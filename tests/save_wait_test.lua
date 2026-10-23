-- Run with: nvim -l tests/save_wait_test.lua
-- Checks lua/ai_inline_diff/save_wait.lua: an AI edit to a file with unsaved
-- changes waits, with a winbar notice, until the user saves, discards (:e!)
-- or wipes the buffer, and a cancelled wait never runs.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local recorder = helpers.CheckRecorder.new()

-- A file open in the current window; `dirty` leaves an unsaved edit in it.
---@param dirty boolean
---@return EmbeddedNvim
local function open_file(dirty)
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "saved text" }, path)
  nvim:lua(
    [[
    local path, dirty = ...
    vim.cmd.edit(path)
    if dirty then
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "typed, not saved" })
    end
    vim.wo.winbar = "user winbar"
    _G.ready_count = 0
    _G.cancel = require("ai_inline_diff.save_wait").when_saved(vim.api.nvim_get_current_buf(), function()
      _G.ready_count = _G.ready_count + 1
    end)
  ]],
    path,
    dirty
  )
  return nvim
end

---@param nvim EmbeddedNvim
---@return { ready: integer, winbar: string }
local function state(nvim)
  vim.wait(100)
  return nvim:lua("return { ready = _G.ready_count, winbar = vim.wo.winbar }")
end

local nvim = open_file(false)
recorder:check("clean buffer runs at once", state(nvim), { ready = 1, winbar = "user winbar" })
nvim:stop()

nvim = open_file(true)
local waiting = state(nvim)
recorder:check("unsaved buffer waits", waiting.ready, 0)
recorder:check("winbar tells how to continue", waiting.winbar:find(":w to review", 1, true) ~= nil, true)
nvim:input(":w<CR>")
recorder:check(":w runs it once and restores the winbar", state(nvim), { ready = 1, winbar = "user winbar" })
nvim:input("ix<Esc>:w<CR>")
recorder:check("a later save does not run it again", state(nvim).ready, 1)
nvim:stop()

nvim = open_file(true)
nvim:input(":e!<CR>")
recorder:check(":e! runs it", state(nvim), { ready = 1, winbar = "user winbar" })
nvim:stop()

nvim = open_file(true)
nvim:lua("vim.cmd('enew | bwipeout! #')")
recorder:check("wiping the buffer runs it", state(nvim).ready, 1)
nvim:stop()

nvim = open_file(true)
nvim:lua("_G.cancel()")
nvim:input(":w<CR>")
recorder:check("cancel stops it and restores the winbar", state(nvim), { ready = 0, winbar = "user winbar" })
nvim:stop()

recorder:finish()
