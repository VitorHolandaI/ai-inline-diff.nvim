-- Run with: nvim -l tests/live_changes_test.lua
-- Checks lua/ai_inline_diff/live_changes.lua: when an agent writes a file
-- that is open in Neovim (OpenCode "Always allow", Claude auto-accept), the
-- buffer reloads at once and shows what changed until the user edits it.
-- Unsaved user edits are never replaced.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local recorder = helpers.CheckRecorder.new()

local function check(name, actual, expected)
  recorder:check(name, actual, expected)
end

---@return EmbeddedNvim, string path
local function open_watched_file()
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "one", "two", "three" }, path)
  nvim:lua("require('ai_inline_diff').setup_live_changes(); vim.cmd.edit(...)", path)
  vim.wait(200)
  return nvim, path
end

-- What the user sees: buffer text, highlighted rows, removed lines shown.
---@param nvim EmbeddedNvim
---@param path string
local function view(nvim, path)
  return nvim:lua(
    [[
    local buf = vim.fn.bufnr(...)
    local ns = vim.api.nvim_get_namespaces().AiInlineDiffLive
    local added, removed = {}, {}
    for _, mark in ipairs(ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) or {}) do
      if mark[4].line_hl_group == "DiffAdd" then
        added[#added + 1] = mark[2] + 1
      end
      for _, virt in ipairs(mark[4].virt_lines or {}) do
        removed[#removed + 1] = virt[2][1]
      end
    end
    table.sort(added)
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      added = added,
      removed = removed,
      modified = vim.bo[buf].modified,
    }
  ]],
    path
  )
end

---@param path string
---@param lines string[]
local function agent_writes(path, lines)
  vim.fn.writefile(lines, path)
  vim.wait(700)
end

local function test_agent_write_reloads_and_marks_changes()
  local nvim, path = open_watched_file()
  agent_writes(path, { "one", "TWO", "three", "four" })
  check("agent write reloads the buffer and marks it", view(nvim, path), {
    lines = { "one", "TWO", "three", "four" },
    added = { 2, 4 },
    removed = { "two" },
    modified = false,
  })
  agent_writes(path, { "one", "TWO", "three", "four", "five" })
  local second = view(nvim, path)
  check("a second write replaces the marks", { second.added, second.removed }, { { 5 }, {} })
  nvim:stop()
end

local function test_marks_stay_until_the_user_edits()
  local nvim, path = open_watched_file()
  agent_writes(path, { "one", "TWO", "three" })
  vim.wait(500)
  check("marks stay while reading", view(nvim, path).added, { 2 })
  nvim:input("ggi")
  check("entering Insert clears the marks", view(nvim, path).added, {})
  nvim:input("<Esc>")
  nvim:stop()

  nvim, path = open_watched_file()
  agent_writes(path, { "one", "TWO", "three" })
  nvim:input("Gdd")
  check("a Normal-mode edit clears the marks", view(nvim, path).added, {})
  nvim:stop()
end

local function test_unsaved_user_edits_are_kept()
  local nvim, path = open_watched_file()
  nvim:lua("vim.api.nvim_buf_set_lines(vim.fn.bufnr(...), 0, 1, false, { 'typed by the user' })", path)
  agent_writes(path, { "one", "TWO", "three" })
  local state = view(nvim, path)
  check(
    "unsaved buffer is not reloaded",
    { state.lines[1], state.modified, state.added },
    { "typed by the user", true, {} }
  )
  nvim:stop()
end

local function test_own_save_is_not_marked()
  local nvim, path = open_watched_file()
  nvim:input("ggAx<Esc>:w<CR>")
  vim.wait(700)
  check("the user's own :w is not marked", view(nvim, path).added, {})
  nvim:stop()
end

-- Many tools write a temp file and rename it over the original.
local function test_atomic_rename_is_seen()
  local nvim, path = open_watched_file()
  vim.fn.writefile({ "one", "two", "THREE" }, path .. ".tmp")
  vim.uv.fs_rename(path .. ".tmp", path)
  vim.wait(700)
  agent_writes(path, { "ONE", "two", "THREE" })
  local state = view(nvim, path)
  check("rename-over write reloads, and the file is still watched", { state.lines, state.added }, {
    { "ONE", "two", "THREE" },
    { 1 },
  })
  nvim:stop()
end

test_agent_write_reloads_and_marks_changes()
test_marks_stay_until_the_user_edits()
test_unsaved_user_edits_are_kept()
test_own_save_is_not_marked()
test_atomic_rename_is_seen()
recorder:finish()
