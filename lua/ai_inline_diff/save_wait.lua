local M = {}

local winbar_text = "%#WarningMsg# AI edit waiting: save with :w to review it, or :e! to discard your changes %*"

---@param buf integer
---@return integer[]
local function windows_showing(buf)
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_buf(win) == buf
  end, vim.api.nvim_list_wins())
end

--- Run `on_ready` once `buf` has no unsaved changes. A clean buffer (or none)
--- runs it at once; otherwise the windows showing the buffer get a winbar
--- notice until the user saves, discards (:e!), undoes back or wipes it.
--- Example: `local cancel = when_saved(find_loaded_buffer(path), open_review_now)`
---@param buf integer? nil when the file is not loaded
---@param on_ready fun()
---@return fun() cancel stops waiting without calling on_ready
function M.when_saved(buf, on_ready)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modified then
    on_ready()
    return function() end
  end

  local finished = false
  local previous_winbars = {} ---@type table<integer, string>
  local group = vim.api.nvim_create_augroup("AiInlineDiffSaveWait" .. buf, { clear = true })

  local function show_notice()
    for _, win in ipairs(windows_showing(buf)) do
      if previous_winbars[win] == nil then
        previous_winbars[win] = vim.wo[win].winbar
        vim.wo[win].winbar = winbar_text
      end
    end
  end

  ---@param run boolean
  local function finish(run)
    if finished then
      return
    end
    finished = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    for win, winbar in pairs(previous_winbars) do
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].winbar = winbar
      end
    end
    if run then
      on_ready()
    end
  end

  -- 'modified' turns off on :w, on :e! and on undo back to the saved text.
  vim.api.nvim_create_autocmd("BufModifiedSet", {
    group = group,
    buffer = buf,
    callback = function()
      if not vim.bo[buf].modified then
        vim.schedule(function()
          finish(true)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        finish(true)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, buffer = buf, callback = show_notice })

  show_notice()
  vim.notify(
    string.format(
      "AI edit waiting: %s has unsaved changes; save with :w to review it, or :e! to discard them",
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    ),
    vim.log.levels.WARN,
    { title = "ai-inline-diff", timeout = false }
  )

  return function()
    finish(false)
  end
end

return M
