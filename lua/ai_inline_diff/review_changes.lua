local M = {}

local text = require("ai_inline_diff.text")
local review_selection = require("ai_inline_diff.review_selection")

local namespace = vim.api.nvim_create_namespace("AiInlineDiff")
-- Extmarks move with the text, so a kept change stays marked after an
-- earlier change is dropped and the rows below it shift.
local kept_namespace = vim.api.nvim_create_namespace("AiInlineDiffKept")

---@class AiInlineDiffReviewState
---@field buf integer
---@field win integer
---@field hunks AiInlineDiffHunk[]
---@field original_text string
---@field editable boolean

---@class AiInlineDiffResolvers
---@field accept fun()
---@field reject fun()

---@param buf integer
---@param hunk AiInlineDiffHunk
---@param old_lines string[]
local function render_removed_lines(buf, hunk, old_lines)
  local old_start, old_count, new_start, new_count = unpack(hunk)
  local virtual_lines = {}
  for index = old_start, old_start + old_count - 1 do
    virtual_lines[#virtual_lines + 1] = { { "- ", "DiffDelete" }, { old_lines[index] or "", "DiffDelete" } }
  end
  vim.api.nvim_buf_set_extmark(buf, namespace, math.max(new_start - 1, 0), 0, {
    strict = false,
    virt_lines = virtual_lines,
    virt_lines_above = new_count > 0 or new_start == 0,
  })
end

---@param review AiInlineDiffReviewState
---@param hunk AiInlineDiffHunk
---@return boolean
local function is_kept(review, hunk)
  local first, last = review_selection.hunk_rows(hunk, vim.api.nvim_buf_line_count(review.buf))
  local marks = vim.api.nvim_buf_get_extmarks(review.buf, kept_namespace, { first - 1, 0 }, { last - 1, -1 }, {})
  return #marks > 0
end

--- Draw removed lines as virtual lines and proposed lines as DiffAdd, with
--- a "✓" sign on changes kept with <M-y>.
---@param review AiInlineDiffReviewState
function M.render(review)
  vim.api.nvim_buf_clear_namespace(review.buf, namespace, 0, -1)
  local old_lines = text.split(review.original_text)
  local line_count = vim.api.nvim_buf_line_count(review.buf)
  for _, hunk in ipairs(review.hunks) do
    if hunk[2] > 0 then
      render_removed_lines(review.buf, hunk, old_lines)
    end
    local sign = is_kept(review, hunk) and "✓" or "+"
    for index = hunk[3], math.min(hunk[3] + hunk[4] - 1, line_count) do
      if index >= 1 then
        vim.api.nvim_buf_set_extmark(review.buf, namespace, index - 1, 0, {
          line_hl_group = "DiffAdd",
          sign_text = sign,
          sign_hl_group = "DiffAdd",
        })
      end
    end
  end
end

-- Diffs the original against what the buffer holds now, so hand edits and
-- dropped changes are both reflected.
---@param review AiInlineDiffReviewState
local function refresh(review)
  local old_lines = text.split(review.original_text)
  local new_lines = vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)
  review.hunks = vim.diff(text.join(old_lines, true), text.join(new_lines, true), {
    algorithm = "histogram",
    result_type = "indices",
  })
  M.render(review)
end

---@param review AiInlineDiffReviewState
---@return AiInlineDiffHunk?
local function selected_hunk(review)
  local row = math.min(vim.fn.line("v", review.win), vim.fn.line(".", review.win))
  local line_count = vim.api.nvim_buf_line_count(review.buf)
  for _, hunk in ipairs(review.hunks) do
    local first, last = review_selection.hunk_rows(hunk, line_count)
    if row >= first and row <= last then
      return hunk
    end
  end
end

---@param review AiInlineDiffReviewState
---@param hunk AiInlineDiffHunk
local function restore_original_lines(review, hunk)
  local old_lines = text.split(review.original_text)
  local original = vim.list_slice(old_lines, hunk[1], hunk[1] + hunk[2] - 1)
  if hunk[4] > 0 then
    vim.api.nvim_buf_set_lines(review.buf, hunk[3] - 1, hunk[3] - 1 + hunk[4], false, original)
  else
    vim.api.nvim_buf_set_lines(review.buf, hunk[3], hunk[3], false, original)
  end
end

-- Selects the next undecided change at or after `from_row`, wrapping
-- around. With none left, the review ends: kept changes are accepted, and
-- a review whose changes were all dropped is rejected.
---@param review AiInlineDiffReviewState
---@param from_row integer
---@param resolvers AiInlineDiffResolvers
local function continue_or_finish(review, from_row, resolvers)
  refresh(review)
  local line_count = vim.api.nvim_buf_line_count(review.buf)
  local pending = vim.tbl_filter(function(hunk)
    return not is_kept(review, hunk)
  end, review.hunks)
  if #pending == 0 then
    local finish = #review.hunks > 0 and resolvers.accept or resolvers.reject
    finish()
    return
  end
  for _, hunk in ipairs(pending) do
    if review_selection.hunk_rows(hunk, line_count) >= from_row then
      review_selection.select_hunk(review.win, review.buf, hunk)
      return
    end
  end
  review_selection.select_hunk(review.win, review.buf, pending[1])
end

---@param review AiInlineDiffReviewState
---@return AiInlineDiffHunk?
local function editable_selected_hunk(review)
  if not review.editable then
    vim.notify("This agent only takes the whole edit: <M-a> accepts, <M-r> rejects", vim.log.levels.WARN)
    return nil
  end
  return selected_hunk(review)
end

--- Keep the selected change and move to the next undecided one.
---@param review AiInlineDiffReviewState
---@param resolvers AiInlineDiffResolvers
function M.keep_selected(review, resolvers)
  local hunk = editable_selected_hunk(review)
  if not hunk then
    return
  end
  local first, last = review_selection.hunk_rows(hunk, vim.api.nvim_buf_line_count(review.buf))
  vim.api.nvim_buf_set_extmark(review.buf, kept_namespace, first - 1, 0, {})
  continue_or_finish(review, last + 1, resolvers)
end

--- Put the original lines back for the selected change, then move on.
---@param review AiInlineDiffReviewState
---@param resolvers AiInlineDiffResolvers
function M.drop_selected(review, resolvers)
  local hunk = editable_selected_hunk(review)
  if not hunk then
    return
  end
  local first = review_selection.hunk_rows(hunk, vim.api.nvim_buf_line_count(review.buf))
  restore_original_lines(review, hunk)
  continue_or_finish(review, first, resolvers)
end

return M
