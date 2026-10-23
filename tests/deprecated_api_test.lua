-- Run with: nvim -l tests/deprecated_api_test.lua
-- Fails when the plugin itself calls an API Neovim has deprecated:
-- - vim.diff(), renamed to vim.text.diff() (runtime/doc/deprecated.txt)
-- - vim.keymap.set(..., { buffer = }), renamed to `buf`; runtime/lua/vim/
--   keymap.lua plans its removal for 0.15.
-- Calls are attributed by caller file, and calls that arrive through
-- vim.text.diff() are skipped, since it still forwards to vim.diff().

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local recorder = helpers.CheckRecorder.new()

local nvim = helpers.EmbeddedNvim.start(plugin_root)
nvim:lua(
  [[
  local plugin_lua = ... .. "/lua/"
  _G.deprecated_calls = {}
  local function record_if_plugin(api)
    local info = debug.getinfo(3, "Sl")
    if info.source:sub(2, #plugin_lua + 1) == plugin_lua then
      table.insert(_G.deprecated_calls, api .. " at " .. info.source:sub(#plugin_lua + 2) .. ":" .. info.currentline)
    end
  end
  -- vim.text.diff() ends in `return vim.diff(...)`, a tail call that drops
  -- its own frame, so calls made through it are flagged and skipped.
  local diff, text_diff, inside_text_diff = vim.diff, vim.text.diff, false
  vim.diff = function(...)
    if not inside_text_diff then
      record_if_plugin("vim.diff()")
    end
    return diff(...)
  end
  vim.text.diff = function(...)
    inside_text_diff = true
    local result = text_diff(...)
    inside_text_diff = false
    return result
  end
  local keymap_set = vim.keymap.set
  vim.keymap.set = function(modes, lhs, rhs, opts)
    if opts and opts.buffer ~= nil then
      record_if_plugin("vim.keymap.set{buffer}")
    end
    return keymap_set(modes, lhs, rhs, opts)
  end
]],
  plugin_root
)

-- Exercise every path that diffs or maps keys: terminal setup, a review with
-- per-change keys (open, keep, drop, refresh), and a shown location.
local path = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "one", "two", "three" }, path)
nvim:lua(
  [[
  local path = ...
  local FakeAntigravityDiff = {}
  function FakeAntigravityDiff.send_diff_response() end
  package.loaded["antigravity-cli.diff"] = FakeAntigravityDiff
  require("ai_inline_diff").setup_terminal()
  require("ai_inline_diff").setup_antigravity()
  vim.cmd.edit(path)
  FakeAntigravityDiff.open(path, "ONE\ntwo\nTHREE\n")
]],
  path
)
nvim:input("<M-y>")
nvim:input("<M-x>")
nvim:lua("require('ai_inline_diff').open_location(...)", path, 1, 2)

local calls = nvim:lua("return _G.deprecated_calls")
nvim:stop()
recorder:check("plugin calls no deprecated API", calls, {})
recorder:finish()
