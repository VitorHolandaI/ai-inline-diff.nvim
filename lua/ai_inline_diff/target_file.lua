local M = {}

local canonical_path = require("ai_inline_diff.paths").canonical_path

--- The file's bytes, or nil and the error when it cannot be read.
--- Example: `local text = target_file.read(path) or ""`
---@param path string
---@return string?, string?
function M.read(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end

  local content = file:read("*a")
  file:close()
  return content
end

--- The absolute path an agent meant. A relative path is tried against
--- `base_dir` and each of its parents, then Neovim's cwd, then $HOME.
---@param path string
---@param base_dir string?
---@return string
function M.resolve(path, base_dir)
  if path:sub(1, 1) ~= "/" and base_dir then
    local directory = vim.fs.normalize(base_dir)
    while directory do
      local candidate = vim.fs.normalize(vim.fs.joinpath(directory, path))
      if vim.fn.filereadable(candidate) == 1 then
        return canonical_path(candidate)
      end
      local parent = vim.fs.dirname(directory)
      if not parent or parent == directory then
        break
      end
      directory = parent
    end
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(absolute) == 1 then
    return canonical_path(absolute)
  end

  if vim.env.HOME and vim.env.HOME ~= "" then
    local home_path = vim.fs.normalize(vim.fs.joinpath(vim.env.HOME, path))
    if vim.fn.filereadable(home_path) == 1 then
      return canonical_path(home_path)
    end
  end

  return vim.fs.normalize(absolute)
end

--- The loaded buffer showing `path`, compared by canonical path.
---@param path string
---@return integer?
function M.loaded_buffer(path)
  local normalized_path = canonical_path(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and canonical_path(name) == normalized_path then
        return buf
      end
    end
  end
end

return M
