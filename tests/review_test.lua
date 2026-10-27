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

-- An agent's next edit often lands right after it wrote the one just
-- accepted; checktime or live_changes then reloads the file's buffer during
-- the review. That reload brings in the agent's own write, not a user edit.
local function test_reload_of_agent_write_is_not_stale()
  local path = write_original_file()
  local nvim = open_session(path)
  local first_edit = edited_text({ [1] = "one" })
  vim.fn.writefile(vim.split(first_edit, "\n", { trimempty = true }), path)
  local second_edit = edited_text({ [1] = "one", [7] = "seven" })
  propose(nvim, path, second_edit)
  nvim:lua("vim.api.nvim_buf_call(vim.fn.bufnr(...), function() vim.cmd('silent! edit!') end)", path)
  nvim:input("<M-a>")
  vim.wait(200)
  local state = review_state(nvim)
  check("reloaded target still accepts", read_lines(path), vim.split(second_edit, "\n", { trimempty = true }))
  check("reloaded target replies accepted", state.replies, { "ide/diffAccepted" })
  nvim:stop()
end

-- Longest hint line that fits snacks.nvim's notifier: 40 columns wide at
-- least, minus the padding on each side.
local hint_max_width = 38

---@param message string
---@return integer
local function widest_line(message)
  local widest = 0
  for _, line in ipairs(vim.split(message, "\n")) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  return widest
end

-- The key hint stays up for a minute and lists only keys that work for the
-- agent: OpenCode takes or refuses its whole patch, so no <M-y>/<M-x>.
-- Each line fits the notification box, which cuts longer ones short.
local function test_key_hint_lasts_a_minute_and_fits_the_agent()
  local path = write_original_file()
  local nvim = open_session(path)
  nvim:lua([[
    _G.hints = {}
    vim.notify = function(message, _, opts)
      if tostring(message):find("^AI edit") then
        table.insert(_G.hints, { message = message, timeout = opts and opts.timeout })
      end
    end
  ]])
  propose(nvim, path, edited_text({ [3] = "three" }))
  local editable = nvim:lua("return _G.hints[#_G.hints]") or {}
  check("editable review hint lasts 60 s", editable.timeout, 60000)
  check("editable review hint lists Alt-y/Alt-x", tostring(editable.message):find("Alt-y", 1, true) ~= nil, true)
  check("editable review hint fits the box", widest_line(tostring(editable.message)) <= hint_max_width, true)
  nvim:input("<M-r>")

  nvim:lua("package.loaded.agent_doubles = dofile(...)", plugin_root .. "/tests/helpers/agent_doubles.lua")
  nvim:lua(
    "package.loaded.agent_doubles.propose_opencode_v2(...)",
    path,
    "Index: x\n" .. string.rep("=", 67) .. "\n--- x\n+++ x\n@@ -3 +3 @@\n-line 3\n+three\n"
  )
  vim.wait(150)
  local read_only = nvim:lua("return _G.hints[#_G.hints]") or {}
  check("OpenCode review hint lasts 60 s", read_only.timeout, 60000)
  check("OpenCode review hint leaves out Alt-y/Alt-x", tostring(read_only.message):find("Alt-y", 1, true), nil)
  check("OpenCode review hint keeps Alt-a", tostring(read_only.message):find("Alt-a", 1, true) ~= nil, true)
  check("OpenCode review hint fits the box", widest_line(tostring(read_only.message)) <= hint_max_width, true)
  nvim:stop()
end

-- One hint box at a time: each review used to add a box, and a few edits in
-- a row stacked them down the screen. The box also closes with the review.
local function test_key_hint_replaces_itself_and_closes_with_the_review()
  local path = write_original_file()
  local nvim = open_session(path)
  nvim:lua([[
    _G.hint_ids, _G.hidden = {}, {}
    vim.notify = function(message, _, opts)
      if tostring(message):find("^AI edit: review keys") then
        table.insert(_G.hint_ids, opts and opts.id or "none")
      end
    end
    package.loaded["snacks.notifier"] = {
      hide = function(id)
        table.insert(_G.hidden, id)
      end,
    }
  ]])
  propose(nvim, path, edited_text({ [3] = "three" }))
  nvim:input("<M-r>")
  propose(nvim, path, edited_text({ [4] = "four" }))
  local ids = nvim:lua("return _G.hint_ids")
  check("each hint is shown with an id", #ids == 2 and ids[1] ~= "none", true)
  check("every review reuses the same hint box", ids[1], ids[2])
  check("ending the review closes the hint box", nvim:lua("return _G.hidden"), { ids[1] })
  nvim:stop()
end

test_opens_with_first_change_selected()
test_key_hint_lasts_a_minute_and_fits_the_agent()
test_navigation_selects_each_change()
test_alt_n_and_alt_p_step_from_each_mode()
test_removal_only_change_places_cursor()
test_alt_a_accepts_from_each_mode()
test_alt_r_rejects_from_insert()
test_da_in_visual_accepts_instead_of_deleting()
test_reload_of_agent_write_is_not_stale()
test_key_hint_replaces_itself_and_closes_with_the_review()
recorder:finish()
