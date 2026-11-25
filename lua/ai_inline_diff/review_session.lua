local M = {}

local target_file = require("ai_inline_diff.target_file")
local find_editor_window = require("ai_inline_diff.windows").find_editor_window
local review_keys = require("ai_inline_diff.review_keys")
local review_selection = require("ai_inline_diff.review_selection")
local review_changes = require("ai_inline_diff.review_changes")
local text = require("ai_inline_diff.text")
local live_changes = require("ai_inline_diff.live_changes")

local split_text = text.split
local join_lines = text.join

---@class AiInlineDiffReviewOpts
---@field id string unique per agent request, e.g. "claude:<tab name>"
---@field path string
---@field old_text string
---@field new_text string
---@field editable boolean? false for agents that only take the edit whole
---@field on_accept fun(final_text: string)
---@field on_reject fun()
---@field claude_tab_name string?
---@field client_id string?

---@class AiInlineDiffReview: AiInlineDiffReviewState
---@field id string
---@field path string
---@field previous_buf integer
---@field previous_cursor integer[]
---@field previous_signcolumn string
---@field on_accept fun(final_text: string)
---@field on_reject fun()
---@field client_id string?
---@field resolving boolean?
---@field release_terminal_keys fun()?

local reviews = {} ---@type table<string, AiInlineDiffReview>
local current_review ---@type string?

-- A fixed id makes snacks.nvim replace the box instead of stacking a new
-- one for every review.
local review_keys_hint_id = "ai_inline_diff_review_keys"

-- The hint only applies while a review is open. Other notifiers have no
-- hide-by-id, so there it just times out.
local function close_review_keys_hint()
  local ok, notifier = pcall(require, "snacks.notifier")
  if ok then
    notifier.hide(review_keys_hint_id)
  end
end

---@param buf integer
---@return string
local function get_buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" and vim.b[buf].ai_inline_diff_empty then
    return ""
  end
  return join_lines(lines, vim.bo[buf].endofline, vim.b[buf].ai_inline_diff_line_ending)
end

---@param review AiInlineDiffReview
local function restore_review(review)
  reviews[review.id] = nil
  if review.release_terminal_keys then
    review.release_terminal_keys()
    review.release_terminal_keys = nil
  end
  if current_review == review.id then
    current_review = nil
  end

  if vim.api.nvim_win_is_valid(review.win) then
    if vim.api.nvim_win_get_buf(review.win) == review.buf and vim.api.nvim_buf_is_valid(review.previous_buf) then
      vim.api.nvim_win_set_buf(review.win, review.previous_buf)
      local line_count = vim.api.nvim_buf_line_count(review.previous_buf)
      local cursor = { math.min(review.previous_cursor[1], math.max(line_count, 1)), review.previous_cursor[2] }
      pcall(vim.api.nvim_win_set_cursor, review.win, cursor)
    end
    vim.wo[review.win].signcolumn = review.previous_signcolumn
  end

  if vim.api.nvim_buf_is_valid(review.buf) then
    vim.api.nvim_buf_delete(review.buf, { force = true })
  end
end

---@param review AiInlineDiffReview
---@return boolean
local function target_changed_during_review(review)
  local disk_text = target_file.read(review.path) or ""
  if disk_text ~= review.original_text then
    return true
  end
  -- Only unsaved edits count: a reload (checktime, live_changes) bumps
  -- changedtick too, and it brings in the agent's own last write.
  local target_buf = target_file.loaded_buffer(review.path)
  return target_buf ~= nil and vim.bo[target_buf].modified
end

--- End review `id`, restoring the window, and tell the agent unless
--- `invoke_callback` is false (the agent already answered elsewhere).
---@param id string
---@param accepted boolean
---@param invoke_callback boolean?
---@return boolean resolved false when unknown, already ending, or stale
function M.resolve(id, accepted, invoke_callback)
  local review = reviews[id]
  if not review or review.resolving then
    return false
  end

  if accepted and target_changed_during_review(review) then
    vim.notify(
      "AI edit is stale: the target changed during review; reject it and request a new edit",
      vim.log.levels.ERROR
    )
    return false
  end

  review.resolving = true
  close_review_keys_hint()
  local proposed_text = get_buffer_text(review.buf)
  if accepted then
    live_changes.expect_accepted_write(review.path, proposed_text)
  end
  vim.bo[review.buf].modified = false
  restore_review(review)

  if invoke_callback ~= false then
    local callback = accepted and review.on_accept or review.on_reject
    local ok, err = pcall(callback, proposed_text)
    if not ok then
      vim.notify("Failed to resolve AI edit: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  return true
end

---@param opts AiInlineDiffReviewOpts
---@return integer buf, AiInlineDiffHunk[] hunks
local function create_review_buffer(opts)
  local old_lines, old_has_eol = split_text(opts.old_text)
  local new_lines, new_has_eol, new_line_ending = split_text(opts.new_text)
  local normalized_old = join_lines(old_lines, old_has_eol)
  local normalized_new = join_lines(new_lines, new_has_eol)
  -- result_type = indices always yields a list; nil only comes with on_hunk.
  local hunks = vim.text.diff(normalized_old, normalized_new, {
    algorithm = "histogram",
    result_type = "indices",
  }) --[[@as AiInlineDiffHunk[] ]]

  local buf = vim.api.nvim_create_buf(false, true)
  local safe_id = tostring(opts.id):gsub("[^%w_.-]", "_")
  local name = string.format("ai-inline-diff://%s/%s", safe_id, vim.fs.basename(opts.path))
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].undofile = false
  vim.bo[buf].endofline = new_has_eol
  vim.bo[buf].fixendofline = false
  vim.bo[buf].fileformat = new_line_ending == "\r\n" and "dos" or "unix"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #new_lines == 0 and { "" } or new_lines)
  vim.bo[buf].modifiable = opts.editable ~= false
  vim.bo[buf].modified = false
  vim.b[buf].ai_inline_diff_empty = #new_lines == 0
  vim.b[buf].ai_inline_diff_id = opts.id
  vim.b[buf].ai_inline_diff_line_ending = new_line_ending
  if opts.claude_tab_name then
    vim.b[buf].claudecode_diff_tab_name = opts.claude_tab_name
  end

  local filetype = vim.filetype.match({ filename = opts.path })
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf, hunks
end

---@param review AiInlineDiffReview
local function attach_review_controls(review)
  local function accept()
    M.resolve(review.id, true)
  end
  local function reject()
    M.resolve(review.id, false)
  end

  local resolvers = { accept = accept, reject = reject }
  review.release_terminal_keys = review_keys.map_terminal(resolvers)
  review_keys.map(review.buf, {
    accept = accept,
    reject = reject,
    keep_change = function()
      review_changes.keep_selected(review, resolvers)
    end,
    drop_change = function()
      review_changes.drop_selected(review, resolvers)
    end,
    next_change = function()
      review_selection.select_adjacent(review, "next")
    end,
    previous_change = function()
      review_selection.select_adjacent(review, "previous")
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = review.buf,
    callback = accept,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = review.buf,
    once = true,
    callback = function()
      if reviews[review.id] and not review.resolving then
        M.resolve(review.id, false)
      end
    end,
  })
end

---@param review AiInlineDiffReview
local function show_keys_hint(review)
  -- Read-only reviews (OpenCode) take or refuse the whole edit, so the hint
  -- leaves out the per-change keys. It stays a minute: the default few
  -- seconds were gone before the keys could be read.
  -- One short line per key: the notification box cuts long lines short.
  local hint = { "AI edit: review keys", "Alt-n / Alt-p  next / previous change" }
  if review.editable then
    hint[#hint + 1] = "Alt-y / Alt-x  keep / drop this change"
  end
  vim.list_extend(hint, { "Alt-a          accept all", "Alt-r          reject all" })
  vim.notify(
    table.concat(hint, "\n"),
    vim.log.levels.INFO,
    { title = "ai-inline-diff", timeout = 60000, id = review_keys_hint_id }
  )
end

--- Replace an editor window with the proposed file and wait for the user.
--- An older review still open is rejected first: only one runs at a time.
--- Example: `review_session.open({ id = id, path = p, old_text = a, ... })`
---@param opts AiInlineDiffReviewOpts
---@return AiInlineDiffReview?, string? error
function M.open(opts)
  if current_review and reviews[current_review] then
    M.resolve(current_review, false)
  end

  local win = find_editor_window(opts.path)
  if not win then
    return nil, "No editor window is available for the inline diff"
  end

  local buf, hunks = create_review_buffer(opts)
  local review = {
    id = opts.id,
    buf = buf,
    win = win,
    path = opts.path,
    hunks = hunks,
    previous_buf = vim.api.nvim_win_get_buf(win),
    previous_cursor = vim.api.nvim_win_get_cursor(win),
    previous_signcolumn = vim.wo[win].signcolumn,
    original_text = opts.old_text,
    editable = opts.editable ~= false,
    on_accept = opts.on_accept,
    on_reject = opts.on_reject,
    client_id = opts.client_id,
  }
  reviews[opts.id] = review
  current_review = opts.id

  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].signcolumn = "yes"
  review_changes.render(review)

  vim.api.nvim_set_current_win(win)
  if hunks[1] then
    review_selection.select_hunk(win, buf, hunks[1])
  end

  attach_review_controls(review)
  show_keys_hint(review)
  return review
end

--- Whether review `id` is still open.
---@param id string?
---@return boolean
function M.is_open(id)
  return id ~= nil and reviews[id] ~= nil
end

--- Id of the review opened last, if it is still open.
---@return string?
function M.current_id()
  return current_review
end

--- Reject every open review whose id starts with `prefix` and that
--- `predicate` (optional) accepts. Returns how many were rejected.
---@param prefix string
---@param predicate (fun(review: AiInlineDiffReview): boolean)?
---@return integer
function M.reject_matching(prefix, predicate)
  local ids = {}
  for id, review in pairs(reviews) do
    if id:sub(1, #prefix) == prefix and (not predicate or predicate(review)) then
      ids[#ids + 1] = id
    end
  end
  for _, id in ipairs(ids) do
    M.resolve(id, false)
  end
  return #ids
end

--- What an agent plugin's "close all diffs" should return once this plugin
--- also rejected `count` inline reviews.
---@param result unknown the agent plugin's own return value
---@param count integer
---@return unknown
function M.close_result(result, count)
  return type(result) == "number" and result + count or result or count
end

return M
