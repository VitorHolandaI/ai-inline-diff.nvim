local M = {}

---@class AiInlineDiffOpencodeEdit
---@field id string|integer permission request id
---@field session_id string? set for OpenCode 2.x, which replies per session
---@field filepath string
---@field diff string unified diff, or a `*** Begin Patch` block in 1.x

-- OpenCode 1.x events are `{ type, properties }` with the edit in
-- properties.metadata.{filepath,diff}.
---@param event table
---@return AiInlineDiffOpencodeEdit?
local function edit_from_v1(event)
  local properties = event.properties
  if properties.permission ~= "edit" or not properties.metadata then
    return nil
  end
  return { id = properties.id, filepath = properties.metadata.filepath, diff = properties.metadata.diff }
end

-- OpenCode 2.x events are `{ id, type, data }`; data.action names the
-- permission and data.metadata.files holds `{ file, patch, status }` per file
-- (edit, write and patch tools in 2.1.4). Edits without a diff, like an
-- edit whose oldString did not match, carry no metadata.
---@param event table
---@return AiInlineDiffOpencodeEdit?, string? reason it cannot be reviewed
local function edit_from_v2(event)
  local data = event.data
  if data.action ~= "edit" then
    return nil
  end
  local files = data.metadata and data.metadata.files
  if type(files) ~= "table" or #files == 0 then
    return nil, "the edit request carries no diff"
  end
  if #files > 1 then
    -- One reply covers every file, and the review shows a single one.
    return nil, string.format("the edit touches %d files, expected 1", #files)
  end
  local file = files[1]
  return { id = data.id, session_id = data.sessionID, filepath = file.file, diff = file.patch }
end

--- Read an edit permission request from either OpenCode event shape.
--- Example: `local edit, reason = edit_request(args.data.event)`
---@param event table
---@return AiInlineDiffOpencodeEdit?, string? reason why an edit cannot be reviewed
function M.edit_request(event)
  if event.type ~= "permission.asked" then
    return nil
  end
  if event.data then
    return edit_from_v2(event)
  end
  if event.properties then
    return edit_from_v1(event)
  end
  return nil, string.format("unknown event shape %s, expected properties (1.x) or data (2.x)", vim.inspect(event))
end

---@param event table a permission.replied event
---@return string|integer? the id of the request that was answered
function M.replied_request_id(event)
  local fields = event.data or event.properties
  return fields and fields.requestID
end

--- Answer a permission request in the form the OpenCode version expects.
---@param server table an opencode.server.Server
---@param edit AiInlineDiffOpencodeEdit
---@param choice "once"|"always"|"reject"
---@return table promise with :catch()
function M.permit(server, edit, choice)
  if edit.session_id then
    return server:permit(edit.session_id, edit.id, choice)
  end
  return server:permit(edit.id, choice)
end

return M
