local M = {}

local paths = require("ai_inline_diff.paths")
local review_changes = require("ai_inline_diff.review_changes")
local text = require("ai_inline_diff.text")

local namespace = vim.api.nvim_create_namespace("AiInlineDiffLive")
-- Agents often write a file in several steps; one check after they settle.
local settle_ms = 150

---@class AiInlineDiffDirWatch
---@field handle uv.uv_fs_event_t
---@field names table<string, integer> file name -> buffer

---@type table<string, AiInlineDiffDirWatch> directory -> watcher
local directories = {}
---@type table<string, true>
local pending = {}

---@param buf integer
---@return boolean
local function is_file_buffer(buf)
  return vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
    and vim.b[buf].ai_inline_diff_id == nil
end

-- Clears the marks once the user edits the buffer: Insert mode, or any
-- change after the one the reload itself made.
---@param buf integer
local function clear_on_user_edit(buf)
  local group = vim.api.nvim_create_augroup("AiInlineDiffLive" .. buf, { clear = true })
  local reloaded_tick = vim.api.nvim_buf_get_changedtick(buf)
  local function clear()
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  vim.api.nvim_create_autocmd("InsertEnter", { group = group, buffer = buf, callback = clear })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = buf,
    callback = function()
      if vim.api.nvim_buf_get_changedtick(buf) ~= reloaded_tick then
        clear()
      end
    end,
  })
end

-- :edit! updates the file time Neovim keeps, so a later :w does not warn
-- that the file changed; 'undoreload' keeps the agent's change undoable.
---@param buf integer
local function reload_keeping_cursors(buf)
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    cursors[win] = vim.api.nvim_win_get_cursor(win)
  end
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! edit!")
  end)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for win, cursor in pairs(cursors) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], line_count), cursor[2] })
    end
  end
end

---@param path string
---@param buf integer
local function show_change(path, buf)
  if not vim.api.nvim_buf_is_valid(buf) or not is_file_buffer(buf) or vim.bo[buf].modified then
    return
  end
  local ok, disk = pcall(vim.fn.readfile, path, "b")
  if not ok then
    return
  end
  local new_lines = text.split(table.concat(disk, "\n"))
  local old_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.deep_equal(old_lines, new_lines) then
    return
  end
  reload_keeping_cursors(buf)
  local hunks = vim.text.diff(text.join(old_lines, true), text.join(new_lines, true), {
    algorithm = "histogram",
    result_type = "indices",
  }) --[[@as AiInlineDiffHunk[] ]]
  review_changes.draw(buf, namespace, hunks, old_lines, function()
    return "+"
  end)
  clear_on_user_edit(buf)
end

---@param path string
---@param buf integer
local function schedule_check(path, buf)
  if pending[path] then
    return
  end
  pending[path] = true
  vim.defer_fn(function()
    pending[path] = nil
    show_change(path, buf)
  end, settle_ms)
end

-- One watcher per directory, not per file: writing a temp file and renaming
-- it over the original replaces the file a per-file watcher would follow.
---@param buf integer
local function watch(buf)
  if not is_file_buffer(buf) then
    return
  end
  local path = paths.canonical_path(vim.api.nvim_buf_get_name(buf))
  local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
  local entry = directories[dir]
  if not entry then
    local handle = vim.uv.new_fs_event()
    if not handle then
      return
    end
    entry = { handle = handle, names = {} }
    local started, err = handle:start(dir, {}, function(watch_err, filename)
      local watched = not watch_err and filename and entry.names[filename]
      if watched then
        vim.schedule(function()
          schedule_check(dir .. "/" .. filename, watched)
        end)
      end
    end)
    if not started then
      handle:close()
      vim.notify(
        string.format("ai-inline-diff: cannot watch '%s' for agent edits: %s", dir, tostring(err)),
        vim.log.levels.WARN
      )
      return
    end
    directories[dir] = entry
  end
  entry.names[name] = buf
end

---@param buf integer
local function unwatch(buf)
  local name_in_buf = vim.api.nvim_buf_get_name(buf)
  if name_in_buf == "" then
    return
  end
  local path = paths.canonical_path(name_in_buf)
  local dir = vim.fs.dirname(path)
  local entry = directories[dir]
  if not entry then
    return
  end
  entry.names[vim.fs.basename(path)] = nil
  if next(entry.names) == nil then
    entry.handle:close()
    directories[dir] = nil
  end
end

--- Reload files that change on disk while open and unmodified, and mark
--- what changed until the user edits them. Example: `setup()`
function M.setup()
  local group = vim.api.nvim_create_augroup("AiInlineDiffLiveWatch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWritePost" }, {
    group = group,
    callback = function(args)
      watch(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      unwatch(args.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    watch(buf)
  end
end

return M
