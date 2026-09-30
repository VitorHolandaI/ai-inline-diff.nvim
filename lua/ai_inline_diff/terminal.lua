local M = {}

---@class AiInlineDiffTerminalOpts
---@field auto_insert? boolean Enter terminal mode when a terminal gains focus.
---@field window_keys? boolean Map <C-w> and <C-h/j/k/l> in terminal mode.

---@type AiInlineDiffTerminalOpts
local default_opts = {
  auto_insert = true,
  window_keys = true,
}

-- Each key leaves terminal mode before acting; otherwise the agent's TUI
-- receives it and focus never leaves the terminal.
local window_keymaps = {
  { lhs = "<C-h>", rhs = "<C-\\><C-n><C-w>h", desc = "Focus window left" },
  { lhs = "<C-j>", rhs = "<C-\\><C-n><C-w>j", desc = "Focus window below" },
  { lhs = "<C-k>", rhs = "<C-\\><C-n><C-w>k", desc = "Focus window above" },
  { lhs = "<C-l>", rhs = "<C-\\><C-n><C-w>l", desc = "Focus window right" },
  { lhs = "<C-w>", rhs = "<C-\\><C-n><C-w>", desc = "Window command from terminal" },
}

---@param buf integer
---@return boolean
local function terminal_job_is_running(buf)
  local job_id = vim.b[buf].terminal_job_id
  return job_id ~= nil and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function enable_auto_insert()
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("AiInlineDiffTerminalInsert", { clear = true }),
    callback = function(args)
      if vim.bo[args.buf].buftype ~= "terminal" then
        return
      end
      -- A finished terminal closes on the next key typed in terminal mode.
      if terminal_job_is_running(args.buf) then
        vim.cmd.startinsert()
      end
    end,
    desc = "Enter terminal mode when a terminal gains focus",
  })
end

local function map_window_keys()
  for _, keymap in ipairs(window_keymaps) do
    vim.keymap.set("t", keymap.lhs, keymap.rhs, { desc = keymap.desc })
  end
end

---@param opts AiInlineDiffTerminalOpts?
---@return AiInlineDiffTerminalOpts
local function resolve_opts(opts)
  for key, value in pairs(opts or {}) do
    if default_opts[key] == nil then
      error(string.format("unknown setup_terminal option: '%s', expected auto_insert or window_keys", key))
    end
    if type(value) ~= "boolean" then
      error(string.format("setup_terminal option '%s' is %s, expected boolean", key, vim.inspect(value)))
    end
  end
  return vim.tbl_extend("force", default_opts, opts or {})
end

--- Make agent terminals quick to enter and leave.
--- Example: `require("ai_inline_diff.terminal").setup({ window_keys = false })`
---@param opts AiInlineDiffTerminalOpts?
function M.setup(opts)
  local resolved = resolve_opts(opts)
  if resolved.auto_insert then
    enable_auto_insert()
  end
  if resolved.window_keys then
    map_window_keys()
  end
end

return M
