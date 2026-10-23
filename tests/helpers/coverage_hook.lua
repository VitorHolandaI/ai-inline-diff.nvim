-- Loaded inside each child Neovim when tests/coverage.lua drives the suite.
-- Counts which lines of the plugin's Lua files run, then writes them out
-- for tests/coverage.lua to merge.

local M = {}

---@type table<string, table<integer, integer>> hits[file][line] = count
local hits = {}

--- Start counting lines of files whose path starts with `prefix`.
--- Example: `start("/path/to/ai-inline-diff.nvim/lua/")`
---@param prefix string
function M.start(prefix)
  -- Compiled traces skip line hooks, so lines would go uncounted.
  jit.off()
  local wanted = "@" .. prefix
  debug.sethook(function(_, line)
    local source = debug.getinfo(2, "S").source
    if source:sub(1, #wanted) ~= wanted then
      return
    end
    local file = source:sub(2)
    hits[file] = hits[file] or {}
    hits[file][line] = (hits[file][line] or 0) + 1
  end, "l")
end

--- Write the counts as `file<TAB>line<TAB>count` lines to a new file in `dir`.
---@param dir string
function M.dump(dir)
  debug.sethook()
  local rows = {}
  for file, lines in pairs(hits) do
    for line, count in pairs(lines) do
      rows[#rows + 1] = string.format("%s\t%d\t%d", file, line, count)
    end
  end
  local path = string.format("%s/%d-%d.tsv", dir, vim.fn.getpid(), vim.uv.hrtime())
  if vim.fn.writefile(rows, path) ~= 0 then
    error(string.format("cannot write coverage to '%s', expected a writable directory", path))
  end
end

return M
