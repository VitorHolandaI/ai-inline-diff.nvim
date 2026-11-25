local M = {}

local review_session = require("ai_inline_diff.review_session")
local target_file = require("ai_inline_diff.target_file")
local save_wait = require("ai_inline_diff.save_wait")

-- Cancels for Claude edits waiting on a buffer with unsaved changes, keyed
-- by diff tab name.
local claude_save_waits = {} ---@type table<string, fun()>

---@param saved boolean
---@param tab_name string
---@param content string?
---@return table
local function claude_result(saved, tab_name, content)
  if saved then
    return { content = { { type = "text", text = "FILE_SAVED" }, { type = "text", text = content } } }
  end
  return { content = { { type = "text", text = "DIFF_REJECTED" }, { type = "text", text = tab_name } } }
end

--- Resume the coroutine Claude's `openDiff` waits on, and send its result
--- through claudecode.nvim's deferred response table.
---@param co thread
---@param result table
local function resume_with(co, result)
  local ok, resumed_result = coroutine.resume(co, result)
  local co_key = tostring(co)
  -- claudecode.nvim owns this global; tests/claude_adapter_test.lua pins
  -- its use.
  ---@type table<string, fun(reply: table)>?
  local deferred = rawget(_G, "claude_deferred_responses")
  local sender = deferred and deferred[co_key]
  if deferred and sender then
    if ok then
      sender(resumed_result)
    else
      sender({ error = { code = -32603, message = "Internal error", data = tostring(resumed_result) } })
    end
    deferred[co_key] = nil
  end
end

---@param co thread
---@param path string
---@param tab_name string
local function wait_until_saved(co, path, tab_name)
  -- Claude already waits on this coroutine for the reply, so it can also
  -- wait while the user saves or discards unsaved edits in the file.
  local ready = false
  local cancel = save_wait.when_saved(target_file.loaded_buffer(path), function()
    ready = true
    claude_save_waits[tab_name] = nil
    if coroutine.status(co) == "suspended" then
      coroutine.resume(co)
    end
  end)
  if not ready then
    claude_save_waits[tab_name] = cancel
    coroutine.yield()
  end
end

---@param old_file_path string
---@param _ string new file path, the same file for an edit
---@param new_file_contents string
---@param tab_name string
---@param client_id string?
---@return table
local function open_diff_blocking(old_file_path, _, new_file_contents, tab_name, client_id)
  local co, is_main = coroutine.running()
  if not co or is_main then
    error({ code = -32000, message = "Internal server error", data = "openDiff must run in coroutine context" })
  end

  local path = target_file.resolve(old_file_path)
  wait_until_saved(co, path, tab_name)

  local _, open_err = review_session.open({
    id = "claude:" .. tab_name,
    path = path,
    old_text = target_file.read(path) or "",
    new_text = new_file_contents,
    claude_tab_name = tab_name,
    client_id = client_id,
    on_accept = function(content)
      resume_with(co, claude_result(true, tab_name, content))
    end,
    on_reject = function()
      resume_with(co, claude_result(false, tab_name))
    end,
  })
  if open_err then
    error({ code = -32000, message = "Inline diff setup failed", data = open_err })
  end

  return coroutine.yield()
end

---@param predicate fun(review: AiInlineDiffReview): boolean
---@return integer
local function reject_claude_reviews(predicate)
  return review_session.reject_matching("claude:", predicate)
end

local function every_review()
  return true
end

---@param diff table claudecode.diff
---@param originals table<string, function?>
local function wrap_close_functions(diff, originals)
  diff._cleanup_all_active_diffs = function(...)
    reject_claude_reviews(every_review)
    return originals.cleanup_all(...)
  end

  if originals.close_all then
    diff.close_all_diffs = function(...)
      local count = reject_claude_reviews(every_review)
      return review_session.close_result(originals.close_all(...), count)
    end
  end

  if originals.close_pending then
    diff.close_pending_diffs = function(...)
      local count = reject_claude_reviews(every_review)
      return review_session.close_result(originals.close_pending(...), count)
    end
  end

  if originals.close_for_client then
    diff.close_diffs_for_client = function(client_id, ...)
      local count = reject_claude_reviews(function(review)
        return review.client_id == client_id
      end)
      return review_session.close_result(originals.close_for_client(client_id, ...), count)
    end
  end
end

---@param diff table claudecode.diff
---@param originals table<string, function?>
local function wrap_accept_and_close(diff, originals)
  diff.accept_current_diff = function()
    local id = vim.b.ai_inline_diff_id
    if review_session.is_open(id) then
      review_session.resolve(id, true)
      return
    end
    originals.accept()
  end

  diff.deny_current_diff = function()
    local id = vim.b.ai_inline_diff_id
    if review_session.is_open(id) then
      review_session.resolve(id, false)
      return
    end
    originals.reject()
  end

  diff.close_diff_by_tab_name = function(tab_name)
    if claude_save_waits[tab_name] then
      claude_save_waits[tab_name]()
      claude_save_waits[tab_name] = nil
    end
    local id = "claude:" .. tab_name
    if review_session.is_open(id) then
      review_session.resolve(id, false)
      return true
    end
    vim.defer_fn(function()
      vim.cmd("checktime")
    end, 100)
    return originals.close(tab_name)
  end
end

--- Replace claudecode.diff so each `openDiff` from Claude Code opens an
--- inline review. Safe to call again: the originals are kept once.
function M.setup()
  local diff = require("claudecode.diff")
  local originals = rawget(diff, "_ai_inline_diff_originals")
  if not originals then
    originals = {
      accept = diff.accept_current_diff,
      reject = diff.deny_current_diff,
      close = diff.close_diff_by_tab_name,
      cleanup_all = diff._cleanup_all_active_diffs,
      close_all = diff.close_all_diffs,
      close_pending = diff.close_pending_diffs,
      close_for_client = diff.close_diffs_for_client,
    }
    diff._ai_inline_diff_originals = originals
  end

  diff.open_diff_blocking = open_diff_blocking
  wrap_accept_and_close(diff, originals)
  wrap_close_functions(diff, originals)
end

return M
