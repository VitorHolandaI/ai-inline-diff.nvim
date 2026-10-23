local M = {}

---@alias AiInlineDiffHunk integer[] { old_start, old_count, new_start, new_count }

---@param hunk AiInlineDiffHunk
---@param line_count integer
---@return integer first_row, integer last_row
local function hunk_rows(hunk, line_count)
  local first = math.min(math.max(hunk[3], 1), line_count)
  if hunk[4] == 0 then
    return first, first
  end
  return first, math.min(hunk[3] + hunk[4] - 1, line_count)
end

--- Put the cursor on a change and select its proposed lines linewise.
--- A removal-only change has no proposed lines, so it stays in Normal mode.
---@param win integer
---@param buf integer
---@param hunk AiInlineDiffHunk
function M.select_hunk(win, buf, hunk)
  local first, last = hunk_rows(hunk, vim.api.nvim_buf_line_count(buf))
  local keys = string.format("<C-\\><C-n>%dG", first)
  if hunk[4] > 0 then
    keys = keys .. string.format("V%dGo", last)
  end
  vim.api.nvim_win_set_cursor(win, { first, 0 })
  -- Typeahead instead of :normal, which would end Visual mode on return.
  vim.api.nvim_feedkeys(vim.keycode(keys), "n", false)
end

---@param hunks AiInlineDiffHunk[]
---@param row integer
---@param direction "next"|"previous"
---@return AiInlineDiffHunk
local function adjacent_hunk(hunks, row, direction)
  if direction == "next" then
    for _, hunk in ipairs(hunks) do
      if math.max(hunk[3], 1) > row then
        return hunk
      end
    end
    return hunks[1]
  end
  for index = #hunks, 1, -1 do
    if math.max(hunks[index][3], 1) < row then
      return hunks[index]
    end
  end
  return hunks[#hunks]
end

--- Select the change after or before the cursor, wrapping around.
--- Example: `select_adjacent(review, "next")` from a ]c mapping.
---@param review { win: integer, buf: integer, hunks: AiInlineDiffHunk[] }
---@param direction "next"|"previous"
function M.select_adjacent(review, direction)
  if not vim.api.nvim_win_is_valid(review.win) or #review.hunks == 0 then
    return
  end
  -- In Visual mode the cursor may sit on either end of the selection.
  local row = math.min(vim.fn.line("v", review.win), vim.fn.line(".", review.win))
  M.select_hunk(review.win, review.buf, adjacent_hunk(review.hunks, row, direction))
end

return M
