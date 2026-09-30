-- Run with: nvim -l tests/terminal_test.lua
-- Drives an embedded Neovim over RPC because terminal mode cannot be
-- exercised with feedkeys inside a single headless instance.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

---@class EmbeddedNvim
---@field chan integer
local EmbeddedNvim = {}
EmbeddedNvim.__index = EmbeddedNvim

---@return EmbeddedNvim
function EmbeddedNvim.start()
  local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "--clean" }, { rpc = true })
  if chan <= 0 then
    error(string.format("failed to start embedded nvim: jobstart returned %d, expected channel > 0", chan))
  end
  local self = setmetatable({ chan = chan }, EmbeddedNvim)
  self:lua("vim.opt.rtp:prepend(...)", plugin_root)
  return self
end

---@param code string
---@param ... unknown
---@return unknown
function EmbeddedNvim:lua(code, ...)
  return vim.rpcrequest(self.chan, "nvim_exec_lua", code, { ... })
end

---@param keys string
function EmbeddedNvim:input(keys)
  vim.rpcrequest(self.chan, "nvim_input", keys)
  vim.wait(150)
end

---@return { in_terminal: boolean, mode: string }
function EmbeddedNvim:focus()
  return self:lua([[
    return { in_terminal = vim.bo.buftype == "terminal", mode = vim.api.nvim_get_mode().mode }
  ]])
end

function EmbeddedNvim:stop()
  vim.fn.jobstop(self.chan)
end

-- Editor on the left, terminal running `cat` on the right, focus on editor.
local function open_editor_and_terminal(opts)
  local nvim = EmbeddedNvim.start()
  nvim:lua("require('ai_inline_diff').setup_terminal(...)", opts or vim.empty_dict())
  nvim:lua("vim.cmd('vsplit | wincmd l | terminal cat')")
  nvim:lua("vim.cmd('stopinsert | wincmd h')")
  vim.wait(150)
  return nvim
end

local failures = 0

local function check(name, actual, expected)
  if vim.deep_equal(actual, expected) then
    print("ok   " .. name)
    return
  end
  failures = failures + 1
  print(string.format("FAIL %s: got %s, expected %s", name, vim.inspect(actual), vim.inspect(expected)))
end

local function test_entering_terminal_starts_terminal_mode()
  local nvim = open_editor_and_terminal()
  nvim:input("<C-w>l")
  check("entering terminal starts terminal mode", nvim:focus(), { in_terminal = true, mode = "t" })
  nvim:stop()
end

local function test_window_keys_leave_terminal()
  local nvim = open_editor_and_terminal()
  for _, keys in ipairs({ "<C-w>h", "<C-h>" }) do
    nvim:input("<C-w>l")
    nvim:input(keys)
    check(keys .. " leaves terminal", nvim:focus(), { in_terminal = false, mode = "n" })
  end
  nvim:stop()
end

local function test_finished_terminal_stays_in_normal_mode()
  local nvim = open_editor_and_terminal()
  nvim:lua("vim.fn.jobstop(vim.b[vim.fn.winbufnr(vim.fn.winnr('l'))].terminal_job_id)")
  vim.wait(200)
  nvim:input("<C-w>l")
  check("finished terminal stays in normal mode", nvim:focus(), { in_terminal = true, mode = "nt" })
  nvim:stop()
end

local function test_options_disable_features()
  local nvim = open_editor_and_terminal({ auto_insert = false, window_keys = false })
  nvim:input("<C-w>l")
  check("auto_insert = false keeps normal mode", nvim:focus(), { in_terminal = true, mode = "nt" })
  local mapped = nvim:lua("return vim.fn.maparg('<C-w>', 't') ~= ''")
  check("window_keys = false leaves <C-w> unmapped", mapped, false)
  nvim:stop()
end

local function test_invalid_option_is_rejected()
  local ok, err = pcall(require("ai_inline_diff.terminal").setup, { auto_insert = "yes" })
  check("non-boolean option raises", ok, false)
  check("error names the bad value", tostring(err):find('"yes"', 1, true) ~= nil, true)
  ok, err = pcall(require("ai_inline_diff.terminal").setup, { zoom = true })
  check("unknown option raises", ok, false)
  check("error names the unknown key", tostring(err):find("'zoom'", 1, true) ~= nil, true)
end

vim.opt.rtp:prepend(plugin_root)
test_entering_terminal_starts_terminal_mode()
test_window_keys_leave_terminal()
test_finished_terminal_stays_in_normal_mode()
test_options_disable_features()
test_invalid_option_is_rejected()

if failures > 0 then
  print(string.format("%d check(s) failed", failures))
  os.exit(1)
end
print("all checks passed")
