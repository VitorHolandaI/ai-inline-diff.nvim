local M = {}

---@param path string
---@return string
function M.canonical_path(path)
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return vim.uv.fs_realpath(absolute) or absolute
end

return M
