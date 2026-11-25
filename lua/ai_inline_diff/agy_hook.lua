local M = {}

-- bin/agy-review-hook.lua polls every 200 ms; this much silence means agy
-- killed it (its hooks.json timeout ran out) and nobody waits for an answer.
local abandoned_after_ms = 3000
local allow = { decision = "allow" }
local rejected_reason =
  "The user rejected this edit in the Neovim review. Ask what they want changed instead of retrying it another way."

---@class AiInlineDiffAgyToolCall
---@field name string
---@field args table<string, unknown>

---@class AiInlineDiffAgyDeps
---@field open_review fun(opts: table): (table?, string?)
---@field has_review fun(): boolean
---@field close_review fun(id: string)
---@field read_file fun(path: string): string?
---@field find_loaded_buffer fun(path: string): integer?
---@field when_saved fun(buf: integer?, on_ready: fun()): fun()

---@class AiInlineDiffAgyRequest
---@field id string
---@field tool_call AiInlineDiffAgyToolCall
---@field path string
---@field state "queued" | "waiting_save" | "open" | "done"
---@field reply table?
---@field last_poll number
---@field cancel_save fun()?

---@param text string
---@param target string
---@param replacement string
---@return string
local function replace_every(text, target, replacement)
  local parts = {}
  local start = 1
  while true do
    local first, last = text:find(target, start, true)
    if not first then
      break
    end
    parts[#parts + 1] = text:sub(start, first - 1)
    parts[#parts + 1] = replacement
    start = last + 1
  end
  parts[#parts + 1] = text:sub(start)
  return table.concat(parts)
end

--- The file agy would write for `tool_call`, or nil when it is not an edit
--- to review. edit_file replaces every match of Target, as agy does.
--- Example: `proposed_text(payload.toolCall, read_file(path))`
---@param tool_call AiInlineDiffAgyToolCall
---@param disk_text string
---@return string?
function M.proposed_text(tool_call, disk_text)
  local args = tool_call.args or {}
  if tool_call.name == "write_file" then
    -- Artifacts are agy's own plans and notes, kept outside the project.
    if type(args.Content) == "string" and args.ArtifactMetadata == nil then
      return args.Content
    end
    return nil
  end
  if tool_call.name ~= "edit_file" or type(args.Target) ~= "string" or type(args.Replacement) ~= "string" then
    return nil
  end
  if args.Target == "" or not disk_text:find(args.Target, 1, true) then
    return nil
  end
  return replace_every(disk_text, args.Target, args.Replacement)
end

--- What agy gets when the review is accepted with `final_text` in it. A
--- changed review rewrites the call's arguments (agy's `overwrite`).
---@param tool_call AiInlineDiffAgyToolCall
---@param original_text string
---@param proposed_text string
---@param final_text string
---@return table
function M.accepted_reply(tool_call, original_text, proposed_text, final_text)
  if final_text == proposed_text then
    return allow
  end
  if final_text == original_text then
    return { decision = "deny", reason = rejected_reason }
  end
  if tool_call.name == "write_file" then
    return { decision = "allow", overwrite = { Content = final_text } }
  end
  -- The disk still holds original_text (the review refuses a stale accept),
  -- so replacing all of it is exact.
  return { decision = "allow", overwrite = { Target = original_text, Replacement = final_text } }
end

---@param raw_payload string
---@return table payload
local function decode_payload(raw_payload)
  local ok, payload = pcall(vim.json.decode, raw_payload, { luanil = { object = true, array = true } })
  if not ok or type(payload) ~= "table" then
    error(
      string.format("hook payload is not a JSON object: %s, expected agy's PreToolUse input", raw_payload:sub(1, 200)),
      0
    )
  end
  return payload
end

---@param payload table
---@return AiInlineDiffAgyToolCall?, string? path
local function reviewable_call(payload)
  local tool_call = payload.toolCall
  if type(tool_call) ~= "table" or type(tool_call.args) ~= "table" or type(tool_call.args.Path) ~= "string" then
    return nil
  end
  local path = tool_call.args.Path
  if path:sub(1, 1) ~= "/" and type(payload.cwd) == "string" then
    path = payload.cwd .. "/" .. path
  end
  return tool_call, vim.fs.normalize(path)
end

---@class AiInlineDiffAgyQueue
---@field deps AiInlineDiffAgyDeps
---@field requests table<string, AiInlineDiffAgyRequest>
---@field order string[] request ids, oldest first
---@field next_number integer
---@field watchdog uv.uv_timer_t?
local Queue = {}
Queue.__index = Queue

--- Review queue for agy's hook. init.lua builds `deps` from
--- review_session.lua, which owns the review windows.
--- Example: `local hook = agy_hook.new(deps); hook:start(raw)`
---@param deps AiInlineDiffAgyDeps
---@return AiInlineDiffAgyQueue
function M.new(deps)
  return setmetatable({ deps = deps, requests = {}, order = {}, next_number = 0 }, Queue)
end

---@param request AiInlineDiffAgyRequest
---@return string
local function review_id(request)
  return "agy-hook:" .. request.id
end

---@param id string
function Queue:forget(id)
  self.requests[id] = nil
  self.order = vim.tbl_filter(function(queued)
    return queued ~= id
  end, self.order)
end

---@param request AiInlineDiffAgyRequest
---@param reply table
function Queue:finish(request, reply)
  request.state = "done"
  request.reply = reply
  vim.schedule(function()
    self:pump()
  end)
end

---@param request AiInlineDiffAgyRequest
function Queue:open(request)
  request.cancel_save = nil
  local original = self.deps.read_file(request.path) or ""
  local proposed = M.proposed_text(request.tool_call, original)
  if not proposed then
    -- The file changed while waiting; agy reports the failed edit itself.
    self:finish(request, allow)
    return
  end
  request.state = "open"
  local _, open_err = self.deps.open_review({
    id = review_id(request),
    path = request.path,
    old_text = original,
    new_text = proposed,
    editable = true,
    on_accept = function(final_text)
      self:finish(request, M.accepted_reply(request.tool_call, original, proposed, final_text))
      -- agy writes once the hook answers; reload the open buffer then.
      vim.defer_fn(function()
        pcall(vim.cmd.checktime)
      end, 1000)
    end,
    on_reject = function()
      self:finish(request, { decision = "deny", reason = rejected_reason })
    end,
  })
  if open_err then
    vim.notify("Cannot open Antigravity inline diff: " .. open_err, vim.log.levels.ERROR)
    self:finish(request, { decision = "deny", reason = "Neovim could not show the review: " .. open_err })
  end
end

---@param request AiInlineDiffAgyRequest
function Queue:begin(request)
  request.state = "waiting_save"
  local ready = false
  local cancel = self.deps.when_saved(self.deps.find_loaded_buffer(request.path), function()
    ready = true
    self:open(request)
  end)
  if not ready then
    request.cancel_save = cancel
  end
end

--- Start the oldest queued request unless one is already being reviewed.
function Queue:pump()
  for _, id in ipairs(self.order) do
    local state = self.requests[id].state
    if state == "waiting_save" or state == "open" then
      return
    end
  end
  if self.deps.has_review() then
    return
  end
  for _, id in ipairs(self.order) do
    if self.requests[id].state == "queued" then
      self:begin(self.requests[id])
      return
    end
  end
end

---@param request AiInlineDiffAgyRequest
function Queue:abandon(request)
  self:forget(request.id)
  if request.state == "done" then
    return
  end
  if request.cancel_save then
    request.cancel_save()
  end
  if request.state == "open" then
    self.deps.close_review(review_id(request))
  end
  vim.notify(
    string.format(
      "Antigravity stopped waiting for the review of %s, so the edit was not applied. "
        .. "Raise the hook timeout in hooks.json for longer reviews.",
      vim.fn.fnamemodify(request.path, ":~:.")
    ),
    vim.log.levels.WARN,
    { title = "ai-inline-diff" }
  )
end

function Queue:check_abandoned()
  local now = vim.uv.now()
  for _, request in pairs(self.requests) do
    if now - request.last_poll > abandoned_after_ms then
      self:abandon(request)
    end
  end
  if next(self.requests) == nil and self.watchdog then
    self.watchdog:stop()
    self.watchdog:close()
    self.watchdog = nil
  end
  self:pump()
end

--- Returns `{ id }` while the edit waits for review, or `{ reply }` when
--- agy can go on at once (not an edit, or nothing to review).
---@param raw_payload string
---@return table
function Queue:start(raw_payload)
  local tool_call, path = reviewable_call(decode_payload(raw_payload))
  if not tool_call or not path or not M.proposed_text(tool_call, self.deps.read_file(path) or "") then
    return { reply = allow }
  end
  self.next_number = self.next_number + 1
  local request = {
    id = tostring(self.next_number),
    tool_call = tool_call,
    path = path,
    state = "queued",
    last_poll = vim.uv.now(),
  }
  self.requests[request.id] = request
  self.order[#self.order + 1] = request.id
  if not self.watchdog then
    self.watchdog = assert(vim.uv.new_timer())
    self.watchdog:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        self:check_abandoned()
      end)
    )
  end
  self:pump()
  return { id = request.id }
end

--- The decision for request `id` once the review ends, nil before that.
---@param id string
---@return table?
function Queue:poll(id)
  local request = self.requests[id]
  if not request then
    return { decision = "deny", reason = "Neovim no longer knows this review (id " .. tostring(id) .. ")" }
  end
  request.last_poll = vim.uv.now()
  if request.state ~= "done" then
    self:pump()
    return nil
  end
  self:forget(id)
  return request.reply
end

return M
