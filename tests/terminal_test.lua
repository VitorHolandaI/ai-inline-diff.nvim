-- Run with: nvim -l tests/terminal_test.lua
-- Drives an embedded Neovim over RPC because terminal mode cannot be
-- exercised with feedkeys inside a single headless instance.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local recorder = helpers.CheckRecorder.new()

local function check(name, actual, expected)
  recorder:check(name, actual, expected)
end

-- Editor on the left, terminal running `cat` on the right, focus on editor.
local function open_editor_and_terminal(opts)
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  nvim:lua("require('ai_inline_diff').setup_terminal(...)", opts or vim.empty_dict())
  nvim:lua("vim.cmd('vsplit | wincmd l | terminal cat')")
  nvim:lua("vim.cmd('stopinsert | wincmd h')")
  vim.wait(150)
  return nvim
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

recorder:finish()
