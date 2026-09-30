local M = {}

local canonical_path = require("ai_inline_diff.paths").canonical_path

local excluded_filetypes = {
  aerial = true,
  minifiles = true,
  netrw = true,
  neo_tree = true,
  ["neo-tree"] = true,
  NvimTree = true,
  oil = true,
  snacks_picker_list = true,
  tagbar = true,
}

---@param win integer
---@return boolean
function M.is_editor_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local config = vim.api.nvim_win_get_config(win)
  if config.relative and config.relative ~= "" then
    return false
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local buftype = vim.bo[buf].buftype
  local filetype = vim.bo[buf].filetype
  return buftype ~= "terminal" and buftype ~= "prompt" and not excluded_filetypes[filetype]
end

--- Pick the window a file should appear in: one already showing it, else
--- the current or nearest non-terminal, non-sidebar window.
---@param path string?
---@return integer?
function M.find_editor_window(path)
  local normalized_path = path and canonical_path(path)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if
      normalized_path
      and canonical_path(vim.api.nvim_buf_get_name(buf)) == normalized_path
      and M.is_editor_window(win)
    then
      return win
    end
  end

  local current = vim.api.nvim_get_current_win()
  if M.is_editor_window(current) then
    return current
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if M.is_editor_window(win) then
      return win
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if M.is_editor_window(win) then
      return win
    end
  end
end

return M
