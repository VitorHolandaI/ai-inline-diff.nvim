-- Run with: nvim -l tests/review_test.lua
-- Covers what the user sees when a review opens and how it is resolved:
-- the first change selected in Visual mode, ]c/[c moving the selection, and
-- <M-a>/<M-r> and <M-n>/<M-p> working from Normal, Visual and Insert mode.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local recorder = helpers.CheckRecorder.new()

local function check(name, actual, expected)
  recorder:check(name, actual, expected)
end

local original_lines = {}
for i = 1, 10 do
  original_lines[i] = "line " .. i
end

-- Copy of the original with replacements ({ [row] = text }) and removals.
local function edited_text(replacements, removed_row)
  local lines = {}
  for i, line in ipairs(original_lines) do
    if i ~= removed_row then
      lines[#lines + 1] = replacements[i] or line
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function write_original_file()
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile(original_lines, path)
  return path
end

-- Editor on the left showing the file, agent terminal on the right with
-- focus in terminal mode: the layout in which agents ask for a review.
-- The review comes from Antigravity's diff module, replaced by a named fake
-- that records the replies sent back to the agent.
local function open_session(path)
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  nvim:lua(
    [[
    local FakeAntigravityDiff = { replies = {} }
    function FakeAntigravityDiff.send_diff_response(method)
      table.insert(FakeAntigravityDiff.replies, method)
    end
    package.loaded["antigravity-cli.diff"] = FakeAntigravityDiff
    require("ai_inline_diff").setup_terminal()
    require("ai_inline_diff").setup_antigravity()
    vim.cmd.edit(...)
    vim.cmd("vsplit | wincmd l | terminal cat")
  ]],
    path
  )
  nvim:input("i")
  return nvim
end

local function propose(nvim, path, new_text)
  nvim:lua("require('antigravity-cli.diff').open(...)", path, new_text)
  vim.wait(150)
end

-- Mode, selected rows (or cursor row when nothing is selected) and replies.
local function review_state(nvim)
  return nvim:lua([[
    local mode = vim.api.nvim_get_mode().mode
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    if not mode:find("^[vV\22]") then
      first = last
    end
    return {
      mode = mode,
      rows = { math.min(first, last), math.max(first, last) },
      in_review = vim.b.ai_inline_diff_id ~= nil,
      replies = package.loaded["antigravity-cli.diff"].replies,
    }
  ]])
end

local function read_lines(path)
  return vim.fn.readfile(path)
end

local function test_opens_with_first_change_selected()
  local path = write_original_file()
  local nvim = open_session(path)
  propose(nvim, path, edited_text({ [4] = "four", [5] = "five" }))
  local state = review_state(nvim)
  check("review takes focus", state.in_review, true)
  check("first change selected linewise", { state.mode, state.rows }, { "V", { 4, 5 } })
  nvim:stop()
end

local function test_navigation_selects_each_change()
  local path = write_original_file()
  local nvim = open_session(path)
  propose(nvim, path, edited_text({ [2] = "two", [8] = "eight" }))
  check("opens on the first change", review_state(nvim).rows, { 2, 2 })
  nvim:input("]c")
  local state = review_state(nvim)
  check("]c selects the next change", { state.mode, state.rows }, { "V", { 8, 8 } })
  nvim:input("[c")
  check("[c selects the previous change", review_state(nvim).rows, { 2, 2 })
  nvim:stop()
end

-- <M-n>/<M-p> step through changes without leaving the mode by hand first.
local function test_alt_n_and_alt_p_step_from_each_mode()
  local cases = {
    { mode = "visual", keys = "" },
    { mode = "normal", keys = "<Esc>" },
    { mode = "insert", keys = "<Esc>A" },
  }
  for _, case in ipairs(cases) do
    local path = write_original_file()
    local nvim = open_session(path)
    propose(nvim, path, edited_text({ [2] = "two", [5] = "five", [8] = "eight" }))
    if case.keys ~= "" then
      nvim:input(case.keys)
    end
    nvim:input("<M-n>")
    local state = review_state(nvim)
    check("<M-n> from " .. case.mode .. " selects the next change", { state.mode, state.rows }, { "V", { 5, 5 } })
    nvim:input("<M-n>")
    check("<M-n> again from " .. case.mode .. " moves on", review_state(nvim).rows, { 8, 8 })
    nvim:input("<M-p>")
    check("<M-p> from " .. case.mode .. " goes back", review_state(nvim).rows, { 5, 5 })
    nvim:stop()
  end
end

local function test_removal_only_change_places_cursor()
  local path = write_original_file()
  local nvim = open_session(path)
  propose(nvim, path, edited_text({}, 5))
  local state = review_state(nvim)
  check("removal-only change leaves Normal mode on the row", { state.mode, state.rows }, { "n", { 4, 4 } })
  nvim:stop()
end

local function test_alt_a_accepts_from_each_mode()
  local new_text = edited_text({ [3] = "three" })
  local expected = vim.split(new_text, "\n", { trimempty = true })
  local cases = {
    { mode = "visual", keys = "" },
    { mode = "normal", keys = "<Esc>" },
    { mode = "insert", keys = "<Esc>A" },
  }
  for _, case in ipairs(cases) do
    local path = write_original_file()
    local nvim = open_session(path)
    propose(nvim, path, new_text)
    if case.keys ~= "" then
      nvim:input(case.keys)
    end
    nvim:input("<M-a>")
    vim.wait(200)
    local state = review_state(nvim)
    check("<M-a> from " .. case.mode .. " writes the edit", read_lines(path), expected)
    check("<M-a> from " .. case.mode .. " ends in Normal mode", { state.mode, state.in_review }, { "n", false })
    check("<M-a> from " .. case.mode .. " replies accepted", state.replies, { "ide/diffAccepted" })
    nvim:stop()
  end
end

local function test_alt_r_rejects_from_insert()
  local path = write_original_file()
  local nvim = open_session(path)
  propose(nvim, path, edited_text({ [3] = "three" }))
  nvim:input("<Esc>A")
  nvim:input("<M-r>")
  local state = review_state(nvim)
  check("<M-r> leaves the file untouched", read_lines(path), original_lines)
  check("<M-r> ends in Normal mode", { state.mode, state.in_review }, { "n", false })
  check("<M-r> replies rejected", state.replies, { "ide/diffRejected" })
  nvim:stop()
end

-- With the change selected, a plain `d` would delete it from the proposal.
local function test_da_in_visual_accepts_instead_of_deleting()
  local new_text = edited_text({ [6] = "six" })
  local path = write_original_file()
  local nvim = open_session(path)
  propose(nvim, path, new_text)
  nvim:input("da")
  vim.wait(200)
  check("da in Visual mode accepts the full edit", read_lines(path), vim.split(new_text, "\n", { trimempty = true }))
  nvim:stop()
end

test_opens_with_first_change_selected()
test_navigation_selects_each_change()
test_alt_n_and_alt_p_step_from_each_mode()
test_removal_only_change_places_cursor()
test_alt_a_accepts_from_each_mode()
test_alt_r_rejects_from_insert()
test_da_in_visual_accepts_instead_of_deleting()
recorder:finish()
