local M = {}

local review_session = require("ai_inline_diff.review_session")
local target_file = require("ai_inline_diff.target_file")
local save_wait = require("ai_inline_diff.save_wait")
local text = require("ai_inline_diff.text")
local find_editor_window = require("ai_inline_diff.windows").find_editor_window
local live_changes = require("ai_inline_diff.live_changes")

-- Cancels for Antigravity edits waiting on a buffer with unsaved changes,
-- keyed by resolved file path.
local antigravity_save_waits = {} ---@type table<string, fun()>

---@param diff table antigravity-cli.diff
---@param method string
---@param filePath string
local function send_diff_response(diff, method, filePath)
  if type(diff.send_diff_response) == "function" then
    diff.send_diff_response(method, filePath)
    return
  end
  local server_ok, server = pcall(require, "antigravity-cli.server")
  if server_ok and server.notify then
    server.notify({
      method = method,
      params = {
        filePath = filePath,
      },
    })
  end
end

--- Antigravity 1.2 leaves the write to the editor: put the accepted text in
--- the file's buffer and save it, or write the file when no buffer loads.
---@param path string
---@param new_content string
local function write_accepted(path, new_content)
  local target_buf = target_file.loaded_buffer(path)
  if not target_buf then
    target_buf = vim.fn.bufnr(path, true)
  end
  if not vim.api.nvim_buf_is_loaded(target_buf) then
    vim.fn.bufload(target_buf)
  end

  local lines, has_eol = text.split(new_content)
  if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
    vim.bo[target_buf].endofline = has_eol
    vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
    vim.api.nvim_buf_call(target_buf, function()
      vim.cmd("silent! write!")
    end)
    return
  end
  local file, write_err = io.open(path, "wb")
  if not file then
    vim.notify("Failed to write Antigravity edit to " .. path .. ": " .. tostring(write_err), vim.log.levels.ERROR)
    return
  end
  file:write(new_content)
  file:close()
end

---@param diff table antigravity-cli.diff
---@param filePath string as Antigravity sent it, echoed in the reply
---@param path string resolved
---@param content string
---@return { status: string }
local function open_now(diff, filePath, path, content)
  local win = find_editor_window(path)
  if not win then
    vim.cmd("split")
  end

  local _, open_err = review_session.open({
    id = "antigravity:" .. path,
    path = path,
    old_text = target_file.read(path) or "",
    new_text = content,
    editable = true,
    on_accept = function(new_content)
      write_accepted(path, new_content)
      send_diff_response(diff, "ide/diffAccepted", filePath)
      vim.defer_fn(function()
        vim.cmd("checktime")
      end, 100)
    end,
    on_reject = function()
      send_diff_response(diff, "ide/diffRejected", filePath)
    end,
  })

  if open_err then
    vim.notify("Cannot open Antigravity inline diff: " .. open_err, vim.log.levels.ERROR)
    send_diff_response(diff, "ide/diffRejected", filePath)
    return { status = "rejected" }
  end

  return { status = "opened" }
end

---@param diff table antigravity-cli.diff
---@return fun(filePath: string, content: string): { status: string }
local function diff_opener(diff)
  return function(filePath, content)
    local path = target_file.resolve(filePath)
    -- With unsaved edits in the file, answer "opened" now and build the
    -- review once the user saves or discards them.
    local result = { status = "opened" }
    local ready = false
    local cancel = save_wait.when_saved(target_file.loaded_buffer(path), function()
      ready = true
      antigravity_save_waits[path] = nil
      result = open_now(diff, filePath, path, content)
    end)
    if not ready then
      antigravity_save_waits[path] = cancel
    end
    return result
  end
end

--- Body of :AntigravityDiffAccept and :AntigravityDiffDeny: answer the
--- review in this buffer, else the latest Antigravity review, else run
--- `plain_command` in antigravity-cli.nvim's own "(proposed)" buffer.
---@param accepted boolean
---@param plain_command string
local function answer_from_command(accepted, plain_command)
  local buf = vim.api.nvim_get_current_buf()
  local id = vim.b[buf].ai_inline_diff_id
  if review_session.is_open(id) then
    review_session.resolve(id, accepted)
    return
  end
  local current = review_session.current_id()
  if current and current:sub(1, 12) == "antigravity:" then
    review_session.resolve(current, accepted)
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("%(proposed%)$") then
    vim.cmd(plain_command)
    return
  end
  -- Live-change marks look like a review; say they are already on disk.
  if live_changes.has_marks(buf) then
    vim.notify(
      "No AI review is open: the agent already wrote the marked lines without asking. "
        .. "u undoes them; see :help ai-inline-diff-unreviewed",
      vim.log.levels.WARN
    )
    return
  end
  vim.notify("No AI review is open in this buffer", vim.log.levels.WARN)
end

---@param diff table antigravity-cli.diff
---@param originals table<string, function?>
local function wrap_close_functions(diff, originals)
  diff.close_all_diffs = function(...)
    local count = review_session.reject_matching("antigravity:")
    if originals.close_all then
      return review_session.close_result(originals.close_all(...), count)
    end
    return count
  end

  if originals.close then
    diff.close = function(filePath, ...)
      local path = target_file.resolve(filePath)
      local waiting = antigravity_save_waits[path]
      if waiting then
        waiting()
        antigravity_save_waits[path] = nil
      end
      local id = "antigravity:" .. path
      if review_session.is_open(id) then
        review_session.resolve(id, false)
        return true
      end
      return originals.close(filePath, ...)
    end
  end
end

--- Replace antigravity-cli.diff so each diff Antigravity 1.2 opens becomes
--- an inline review. Does nothing without antigravity-cli.nvim.
function M.setup()
  local ok, diff = pcall(require, "antigravity-cli.diff")
  if not ok then
    return
  end

  local originals = rawget(diff, "_ai_inline_diff_originals")
  if not originals then
    originals = {
      open = diff.open,
      close = diff.close,
      close_all = diff.close_all_diffs,
    }
    diff._ai_inline_diff_originals = originals
  end

  diff.open = diff_opener(diff)
  vim.api.nvim_create_user_command("AntigravityDiffAccept", function()
    answer_from_command(true, "write")
  end, { force = true })
  vim.api.nvim_create_user_command("AntigravityDiffDeny", function()
    answer_from_command(false, "quit")
  end, { force = true })
  wrap_close_functions(diff, originals)
end

return M
