-- Real agent plugins, checked out at the versions in README "Versions in use",
-- so scenarios run against the same code users install.

local M = {}

---@class AgentPluginPin
---@field name string
---@field url string
---@field commit string

---@type AgentPluginPin[]
M.pins = {
  {
    name = "claudecode.nvim",
    url = "https://github.com/coder/claudecode.nvim",
    commit = "2390c6e45c4789072c293ac69de051d169668b29",
  },
  {
    name = "antigravity-cli.nvim",
    url = "https://github.com/McEazy2700/antigravity-cli.nvim",
    commit = "43d0d38c325ec45da1f6591f1e5534fad9a0fc40",
  },
}

---@param args string[]
---@return string stdout
local function git(args)
  local result = vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
  if result.code ~= 0 then
    error(string.format("git %s failed with code %d: %s", table.concat(args, " "), result.code, result.stderr), 0)
  end
  return vim.trim(result.stdout)
end

---@param dir string
---@param pin AgentPluginPin
local function ensure_checkout(dir, pin)
  if vim.fn.isdirectory(dir) == 0 then
    git({ "clone", "--quiet", "--filter=blob:none", pin.url, dir })
  end
  if git({ "-C", dir, "rev-parse", "HEAD" }) ~= pin.commit then
    git({ "-C", dir, "fetch", "--quiet", "origin", pin.commit })
    git({ "-C", dir, "checkout", "--quiet", "--detach", pin.commit })
  end
end

--- Clone or move each pinned plugin under `deps_dir` and return their paths.
--- Example: `local dirs = ensure(plugin_root .. "/tests/.deps")`
---@param deps_dir string
---@return string[]
function M.ensure(deps_dir)
  vim.fn.mkdir(deps_dir, "p")
  local dirs = {}
  for _, pin in ipairs(M.pins) do
    local dir = deps_dir .. "/" .. pin.name
    ensure_checkout(dir, pin)
    dirs[#dirs + 1] = dir
  end
  return dirs
end

return M
