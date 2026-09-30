-- Run with: nvim -l tests/location_test.lua
-- Covers open_location() and bin/nvim-open-location against a child Neovim
-- laid out like a real session: editor window plus an agent terminal.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local recorder = helpers.CheckRecorder.new()
local script = plugin_root .. "/bin/nvim-open-location"

local function check(name, actual, expected)
  recorder:check(name, actual, expected)
end

-- 40-line file inside a fresh directory, so relative paths can be tested.
local function write_sample_file()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/sample.lua"
  local lines = {}
  for i = 1, 40 do
    lines[i] = "line " .. i
  end
  vim.fn.writefile(lines, path)
  return dir, path
end

-- Editor on the left, terminal on the right, focus in terminal mode.
local function open_session(with_editor)
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  if with_editor then
    nvim:lua("vim.cmd('vsplit | wincmd l')")
  end
  nvim:lua("vim.cmd('terminal cat')")
  nvim:input("i")
  return nvim
end

-- What the user sees: file in the other window, cursor, highlight, focus.
local function snapshot(nvim)
  return nvim:lua([[
    local ns = vim.api.nvim_get_namespaces().AiInlineDiffLocation
    local shown, cursor, highlighted
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
        shown = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
        cursor = vim.api.nvim_win_get_cursor(win)[1]
        highlighted = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns or -1, 0, -1, { details = true })) do
          for row = mark[2], mark[4].end_row - 1 do
            highlighted[#highlighted + 1] = row + 1
          end
        end
      end
    end
    return {
      shown = shown,
      cursor = cursor,
      highlighted = highlighted,
      focus_in_terminal = vim.bo.buftype == "terminal",
      mode = vim.api.nvim_get_mode().mode,
      windows = #vim.api.nvim_tabpage_list_wins(0),
    }
  ]])
end

local function open_location(nvim, ...)
  return nvim:lua("return { pcall(require('ai_inline_diff').open_location, ...) }", ...)
end

local function test_opens_range_beside_terminal()
  local _, path = write_sample_file()
  local nvim = open_session(true)
  open_location(nvim, path, 10, 12)
  check("opens range beside terminal", snapshot(nvim), {
    shown = "sample.lua",
    cursor = 10,
    highlighted = { 10, 11, 12 },
    focus_in_terminal = true,
    mode = "t",
    windows = 2,
  })
  open_location(nvim, path, 30)
  local after = snapshot(nvim)
  check("next call moves cursor", after.cursor, 30)
  check("next call replaces highlight", after.highlighted, { 30 })
  nvim:stop()
end

local function test_splits_when_only_terminal_is_open()
  local _, path = write_sample_file()
  local nvim = open_session(false)
  open_location(nvim, path, 5, 6)
  local after = snapshot(nvim)
  check("split created for file", { after.windows, after.shown, after.cursor }, { 2, "sample.lua", 5 })
  check("focus stays in terminal after split", { after.focus_in_terminal, after.mode }, { true, "t" })
  nvim:stop()
end

local function test_keeps_active_review_untouched()
  local _, path = write_sample_file()
  local nvim = open_session(true)
  nvim:lua([[
    local editor = vim.fn.win_getid(vim.fn.winnr("h"))
    local review = vim.api.nvim_create_buf(false, true)
    vim.b[review].ai_inline_diff_id = "claude:test"
    vim.api.nvim_win_set_buf(editor, review)
    vim.g.review_buf = review
  ]])
  open_location(nvim, path, 3)
  local review_visible = nvim:lua([[
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == vim.g.review_buf then
        return true
      end
    end
    return false
  ]])
  check("review stays visible", review_visible, true)
  check("file opens in a new split", { snapshot(nvim).windows, snapshot(nvim).cursor }, { 3, 3 })
  nvim:stop()
end

local function test_invalid_input_raises_with_value()
  local _, path = write_sample_file()
  local nvim = open_session(true)
  local cases = {
    { args = { path .. ".missing", 1 }, needle = "sample.lua.missing" },
    { args = { path, 0 }, needle = "0" },
    { args = { path, 41 }, needle = "41" },
    { args = { path, 12, 10 }, needle = "10" },
  }
  for _, case in ipairs(cases) do
    local result = open_location(nvim, unpack(case.args))
    local label = "rejects " .. vim.inspect(case.args):gsub("%s+", " ")
    check(label, { result[1], tostring(result[2]):find(case.needle, 1, true) ~= nil }, { false, true })
  end
  nvim:stop()
end

-- Starts the script as an agent would: from its own cwd, with $NVIM set.
local function run_script(address, cwd, spec)
  local env = { NVIM = address, PATH = vim.env.PATH, HOME = vim.env.HOME }
  local result = vim.system({ script, spec }, { cwd = cwd, env = env, clear_env = true, text = true }):wait()
  return result.code, result.stdout .. result.stderr
end

local function test_script_opens_relative_path()
  local dir = write_sample_file()
  local nvim = open_session(true)
  local address = nvim:lua("return vim.fn.serverstart()")
  local code = run_script(address, dir, "sample.lua:7-8")
  check("script exit code", code, 0)
  local after = snapshot(nvim)
  check("script opens range", { after.shown, after.cursor, after.highlighted }, { "sample.lua", 7, { 7, 8 } })
  nvim:stop()
end

local function test_script_reports_failures()
  local dir = write_sample_file()
  local nvim = open_session(true)
  local address = nvim:lua("return vim.fn.serverstart()")
  local code, output = run_script(address, dir, "missing.lua:1")
  check("missing file exits 1", code, 1)
  check("missing file names the path", output:find("missing.lua", 1, true) ~= nil, true)
  code, output = run_script(address, dir, "sample.lua:abc")
  check("bad spec exits 2", code, 2)
  check("bad spec names the spec", output:find("sample.lua:abc", 1, true) ~= nil, true)
  code, output = run_script("", dir, "sample.lua:1")
  check("missing $NVIM exits 2", code, 2)
  check("missing $NVIM is explained", output:find("NVIM", 1, true) ~= nil, true)
  nvim:stop()
end

local function test_setup_puts_script_on_path()
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  nvim:lua("require('ai_inline_diff').setup_open_location()")
  nvim:lua("require('ai_inline_diff').setup_open_location()")
  local found = nvim:lua("return vim.fn.exepath('nvim-open-location')")
  check("setup puts script on PATH", found, script)
  local occurrences = nvim:lua("return select(2, vim.env.PATH:gsub(vim.pesc(...), ''))", plugin_root .. "/bin")
  check("repeated setup adds bin once", occurrences, 1)
  nvim:stop()
end

test_opens_range_beside_terminal()
test_splits_when_only_terminal_is_open()
test_keeps_active_review_untouched()
test_invalid_input_raises_with_value()
test_script_opens_relative_path()
test_script_reports_failures()
test_setup_puts_script_on_path()
recorder:finish()
