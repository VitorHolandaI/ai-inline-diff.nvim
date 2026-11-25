-- Antigravity (agy) PreToolUse hook: holds edit_file/write_file until the
-- edit is reviewed in the Neovim that owns this terminal ($NVIM).
-- hooks.json runs it as
--   "command": "nvim -l /path/to/ai-inline-diff.nvim/bin/agy-review-hook.lua"
-- agy reads the decision from stdout. An empty reply or a crash blocks the
-- edit, so every path ends in a printed decision.

local poll_interval_ms = 200
local allow = { decision = "allow" }

---@param reply table
local function answer(reply)
  io.stdout:write(vim.json.encode(reply), "\n")
end

---@param message string
local function warn(message)
  io.stderr:write("agy-review-hook: ", message, "\n")
end

---@param channel integer
---@param code string
---@param ... unknown
---@return unknown
local function call_editor(channel, code, ...)
  return vim.rpcrequest(channel, "nvim_exec_lua", code, { ... })
end

---@param channel integer
---@param raw_payload string
---@return table reply
local function review_in_editor(channel, raw_payload)
  local started = call_editor(channel, 'return require("ai_inline_diff").antigravity_hook_start(...)', raw_payload)
  if type(started) ~= "table" then
    error(string.format("antigravity_hook_start returned %s, expected a table", vim.inspect(started)), 0)
  end
  if started.reply then
    return started.reply
  end
  while true do
    vim.uv.sleep(poll_interval_ms)
    local reply = call_editor(channel, 'return require("ai_inline_diff").antigravity_hook_poll(...)', started.id)
    if type(reply) == "table" then
      return reply
    end
  end
end

local raw_payload = io.stdin:read("*a")
local server = vim.env.NVIM
-- Outside Neovim there is nowhere to review, so agy behaves as without us.
if not server or server == "" then
  answer(allow)
  return
end

local connected, channel = pcall(vim.fn.sockconnect, "pipe", server, { rpc = true })
if not connected or channel == 0 then
  warn(string.format("cannot connect to $NVIM '%s': %s; edit allowed unreviewed", server, tostring(channel)))
  answer(allow)
  return
end

local has_plugin = pcall(call_editor, channel, 'return require("ai_inline_diff") ~= nil')
if not has_plugin then
  warn("ai_inline_diff is not loaded in the Neovim at $NVIM; edit allowed unreviewed")
  answer(allow)
  return
end

-- Past this point the review may already be on screen, so a failure denies
-- rather than letting the edit through unseen.
local ok, reply = pcall(review_in_editor, channel, raw_payload)
if not ok then
  warn(tostring(reply))
  answer({ decision = "deny", reason = "The Neovim review failed: " .. tostring(reply) })
  return
end
answer(reply)
