local M = {}

local review_session = require("ai_inline_diff.review_session")
local target_file = require("ai_inline_diff.target_file")
local unified_patch = require("ai_inline_diff.unified_patch")
local opencode_event = require("ai_inline_diff.opencode_event")
local save_wait = require("ai_inline_diff.save_wait")

-- false while a permission waits for the user, true once answered anywhere.
local resolved_permissions = {} ---@type table<string, boolean>
-- Cancels for OpenCode edits waiting on a buffer with unsaved changes.
local save_waits = {} ---@type table<string, fun()>

---@alias AiInlineDiffOpencodeReply fun(choice: string, on_failure: fun()?)

---@param url unknown
---@param id unknown
---@return string
local function permission_key(url, id)
  return tostring(url) .. ":" .. tostring(id)
end

local function notify_permission_error(err)
  vim.notify("Failed to answer OpenCode permission: " .. tostring(err), vim.log.levels.ERROR)
end

---@param args { data: { url: string, event: table } }
local function on_permission_replied(args)
  local key = permission_key(args.data.url, opencode_event.replied_request_id(args.data.event))
  resolved_permissions[key] = true
  if save_waits[key] then
    save_waits[key]()
    save_waits[key] = nil
  end
  review_session.resolve("opencode:" .. key, false, false)
  vim.defer_fn(function()
    resolved_permissions[key] = nil
  end, 60000)
end

--- The functions that answer one permission request: `submit(choice,
--- on_failure)` and `reject_with_retry()`, which offers to retry on failure.
---@param server table
---@param edit AiInlineDiffOpencodeEdit
---@param key string
---@return AiInlineDiffOpencodeReply submit, fun() reject_with_retry
local function permission_replier(server, edit, key)
  local function submit(choice, on_failure)
    if resolved_permissions[key] then
      return
    end
    opencode_event.permit(server, edit, choice):catch(function(err)
      notify_permission_error(err)
      if not resolved_permissions[key] and on_failure then
        on_failure()
      end
    end)
  end

  local function reject_with_retry()
    local function retry_reject()
      vim.ui.select({ "Retry reject", "Leave pending" }, { prompt = "OpenCode rejection failed" }, function(choice)
        if choice == "Retry reject" and not resolved_permissions[key] then
          submit("reject", retry_reject)
        end
      end)
    end
    submit("reject", retry_reject)
  end

  return submit, reject_with_retry
end

---@param path string
---@param proposed string
---@param key string
---@param submit AiInlineDiffOpencodeReply
---@param reject_with_retry fun()
local function review_from_disk(path, proposed, key, submit, reject_with_retry)
  local id = "opencode:" .. key
  local original = target_file.read(path) or ""

  local function show_review()
    if resolved_permissions[key] then
      return
    end
    local current = review_session.current_id()
    if current and current ~= id then
      vim.notify("OpenCode edit rejected because another AI review is active", vim.log.levels.WARN)
      reject_with_retry()
      return
    end

    local function reply(choice)
      submit(choice, show_review)
    end

    local _, open_err = review_session.open({
      id = id,
      path = path,
      old_text = original,
      new_text = proposed,
      editable = false,
      on_accept = function()
        reply("once")
      end,
      on_reject = function()
        reply("reject")
      end,
    })
    if open_err then
      vim.notify("Cannot open OpenCode inline diff: " .. open_err, vim.log.levels.ERROR)
      reply("reject")
    end
  end
  show_review()
end

---@param server table
---@param edit AiInlineDiffOpencodeEdit
---@param key string
local function review_with_server(server, edit, key)
  if resolved_permissions[key] then
    return
  end
  local submit, reject_with_retry = permission_replier(server, edit, key)

  -- OpenCode 2.x servers have no cwd; target_file.resolve() then tries
  -- Neovim's.
  local path = target_file.resolve(edit.filepath, server.cwd)
  -- OpenCode writes the content it computed when it asked, from the file
  -- as it was then; edits saved while the review waits get overwritten.
  -- So the proposal comes from that file, and the review compares it
  -- with what is on disk once the buffer is saved.
  local proposed, patch_err = unified_patch.apply(target_file.read(path) or "", edit.diff)
  if not proposed then
    vim.notify(
      "OpenCode diff could not be rendered; answer the pending permission in its terminal: " .. patch_err,
      vim.log.levels.WARN
    )
    return
  end

  local ready = false
  local cancel = save_wait.when_saved(target_file.loaded_buffer(path), function()
    ready = true
    save_waits[key] = nil
    if not resolved_permissions[key] then
      review_from_disk(path, proposed, key, submit, reject_with_retry)
    end
  end)
  -- A clean buffer runs the review before when_saved returns.
  if not ready then
    save_waits[key] = cancel
  end
end

---@param args { data: { url: string, event: table } }
local function on_permission_asked(args)
  local edit, unreviewable = opencode_event.edit_request(args.data.event)
  if not edit then
    if unreviewable then
      vim.notify(
        "OpenCode edit not shown inline (" .. unreviewable .. "); answer it in OpenCode or in its permission prompt",
        vim.log.levels.WARN
      )
    end
    return
  end

  local key = permission_key(args.data.url, edit.id)
  resolved_permissions[key] = false
  opencode_event.with_server(args.data.url, function(server)
    review_with_server(server, edit, key)
  end, function(err)
    vim.notify("Failed to review OpenCode edit: " .. tostring(err), vim.log.levels.ERROR)
  end)
end

--- Review each single-file OpenCode `edit` permission inline, replacing
--- opencode.nvim's own `OpencodeEdits` handling.
function M.setup()
  pcall(vim.api.nvim_del_augroup_by_name, "OpencodeEdits")
  local group = vim.api.nvim_create_augroup("AiInlineOpencodeEdits", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "OpencodeEvent:permission.asked", "OpencodeEvent:permission.replied" },
    callback = function(args)
      if args.data.event.type == "permission.replied" then
        on_permission_replied(args)
        return
      end
      on_permission_asked(args)
    end,
    desc = "Review OpenCode edits inline",
  })
end

return M
