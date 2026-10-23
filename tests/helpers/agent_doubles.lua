-- Loaded inside a child Neovim by tests/scenarios_test.lua. Each agent is
-- replaced at the point where its Neovim plugin talks to the agent process,
-- so everything from that plugin inwards is the real code.

local M = {}

---@class AgentOutcome
---@field reply "accepted"|"rejected"|"pending"
---@field content string? text the agent ends up writing, nil if rejected

---@type table<string, fun(): AgentOutcome>
local outcome_readers = {}

---@param buf integer
---@return string
local function buffer_text(buf)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return vim.bo[buf].endofline and text .. "\n" or text
end

---@return integer? the open review buffer
local function review_buffer()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].ai_inline_diff_id then
      return buf
    end
  end
end

--- Claude Code calls the `openDiff` tool, which claudecode.nvim runs in a
--- coroutine and answers with FILE_SAVED plus the content, or DIFF_REJECTED.
---@param path string
---@param proposed string
function M.propose_claude(path, proposed)
  require("ai_inline_diff").setup_claude()
  local result
  coroutine.wrap(function()
    result = require("claudecode.diff").open_diff_blocking(path, path, proposed, "scenario", "client")
  end)()
  outcome_readers.claude = function()
    if not result then
      return { reply = "pending" }
    end
    local saved = result.content[1].text == "FILE_SAVED"
    return { reply = saved and "accepted" or "rejected", content = saved and result.content[2].text or nil }
  end
end

--- antigravity-cli.nvim tells the agent the decision through server.notify;
--- on accept this plugin also writes the file itself.
---@param path string
---@param proposed string
function M.propose_antigravity(path, proposed)
  local methods = {}
  require("antigravity-cli.server").notify = function(notification)
    methods[#methods + 1] = notification.method
  end
  require("ai_inline_diff").setup_antigravity()
  require("antigravity-cli.diff").open(path, proposed)
  outcome_readers.antigravity = function()
    local last = methods[#methods]
    if last == "ide/diffAccepted" then
      return { reply = "accepted", content = table.concat(vim.fn.readfile(path, "b"), "\n") }
    end
    return { reply = last == "ide/diffRejected" and "rejected" or "pending" }
  end
end

---@class FakeOpencodeServer
---@field cwd string
---@field choices string[]
local FakeOpencodeServer = {}
FakeOpencodeServer.__index = FakeOpencodeServer

---@param id string
---@param choice "once"|"always"|"reject"
---@return { catch: fun(self, on_error: fun(err: unknown)) }
function FakeOpencodeServer:permit(id, choice)
  self.choices[#self.choices + 1] = choice
  return { catch = function() end }
end

--- OpenCode sends `permission.asked` over its event stream, which
--- opencode.nvim turns into a User autocmd; the answer goes back through
--- opencode.server. OpenCode applies its own patch, so the content it would
--- write is what the read-only review showed.
---@param path string
---@param patch string unified diff as OpenCode sends it
function M.propose_opencode(path, patch)
  local server = setmetatable({ cwd = vim.fs.dirname(path), choices = {} }, FakeOpencodeServer)
  package.loaded["opencode.server"] = {
    new = function()
      local promise = {}
      function promise:next(callback)
        callback(server)
        return promise
      end
      function promise:catch()
        return promise
      end
      return promise
    end,
  }
  require("ai_inline_diff").setup_opencode()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "OpencodeEvent:permission.asked",
    data = {
      url = "http://fake-opencode",
      event = {
        type = "permission.asked",
        properties = { id = "permission-1", permission = "edit", metadata = { filepath = path, diff = patch } },
      },
    },
  })
  local shown = review_buffer() and buffer_text(review_buffer()) or nil
  outcome_readers.opencode = function()
    local choice = server.choices[#server.choices]
    if choice == "once" then
      return { reply = "accepted", content = shown }
    end
    return { reply = choice == "reject" and "rejected" or "pending" }
  end
end

---@class FakeOpencodeV2Server
---@field url string
---@field replies { session_id: string, request_id: string, choice: string }[]
local FakeOpencodeV2Server = {}
FakeOpencodeV2Server.__index = FakeOpencodeV2Server

-- v2 replies to /api/session/{sessionID}/permission/{requestID}/reply, so a
-- v1-style permit(id, choice) call lands here with the arguments shifted.
---@param session_id string
---@param request_id string
---@param choice "once"|"always"|"reject"
---@return { catch: fun(self, on_error: fun(err: unknown)) }
function FakeOpencodeV2Server:permit(session_id, request_id, choice)
  self.replies[#self.replies + 1] = { session_id = session_id, request_id = request_id, choice = choice }
  return { catch = function() end }
end

---@param server table
local function serve_opencode(server)
  package.loaded["opencode.server"] = {
    new = function()
      local promise = {}
      function promise:next(callback)
        callback(server)
        return promise
      end
      function promise:catch()
        return promise
      end
      return promise
    end,
  }
end

--- OpenCode 2.x sends `{ id, type, data }` events. An edit permission carries
--- one entry per file in data.metadata.files, each `{ file, patch, status }`
--- (from OpenCode 2.1.4's edit, write and patch tools). The server object has
--- no `cwd`, and the reply needs the session id. The 2.x daemon requires
--- credentials that the autocmd does not carry, so like the real one,
--- `new(url)` fails with 401 and only `connected` can answer.
---@param path string
---@param patch string unified diff for files[1]
---@param extra_files integer? more entries in metadata.files
function M.propose_opencode_v2(path, patch, extra_files)
  local server = setmetatable({ url = "http://fake-opencode", replies = {} }, FakeOpencodeV2Server)
  package.loaded["opencode.server"] = {
    connected = server,
    new = function()
      local promise = {}
      function promise:next()
        return promise
      end
      function promise:catch(on_error)
        on_error('{"_tag":"UnauthorizedError","message":"Authentication required"}')
        return promise
      end
      return promise
    end,
  }
  local files = { { file = path, patch = patch, status = "modified", additions = 1, deletions = 1 } }
  for index = 1, extra_files or 0 do
    files[#files + 1] = { file = path .. ".extra" .. index, patch = patch, status = "modified" }
  end
  require("ai_inline_diff").setup_opencode()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "OpencodeEvent:permission.asked",
    data = {
      url = "http://fake-opencode",
      event = {
        id = "event-1",
        type = "permission.asked",
        data = {
          id = "permission-1",
          sessionID = "session-1",
          action = "edit",
          resources = { path },
          metadata = { files = files },
        },
      },
    },
  })
  local shown = review_buffer() and buffer_text(review_buffer()) or nil
  outcome_readers["opencode-v2"] = function()
    local last = server.replies[#server.replies]
    local addressed = last and last.session_id == "session-1" and last.request_id == "permission-1"
    if addressed and last.choice == "once" then
      return { reply = "accepted", content = shown }
    end
    return { reply = addressed and last.choice == "reject" and "rejected" or "pending" }
  end
end

---@param agent "claude"|"antigravity"|"opencode"|"opencode-v2"
---@return AgentOutcome
function M.outcome(agent)
  return outcome_readers[agent]()
end

return M
