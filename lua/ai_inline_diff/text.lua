local M = {}

--- Split file content into lines, remembering the final newline and whether
--- the file uses CRLF. Example: `split("a\r\nb\r\n")` → `{ "a", "b" }, true, "\r\n"`
---@param text string
---@return string[] lines, boolean has_eol, string line_ending
function M.split(text)
  local line_ending = text:find("\r\n", 1, true) and "\r\n" or "\n"
  text = text:gsub("\r\n", "\n")
  if text == "" then
    return {}, false, line_ending
  end

  local has_eol = text:sub(-1) == "\n"
  local lines = vim.split(text, "\n", { plain = true })
  if has_eol then
    table.remove(lines)
  end
  return lines, has_eol, line_ending
end

--- Inverse of split(). Example: `join({ "a", "b" }, true)` → `"a\nb\n"`
---@param lines string[]
---@param has_eol boolean
---@param line_ending string?
---@return string
function M.join(lines, has_eol, line_ending)
  line_ending = line_ending or "\n"
  local text = table.concat(lines, line_ending)
  return has_eol and (text .. line_ending) or text
end

return M
