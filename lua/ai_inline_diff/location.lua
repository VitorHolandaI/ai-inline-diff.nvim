local M = {}

local paths = require("ai_inline_diff.paths")
local windows = require("ai_inline_diff.windows")

local namespace = vim.api.nvim_create_namespace("AiInlineDiffLocation")
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

---@class AiInlineDiffLocation
---@field path string
---@field first_line integer? first line to highlight; nil opens without highlight
---@field last_line integer?

---@alias AiInlineDiffLayout "smart" | "tab" | "vsplit" | "split"

local layout_names = { smart = true, tab = true, vsplit = true, split = true }
local layout_list = { "smart", "tab", "vsplit", "split" }

-- Buffers that still carry a highlight from the last request.
---@type integer[]
local highlighted_buffers = {}

---@param path string
---@return integer
local function load_file_buffer(path)
  if vim.fn.filereadable(path) ~= 1 then
    error(string.format("cannot open location: '%s' is not a readable file", path), 0)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  return buf
end

---@param value unknown
---@param min integer
---@param max integer
---@return boolean
local function is_line_between(value, min, max)
  return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
end

---@param path string
---@param first_line unknown
---@param last_line unknown
---@param line_count integer
local function validate_range(path, first_line, last_line, line_count)
  if not is_line_between(first_line, 1, line_count) then
    error(
      string.format("first line %s is outside '%s', expected integer 1-%d", vim.inspect(first_line), path, line_count),
      0
    )
  end
  if not is_line_between(last_line, first_line, line_count) then
    error(
      string.format(
        "last line %s is invalid for '%s', expected integer %d-%d",
        vim.inspect(last_line),
        path,
        first_line,
        line_count
      ),
      0
    )
  end
end

---@param layout unknown
---@return AiInlineDiffLayout
local function checked_layout(layout)
  if type(layout) ~= "string" or not layout_names[layout] then
    error(string.format("layout %s is not one of: %s", vim.inspect(layout), table.concat(layout_list, ", ")), 0)
  end
  ---@cast layout AiInlineDiffLayout
  return layout
end

---@param win integer
---@return boolean
local function can_host_file(win)
  -- Replacing a review buffer would wipe it and reject the pending edit.
  local shows_review = vim.b[vim.api.nvim_win_get_buf(win)].ai_inline_diff_id ~= nil
  local same_tab = vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  return same_tab and not shows_review
end

---@param path string
---@param buf integer
---@return integer
local function pick_target_window(path, buf)
  local win = windows.find_editor_window(path)
  if win and can_host_file(win) then
    vim.api.nvim_win_set_buf(win, buf)
    return win
  end
  return vim.api.nvim_open_win(buf, false, { split = "left", win = vim.api.nvim_get_current_win() })
end

--- Drop the highlight from the previous request, whatever it was.
local function clear_highlights()
  for _, buf in ipairs(highlighted_buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    end
  end
  highlighted_buffers = {}
end

---@param buf integer
---@param first_line integer
---@param last_line integer
local function highlight_range(buf, first_line, last_line)
  vim.api.nvim_buf_set_extmark(buf, namespace, first_line - 1, 0, {
    end_row = last_line,
    hl_group = "Visual",
    hl_eol = true,
  })
  if not vim.tbl_contains(highlighted_buffers, buf) then
    highlighted_buffers[#highlighted_buffers + 1] = buf
  end
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    end,
  })
end

---@param win integer
---@param buf integer
---@param location AiInlineDiffLocation
local function show_lines(win, buf, location)
  local first_line = location.first_line
  if first_line == nil then
    return
  end
  vim.api.nvim_win_set_cursor(win, { first_line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  highlight_range(buf, first_line, location.last_line or first_line)
end

--- A window outside this tab that already shows the buffer, so a second
--- request reuses its tab instead of stacking another one.
---@param buf integer
---@param used table<integer, boolean>
---@return integer?
local function tab_window_showing(buf, used)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf and not used[win] and vim.b[buf].ai_inline_diff_id == nil then
        return win
      end
    end
  end
end

--- Open the buffer in a new tab and go straight back, so the window the user
--- is typing in keeps focus and terminal mode. `after_tab` keeps the tabs in
--- the order the locations were asked for.
---@param buf integer
---@param after_tab integer?
---@return integer win
---@return integer tab
local function open_in_new_tab(buf, after_tab)
  local original_tab = vim.api.nvim_get_current_tabpage()
  local typing = vim.bo.buftype == "terminal" and vim.api.nvim_get_mode().mode == "t"
  if after_tab and vim.api.nvim_tabpage_is_valid(after_tab) and after_tab ~= original_tab then
    vim.api.nvim_set_current_tabpage(after_tab)
  end
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  local scratch = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)
  if scratch ~= buf then
    vim.api.nvim_buf_delete(scratch, { force = true })
  end
  vim.api.nvim_set_current_tabpage(original_tab)
  if typing and vim.api.nvim_get_mode().mode ~= "t" then
    vim.cmd.startinsert()
  end
  return win, tab
end

---@param buf integer
---@param used table<integer, boolean>
---@param after_tab integer?
---@return integer win
---@return integer? tab nil when an existing window was reused
local function open_in_tab(buf, used, after_tab)
  local existing = tab_window_showing(buf, used)
  if existing then
    return existing, nil
  end
  return open_in_new_tab(buf, after_tab)
end

---@param buf integer
---@param direction "left" | "right" | "below"
---@param anchor integer
---@return integer
local function open_in_split(buf, direction, anchor)
  return vim.api.nvim_open_win(buf, false, { split = direction, win = anchor })
end

--- Load and validate every location before any window changes, so a bad
--- range in the last one leaves the layout untouched.
---@param locations AiInlineDiffLocation[]
---@return AiInlineDiffLocation[]
local function prepare(locations)
  local prepared = {}
  for _, location in ipairs(locations) do
    local absolute = paths.canonical_path(location.path)
    local buf = load_file_buffer(absolute)
    local first_line = location.first_line
    local last_line = location.last_line or first_line
    if first_line ~= nil then
      validate_range(absolute, first_line, last_line, vim.api.nvim_buf_line_count(buf))
    end
    prepared[#prepared + 1] = { path = absolute, first_line = first_line, last_line = last_line }
  end
  return prepared
end

---@param locations AiInlineDiffLocation[]
---@param layout AiInlineDiffLayout
local function apply(locations, layout)
  clear_highlights()
  local used = {} ---@type table<integer, boolean>
  local anchor = vim.api.nvim_get_current_win()
  local last_tab ---@type integer?
  local opened = 0
  for _, location in ipairs(locations) do
    local buf = load_file_buffer(location.path)
    local win
    if layout == "tab" then
      local tab
      win, tab = open_in_tab(buf, used, last_tab)
      last_tab = tab or last_tab
    elseif layout == "smart" then
      win = pick_target_window(location.path, buf)
    else
      ---@type "left" | "right" | "below"
      local direction = layout == "vsplit" and (opened == 0 and "left" or "right") or "below"
      win = open_in_split(buf, direction, anchor)
      anchor = win
    end
    opened = opened + 1
    used[win] = true
    show_lines(win, buf, location)
  end
end

--- Show lines of a file in an editor window, keeping focus where it is.
--- Without `first_line` the file opens and nothing is highlighted.
--- Example: `require("ai_inline_diff.location").open("lua/app.lua", 10, 25)`
---@param path string
---@param first_line integer?
---@param last_line integer?
function M.open(path, first_line, last_line)
  M.open_many({ { path = path, first_line = first_line, last_line = last_line } }, "smart")
end

--- Show several locations at once, either in one tab each, in splits, or
--- wherever the next matching window is (`smart`).
--- Example: `open_many({ { path = "a.lua", first_line = 10 } }, "tab")`
---@param locations AiInlineDiffLocation[]
---@param layout AiInlineDiffLayout?
function M.open_many(locations, layout)
  local chosen = checked_layout(layout or "smart")
  if #locations == 0 then
    error("no locations given, expected at least one", 0)
  end
  apply(prepare(locations), chosen)
end

---@param entry unknown
---@param index integer
---@return AiInlineDiffLocation
local function payload_location(entry, index)
  if type(entry) ~= "table" then
    error(string.format("location %d is %s, expected a table", index, vim.inspect(entry)), 0)
  end
  if type(entry.path) ~= "string" or entry.path == "" then
    error(string.format("location %d path is %s, expected a non-empty string", index, vim.inspect(entry.path)), 0)
  end
  return { path = entry.path, first_line = entry.first, last_line = entry.last }
end

---@param payload table
---@return AiInlineDiffLocation[]
local function payload_locations(payload)
  local entries = payload.locations
  if type(entries) ~= "table" or #entries == 0 then
    error(string.format("payload locations is %s, expected a non-empty list", vim.inspect(entries)), 0)
  end
  local locations = {}
  for index, entry in ipairs(entries) do
    locations[#locations + 1] = payload_location(entry, index)
  end
  return locations
end

---@param location AiInlineDiffLocation
---@return string
local function describe(location)
  local first_line = location.first_line
  if first_line == nil then
    return location.path
  end
  local last_line = location.last_line or first_line
  if last_line == first_line then
    return string.format("%s:%d", location.path, first_line)
  end
  return string.format("%s:%d-%d", location.path, first_line, last_line)
end

--- Entry point for bin/nvim-open-location; errors become a string so the
--- script can print them and exit non-zero.
---@param payload unknown
---@return string
function M.open_for_remote(payload)
  local ok, result = pcall(function()
    if type(payload) ~= "table" then
      error(string.format("remote payload is %s, expected a table", vim.inspect(payload)), 0)
    end
    ---@cast payload table
    local locations = payload_locations(payload)
    local layout = checked_layout(payload.layout)
    M.open_many(locations, layout)
    local shown = {}
    for _, location in ipairs(locations) do
      shown[#shown + 1] = describe(location)
    end
    return string.format("opened %s (%s)", table.concat(shown, ", "), layout)
  end)
  if not ok then
    return "error: " .. tostring(result)
  end
  return result
end

--- Put bin/nvim-open-location on $PATH for terminals started afterwards.
function M.setup()
  local bin = plugin_root .. "/bin"
  local entries = vim.split(vim.env.PATH or "", ":", { plain = true })
  if not vim.tbl_contains(entries, bin) then
    vim.env.PATH = bin .. ":" .. (vim.env.PATH or "")
  end
end

---@return string
function M.instructions_path()
  return plugin_root .. "/instructions/open-location.md"
end

return M
