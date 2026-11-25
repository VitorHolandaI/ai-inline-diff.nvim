-- Run with: nvim -l tests/agy_hook_test.lua
-- Checks bin/agy-review-hook.lua and lua/ai_inline_diff/agy_hook.lua the
-- way Antigravity (agy 1.5.x) runs them: as a PreToolUse hook that gets the
-- tool call as JSON on stdin and must print its decision on stdout. The
-- hook only answers; agy writes the file itself after an "allow".

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local recorder = helpers.CheckRecorder.new()
local hook_script = plugin_root .. "/bin/agy-review-hook.lua"

local function check(name, actual, expected)
  recorder:check(name, actual, expected)
end

---@param lines string[]
---@return string dir, string path
local function write_target(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/target.txt"
  vim.fn.writefile(lines, path)
  return dir, path
end

---@param path string
---@return EmbeddedNvim, string address
local function open_editor(path)
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  nvim:lua("vim.cmd.edit(...)", path)
  return nvim, nvim:lua("return vim.fn.serverstart()")
end

---@param name string
---@param args table<string, unknown>
---@return table
local function tool_payload(name, args)
  return {
    hookEventName = "PreToolUse",
    toolCall = { id = "toolu_1", name = name, args = args },
    workspacePaths = { "/tmp" },
    cwd = "/tmp",
  }
end

-- Starts the hook as agy does: the payload on stdin, $NVIM inherited.
---@param address string
---@param payload table
---@return vim.SystemObj
local function start_hook(address, payload)
  local env = { NVIM = address, PATH = vim.env.PATH, HOME = vim.env.HOME }
  return vim.system(
    { "nvim", "-l", hook_script },
    { stdin = vim.json.encode(payload), env = env, clear_env = true, text = true }
  )
end

---@param process vim.SystemObj
---@return table? reply, string output
local function hook_reply(process)
  local result = process:wait(8000)
  local ok, reply = pcall(vim.json.decode, result.stdout or "")
  return ok and reply or nil, (result.stdout or "") .. (result.stderr or "")
end

---@param nvim EmbeddedNvim
---@return boolean
local function has_review(nvim)
  return nvim:lua("return vim.b.ai_inline_diff_id ~= nil")
end

---@param nvim EmbeddedNvim
---@return boolean
local function wait_for_review(nvim)
  return vim.wait(4000, function()
    return has_review(nvim)
  end, 50)
end

---@param nvim EmbeddedNvim
---@return string[]
local function review_lines(nvim)
  return nvim:lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
end

local function test_without_neovim_allows()
  local _, path = write_target({ "one", "two" })
  local reply =
    hook_reply(start_hook("", tool_payload("edit_file", { Path = path, Target = "two", Replacement = "2" })))
  check("no $NVIM: agy goes on as without the hook", reply, { decision = "allow" })
end

local function test_accept_allows_unchanged_edit()
  local _, path = write_target({ "one", "two", "three" })
  local nvim, address = open_editor(path)
  local process = start_hook(address, tool_payload("edit_file", { Path = path, Target = "two", Replacement = "TWO" }))
  check("edit_file opens a review", wait_for_review(nvim), true)
  check("review shows the edit applied", review_lines(nvim), { "one", "TWO", "three" })
  nvim:input("<M-a>")
  check("accept answers allow", hook_reply(process), { decision = "allow" })
  check("the hook leaves the write to agy", vim.fn.readfile(path), { "one", "two", "three" })
  nvim:stop()
end

local function test_reject_denies()
  local _, path = write_target({ "one", "two" })
  local nvim, address = open_editor(path)
  local process = start_hook(address, tool_payload("edit_file", { Path = path, Target = "two", Replacement = "TWO" }))
  wait_for_review(nvim)
  nvim:input("<M-r>")
  local reply = hook_reply(process) or {}
  check("reject answers deny", reply.decision, "deny")
  check("deny says the user rejected it", (reply.reason or ""):find("rejected", 1, true) ~= nil, true)
  check("review closes", has_review(nvim), false)
  nvim:stop()
end

local function test_edited_review_overwrites_the_whole_file()
  local _, path = write_target({ "one", "two", "three" })
  local nvim, address = open_editor(path)
  local process = start_hook(address, tool_payload("edit_file", { Path = path, Target = "two", Replacement = "TWO" }))
  wait_for_review(nvim)
  nvim:input("<Esc>ggA!<Esc>")
  nvim:input("<M-a>")
  check("edited review rewrites the edit", hook_reply(process), {
    decision = "allow",
    overwrite = { Target = "one\ntwo\nthree\n", Replacement = "one!\nTWO\nthree\n" },
  })
  nvim:stop()
end

local function test_dropped_change_is_left_out()
  local _, path = write_target({ "a", "b", "c", "d", "e", "f", "g", "h" })
  local nvim, address = open_editor(path)
  local args = { Path = path, Target = "b\nc\nd\ne\nf\ng", Replacement = "B\nc\nd\ne\nf\nG" }
  local process = start_hook(address, tool_payload("edit_file", args))
  wait_for_review(nvim)
  nvim:input("<M-x>")
  nvim:input("<M-a>")
  check("only the kept change reaches agy", hook_reply(process), {
    decision = "allow",
    overwrite = { Target = "a\nb\nc\nd\ne\nf\ng\nh\n", Replacement = "a\nb\nc\nd\ne\nf\nG\nh\n" },
  })
  nvim:stop()
end

local function test_every_occurrence_is_replaced()
  local _, path = write_target({ "x = 1", "print(x)", "x = 1" })
  local nvim, address = open_editor(path)
  local process =
    start_hook(address, tool_payload("edit_file", { Path = path, Target = "x = 1", Replacement = "x = 2" }))
  wait_for_review(nvim)
  check("agy replaces every match, so the review does too", review_lines(nvim), { "x = 2", "print(x)", "x = 2" })
  nvim:input("<M-r>")
  hook_reply(process)
  nvim:stop()
end

local function test_write_file_reviews_a_new_file()
  local dir = write_target({ "unused" })
  local path = dir .. "/new.txt"
  local nvim, address = open_editor(dir .. "/target.txt")
  local process = start_hook(address, tool_payload("write_file", { Path = path, Content = "x\ny\n" }))
  check("write_file opens a review", wait_for_review(nvim), true)
  check("review shows the new content", review_lines(nvim), { "x", "y" })
  nvim:input("<M-a>")
  check("accepted new file answers allow", hook_reply(process), { decision = "allow" })
  nvim:stop()
end

local function test_calls_it_cannot_review_pass_through()
  local _, path = write_target({ "one" })
  local nvim, address = open_editor(path)
  local calls = {
    ["target not in the file"] = tool_payload("edit_file", { Path = path, Target = "zzz", Replacement = "y" }),
    ["agy artifact"] = tool_payload("write_file", {
      Path = "/tmp/brain/plan.md",
      Content = "# plan\n",
      ArtifactMetadata = { Summary = "plan", UserFacing = true },
    }),
    ["other tool"] = tool_payload("read_file", { Path = path }),
  }
  for name, payload in pairs(calls) do
    check(name .. ": allowed at once", hook_reply(start_hook(address, payload)), { decision = "allow" })
  end
  check("no review opened", has_review(nvim), false)
  nvim:stop()
end

local function test_second_edit_waits_for_the_first_review()
  local dir, path = write_target({ "one" })
  local other = dir .. "/other.txt"
  vim.fn.writefile({ "red" }, other)
  local nvim, address = open_editor(path)
  local first = start_hook(address, tool_payload("edit_file", { Path = path, Target = "one", Replacement = "1" }))
  wait_for_review(nvim)
  local second = start_hook(address, tool_payload("edit_file", { Path = other, Target = "red", Replacement = "RED" }))
  vim.wait(600)
  check("first review stays while the second waits", review_lines(nvim), { "1" })
  nvim:input("<M-a>")
  check("first edit allowed", hook_reply(first), { decision = "allow" })
  check(
    "second review opens after the first",
    vim.wait(4000, function()
      return vim.deep_equal(review_lines(nvim), { "RED" })
    end, 50),
    true
  )
  nvim:input("<M-r>")
  check("second edit denied", (hook_reply(second) or {}).decision, "deny")
  nvim:stop()
end

local function test_review_closes_when_agy_stops_waiting()
  local _, path = write_target({ "one", "two" })
  local nvim, address = open_editor(path)
  local process = start_hook(address, tool_payload("edit_file", { Path = path, Target = "two", Replacement = "TWO" }))
  wait_for_review(nvim)
  -- agy kills the hook once its timeout in hooks.json runs out.
  process:kill(9)
  check(
    "review closes after the hook is gone",
    vim.wait(6000, function()
      return not has_review(nvim)
    end, 100),
    true
  )
  check("buffer is the file again", nvim:lua("return vim.fn.expand('%:t')"), "target.txt")
  nvim:stop()
end

local function test_hook_command_points_at_the_script()
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  local command = nvim:lua("return require('ai_inline_diff').antigravity_hook_command()")
  check("command runs the script with nvim -l", command, "nvim -l " .. vim.fn.shellescape(hook_script))
  nvim:stop()
end

local function test_unit_replies_for_edited_reviews()
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  local replies = nvim:lua([[
    local hook = require("ai_inline_diff.agy_hook")
    local write = { name = "write_file", args = { Path = "/x", Content = "new\n" } }
    local edit = { name = "edit_file", args = { Path = "/x", Target = "a", Replacement = "b" } }
    return {
      edited_write = hook.accepted_reply(write, "old\n", "new\n", "mine\n"),
      back_to_original = hook.accepted_reply(edit, "a\n", "b\n", "a\n"),
      empty_target = hook.proposed_text({ name = "edit_file", args = { Target = "", Replacement = "b" } }, "a"),
    }
  ]])
  check("edited write_file rewrites Content", replies.edited_write, {
    decision = "allow",
    overwrite = { Content = "mine\n" },
  })
  check("accepting the original text denies the edit", replies.back_to_original.decision, "deny")
  check("an empty Target is not reviewed", replies.empty_target, nil)
  nvim:stop()
end

local function test_bad_payload_denies_with_the_error()
  local _, path = write_target({ "one" })
  local nvim, address = open_editor(path)
  local env = { NVIM = address, PATH = vim.env.PATH, HOME = vim.env.HOME }
  local result = vim
    .system({ "nvim", "-l", hook_script }, { stdin = "not json", env = env, clear_env = true, text = true })
    :wait(8000)
  local ok, reply = pcall(vim.json.decode, result.stdout or "")
  check("bad payload: deny", ok and reply.decision, "deny")
  check("bad payload: reason quotes it", ok and (reply.reason or ""):find("not json", 1, true) ~= nil, true)
  nvim:stop()
end

local function test_relative_path_uses_the_agent_cwd()
  local dir, path = write_target({ "one", "two" })
  local nvim, address = open_editor(path)
  local payload = tool_payload("edit_file", { Path = "target.txt", Target = "two", Replacement = "TWO" })
  payload.cwd = dir
  local process = start_hook(address, payload)
  check("relative Path opens a review", wait_for_review(nvim), true)
  nvim:input("<M-r>")
  hook_reply(process)
  nvim:stop()
end

local function test_unsaved_buffer_waits_for_save()
  local _, path = write_target({ "one", "two" })
  local nvim, address = open_editor(path)
  nvim:lua("vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'ONE' })")
  local process = start_hook(address, tool_payload("edit_file", { Path = path, Target = "two", Replacement = "TWO" }))
  vim.wait(800)
  check("no review over unsaved text", has_review(nvim), false)
  nvim:input("<Esc>:w<CR>")
  check("review opens after :w", wait_for_review(nvim), true)
  check("review starts from the saved file", review_lines(nvim), { "ONE", "TWO" })
  nvim:input("<M-a>")
  check("accepted after the wait", hook_reply(process), { decision = "allow" })
  nvim:stop()
end

test_hook_command_points_at_the_script()
test_without_neovim_allows()
test_accept_allows_unchanged_edit()
test_reject_denies()
test_edited_review_overwrites_the_whole_file()
test_dropped_change_is_left_out()
test_every_occurrence_is_replaced()
test_write_file_reviews_a_new_file()
test_calls_it_cannot_review_pass_through()
test_second_edit_waits_for_the_first_review()
test_review_closes_when_agy_stops_waiting()
test_unit_replies_for_edited_reviews()
test_bad_payload_denies_with_the_error()
test_relative_path_uses_the_agent_cwd()
test_unsaved_buffer_waits_for_save()
recorder:finish()
