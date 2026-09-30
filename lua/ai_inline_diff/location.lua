local M = {}

local paths = require("ai_inline_diff.paths")
local windows = require("ai_inline_diff.windows")

local namespace = vim.api.nvim_create_namespace("AiInlineDiffLocation")
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local highlighted_buf

---@param path string
---@return integer
local function load_file_buffer(path)
  if vim.fn.filereadable(path) ~= 1 then
    error(string.format("cannot open location: '%s' is not a readable file", path), 0)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  return buf
end

---@param value unknown
---@param min integer
---@param max integer
---@return boolean
local function is_line_between(value, min, max)
  return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
end

---@param path string
---@param first_line unknown
---@param last_line unknown
---@param line_count integer
local function validate_range(path, first_line, last_line, line_count)
  if not is_line_between(first_line, 1, line_count) then
    error(string.format("first line %s is outside '%s', expected integer 1-%d", vim.inspect(first_line), path, line_count), 0)
  end
  if not is_line_between(last_line, first_line, line_count) then
    error(
      string.format("last line %s is invalid for '%s', expected integer %d-%d", vim.inspect(last_line), path, first_line, line_count),
      0
    )
  end
end

---@param win integer
---@return boolean
local function can_host_file(win)
  -- Replacing a review buffer would wipe it and reject the pending edit.
  local shows_review = vim.b[vim.api.nvim_win_get_buf(win)].ai_inline_diff_id ~= nil
  local same_tab = vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  return same_tab and not shows_review
end

---@param path string
---@param buf integer
---@return integer
local function pick_target_window(path, buf)
  local win = windows.find_editor_window(path)
  if win and can_host_file(win) then
    vim.api.nvim_win_set_buf(win, buf)
    return win
  end
  return vim.api.nvim_open_win(buf, false, { split = "left", win = vim.api.nvim_get_current_win() })
end

---@param buf integer
---@param first_line integer
---@param last_line integer
local function highlight_range(buf, first_line, last_line)
  if highlighted_buf and vim.api.nvim_buf_is_valid(highlighted_buf) then
    vim.api.nvim_buf_clear_namespace(highlighted_buf, namespace, 0, -1)
  end
  highlighted_buf = buf
  vim.api.nvim_buf_set_extmark(buf, namespace, first_line - 1, 0, {
    end_row = last_line,
    hl_group = "Visual",
    hl_eol = true,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    end,
  })
end

--- Show lines of a file in an editor window, keeping focus where it is.
--- Example: `require("ai_inline_diff.location").open("lua/app.lua", 10, 25)`
---@param path string
---@param first_line integer
---@param last_line integer?
function M.open(path, first_line, last_line)
  local absolute = paths.canonical_path(path)
  local buf = load_file_buffer(absolute)
  last_line = last_line or first_line
  validate_range(absolute, first_line, last_line, vim.api.nvim_buf_line_count(buf))

  local win = pick_target_window(absolute, buf)
  vim.api.nvim_win_set_cursor(win, { first_line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  highlight_range(buf, first_line, last_line)
end

--- Entry point for bin/nvim-open-location; errors become a string so the
--- script can print them and exit non-zero.
---@param path string
---@param first_line integer
---@param last_line integer?
---@return string
function M.open_for_remote(path, first_line, last_line)
  local ok, err = pcall(M.open, path, first_line, last_line)
  if not ok then
    return "error: " .. tostring(err)
  end
  return string.format("opened %s:%d-%d", path, first_line, last_line or first_line)
end

--- Put bin/nvim-open-location on $PATH for terminals started afterwards.
function M.setup()
  local bin = plugin_root .. "/bin"
  local entries = vim.split(vim.env.PATH or "", ":", { plain = true })
  if not vim.tbl_contains(entries, bin) then
    vim.env.PATH = bin .. ":" .. (vim.env.PATH or "")
  end
end

---@return string
function M.instructions_path()
  return plugin_root .. "/instructions/open-location.md"
end

return M
