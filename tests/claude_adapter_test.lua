-- Run with: nvim -l tests/claude_adapter_test.lua
-- claudecode.nvim answers Claude's openDiff tool later, through a sender it
-- stores in _G.claude_deferred_responses[tostring(coroutine)] while the
-- coroutine waits. LuaLS does not know that foreign global, so these checks
-- pin down how setup_claude() uses it: the sender gets the reply exactly
-- once and is removed, an error inside the coroutine reaches the sender as
-- a JSON-RPC error, and a missing table changes nothing.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
local helpers = require("helpers.embedded_nvim")
local agent_plugins = require("helpers.agent_plugins")
local recorder = helpers.CheckRecorder.new()
local deps = agent_plugins.ensure(plugin_root .. "/tests/.deps")

---@param with_table boolean create _G.claude_deferred_responses first
---@param after_reply string Lua run in the coroutine after the reply arrives
---@return EmbeddedNvim
local function open_waiting_review(with_table, after_reply)
  local nvim = helpers.EmbeddedNvim.start(plugin_root)
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "old" }, path)
  nvim:lua(
    [[
    local deps, path, with_table, after_reply = ...
    for _, dir in ipairs(deps) do
      vim.opt.rtp:prepend(dir)
    end
    require("ai_inline_diff").setup_claude()
    vim.cmd.edit(path)
    _G.sent = {}
    _G.claude_deferred_responses = with_table and {} or nil
    local co = coroutine.create(function()
      local result = require("claudecode.diff").open_diff_blocking(path, path, "new\n", "tab", "client")
      assert(loadstring(after_reply))()
      return result
    end)
    _G.co_key = tostring(co)
    coroutine.resume(co)
    if with_table then
      _G.claude_deferred_responses[_G.co_key] = function(reply)
        table.insert(_G.sent, reply)
      end
    end
  ]],
    deps,
    path,
    with_table,
    after_reply
  )
  return nvim
end

---@param nvim EmbeddedNvim
---@return { sent: table[], sender_left: boolean, in_review: boolean }
local function state(nvim)
  return nvim:lua([[
    return {
      sent = _G.sent,
      sender_left = _G.claude_deferred_responses ~= nil and _G.claude_deferred_responses[_G.co_key] ~= nil,
      in_review = vim.b.ai_inline_diff_id ~= nil,
    }
  ]])
end

local function test_accept_reaches_sender_once()
  local nvim = open_waiting_review(true, "")
  local in_review = state(nvim).in_review
  recorder:check("review is open while Claude waits", in_review, true)
  nvim:input("<M-a>")
  local after = state(nvim)
  recorder:check("sender called once", #after.sent, 1)
  recorder:check("sender gets FILE_SAVED", after.sent[1] and after.sent[1].content[1].text, "FILE_SAVED")
  recorder:check("sender gets the proposed text", after.sent[1] and after.sent[1].content[2].text, "new\n")
  recorder:check("sender removed after use", after.sender_left, false)
  nvim:input("<M-a>")
  recorder:check("a second accept sends nothing", #state(nvim).sent, 1)
  nvim:stop()
end

local function test_reject_reaches_sender()
  local nvim = open_waiting_review(true, "")
  nvim:input("<M-r>")
  local after = state(nvim)
  recorder:check("reject: sender gets DIFF_REJECTED", after.sent[1] and after.sent[1].content[1].text, "DIFF_REJECTED")
  recorder:check("reject: sender removed", after.sender_left, false)
  nvim:stop()
end

local function test_coroutine_error_reaches_sender()
  local nvim = open_waiting_review(true, "error('tool failed after reply')")
  nvim:input("<M-a>")
  local reply = state(nvim).sent[1] or {}
  recorder:check("error: sender gets a JSON-RPC internal error", reply.error and reply.error.code, -32603)
  recorder:check(
    "error: message names the failure",
    tostring(reply.error and reply.error.data):find("tool failed", 1, true) ~= nil,
    true
  )
  nvim:stop()
end

local function test_missing_table_is_harmless()
  local nvim = open_waiting_review(false, "")
  nvim:input("<M-a>")
  local after = state(nvim)
  recorder:check("no table: review still closes", after.in_review, false)
  recorder:check("no table: nothing sent", #after.sent, 0)
  nvim:stop()
end

test_accept_reaches_sender_once()
test_reject_reaches_sender()
test_coroutine_error_reaches_sender()
test_missing_table_is_harmless()
recorder:finish()
