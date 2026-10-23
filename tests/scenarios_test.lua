-- Run with: nvim -l tests/scenarios_test.lua [name]
-- Replays every folder in tests/scenarios/ (or only `name`): an agent
-- proposes an edit, the keys are typed into the review like a macro, and the
-- content the agent ends up writing must match the expected file exactly.
-- Agent plugins are real, pinned in helpers/agent_plugins.lua and cloned
-- into tests/.deps/ on first run; only the agent process is simulated
-- (helpers/agent_doubles.lua).

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local agent_plugins = require("helpers.agent_plugins")
local recorder = helpers.CheckRecorder.new()

---@class Scenario
---@field agent "claude"|"antigravity"|"opencode"
---@field keys string[] typed one entry at a time, as with nvim_input
---@field reply "accepted"|"rejected"

---@param path string
---@return string
local function read_raw(path)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

---@param dir string
---@param stem string
---@return string? first file named `stem.*` in dir
local function find_file(dir, stem)
  return vim.fn.glob(dir .. "/" .. stem .. ".*", false, true)[1]
end

---@param dir string
---@return Scenario
local function load_scenario(dir)
  local spec = dofile(dir .. "/scenario.lua")
  if not vim.tbl_contains({ "claude", "antigravity", "opencode" }, spec.agent) then
    error(string.format("%s: agent %s, expected claude, antigravity or opencode", dir, vim.inspect(spec.agent)), 0)
  end
  if not vim.tbl_contains({ "accepted", "rejected" }, spec.reply) then
    error(string.format("%s: reply %s, expected accepted or rejected", dir, vim.inspect(spec.reply)), 0)
  end
  return spec
end

-- Copies original.<ext> to a fresh directory as sample.<ext>. A scenario
-- without an original proposes a new file, named after expected.<ext>.
---@param dir string
---@return string target path
local function prepare_target(dir)
  local work = vim.fn.tempname()
  vim.fn.mkdir(work, "p")
  local original = find_file(dir, "original")
  local named_after = original or find_file(dir, "expected")
  local target = work .. "/sample." .. vim.fn.fnamemodify(named_after, ":e")
  if original then
    vim.fn.writefile(vim.fn.readfile(original, "b"), target, "b")
  end
  return target
end

-- Editor on the left showing the target, agent terminal focused on the right.
---@param target string
---@param deps string[]
---@return EmbeddedNvim
local function open_session(target, deps)
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  nvim:lua(
    [[
    local deps, target, doubles = ...
    for _, dir in ipairs(deps) do
      vim.opt.rtp:prepend(dir)
    end
    package.loaded.agent_doubles = dofile(doubles)
    require("ai_inline_diff").setup_terminal()
    vim.cmd.edit(target)
    vim.cmd("vsplit | wincmd l | terminal cat")
  ]],
    deps,
    target,
    plugin_root .. "/tests/helpers/agent_doubles.lua"
  )
  nvim:input("i")
  return nvim
end

---@param dir string
---@param deps string[]
local function run_scenario(dir, deps)
  local name = vim.fs.basename(dir)
  local spec = load_scenario(dir)
  local target = prepare_target(dir)
  local original = vim.fn.filereadable(target) == 1 and read_raw(target) or nil
  local proposal = read_raw(find_file(dir, spec.agent == "opencode" and "patch" or "proposed"))

  local nvim = open_session(target, deps)
  nvim:lua("package.loaded.agent_doubles['propose_' .. select(1, ...)](select(2, ...))", spec.agent, target, proposal)
  vim.wait(150)
  for _, keys in ipairs(spec.keys) do
    nvim:input(keys)
  end
  vim.wait(150)
  local outcome = nvim:lua("return package.loaded.agent_doubles.outcome(...)", spec.agent)
  nvim:stop()

  recorder:check(name .. ": agent gets " .. spec.reply, outcome.reply, spec.reply)
  if spec.reply == "accepted" then
    recorder:check(name .. ": agent writes expected content", outcome.content, read_raw(find_file(dir, "expected")))
  end
  if spec.agent ~= "antigravity" or spec.reply == "rejected" then
    -- Only the agent writes in these cases; Neovim must leave the file alone.
    local on_disk = vim.fn.filereadable(target) == 1 and read_raw(target) or nil
    recorder:check(name .. ": file on disk untouched by Neovim", on_disk, original)
  end
end

local deps = agent_plugins.ensure(plugin_root .. "/tests/.deps")
local only = _G.arg[1]
for _, dir in ipairs(vim.fn.glob(plugin_root .. "/tests/scenarios/*", false, true)) do
  local wanted = not only or vim.fs.basename(dir) == only
  if wanted and vim.fn.isdirectory(dir) == 1 then
    run_scenario(dir, deps)
  end
end
recorder:finish()
