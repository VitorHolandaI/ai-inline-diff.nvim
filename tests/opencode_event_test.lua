-- Run with: nvim -l tests/opencode_event_test.lua
-- Checks lua/ai_inline_diff/opencode_event.lua on both event shapes: OpenCode
-- 1.x `{ type, properties }` and 2.x `{ id, type, data }` (as opencode.nvim
-- main and OpenCode 2.1.4 send them), including the replies.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
vim.opt.rtp:prepend(plugin_root)
local recorder = require("helpers.embedded_nvim").CheckRecorder.new()
local opencode_event = require("ai_inline_diff.opencode_event")

local function v1_asked(permission, metadata)
  return { type = "permission.asked", properties = { id = 7, permission = permission, metadata = metadata } }
end

local function v2_asked(action, metadata)
  return {
    id = "event-1",
    type = "permission.asked",
    data = {
      id = "permission-1",
      sessionID = "session-1",
      action = action,
      resources = { "a.lua" },
      metadata = metadata,
    },
  }
end

local one_file = { files = { { file = "/p/a.lua", patch = "@@ -1 +1 @@\n-a\n+b\n", status = "modified" } } }

local cases = {
  {
    name = "1.x edit",
    event = v1_asked("edit", { filepath = "a.lua", diff = "D" }),
    edit = { id = 7, filepath = "a.lua", diff = "D" },
  },
  { name = "1.x non-edit permission", event = v1_asked("bash", nil) },
  {
    name = "2.x edit",
    event = v2_asked("edit", one_file),
    edit = { id = "permission-1", session_id = "session-1", filepath = "/p/a.lua", diff = one_file.files[1].patch },
  },
  { name = "2.x non-edit action", event = v2_asked("bash", nil) },
  { name = "2.x edit without diff", event = v2_asked("edit", nil), reason = "no diff" },
  {
    name = "2.x edit over two files",
    event = v2_asked("edit", { files = { one_file.files[1], one_file.files[1] } }),
    reason = "2 files",
  },
  { name = "other event types", event = { type = "session.status", data = {} } },
  { name = "unknown shape", event = { type = "permission.asked" }, reason = "unknown event shape" },
}

for _, case in ipairs(cases) do
  local edit, reason = opencode_event.edit_request(case.event)
  recorder:check(case.name .. ": edit", edit, case.edit)
  if case.reason then
    recorder:check(case.name .. ": reason", reason ~= nil and reason:find(case.reason, 1, true) ~= nil, true)
  else
    recorder:check(case.name .. ": no reason", reason, nil)
  end
end

recorder:check(
  "1.x replied id",
  opencode_event.replied_request_id({ type = "permission.replied", properties = { requestID = 7 } }),
  7
)
recorder:check(
  "2.x replied id",
  opencode_event.replied_request_id({ type = "permission.replied", data = { requestID = "permission-1" } }),
  "permission-1"
)

---@class RecordingServer
---@field calls table[]
local RecordingServer = {}
RecordingServer.__index = RecordingServer
function RecordingServer:permit(...)
  self.calls[#self.calls + 1] = { ... }
  return {}
end

local v1_server = setmetatable({ calls = {} }, RecordingServer)
opencode_event.permit(v1_server, { id = 7, filepath = "a", diff = "d" }, "once")
recorder:check("1.x permit(id, choice)", v1_server.calls, { { 7, "once" } })

local v2_server = setmetatable({ calls = {} }, RecordingServer)
opencode_event.permit(
  v2_server,
  { id = "permission-1", session_id = "session-1", filepath = "a", diff = "d" },
  "reject"
)
recorder:check("2.x permit(session, id, choice)", v2_server.calls, { { "session-1", "permission-1", "reject" } })

recorder:finish()
