local M = {}

local review_session = require("ai_inline_diff.review_session")
local target_file = require("ai_inline_diff.target_file")
local unified_patch = require("ai_inline_diff.unified_patch")
local save_wait = require("ai_inline_diff.save_wait")
local live_changes = require("ai_inline_diff.live_changes")

--- Apply a unified diff (or a single `*** Add File:` patch) to `original`.
--- Example: `local text, err = ai_inline_diff.apply_unified_patch(old, diff)`
---@param original string
---@param patch string
---@return string?, string?
function M.apply_unified_patch(original, patch)
  return unified_patch.apply(original, patch)
end

--- Review each OpenCode `edit` permission inline (opencode.nvim).
function M.setup_opencode()
  require("ai_inline_diff.opencode_adapter").setup()

  -- A manual module reload must not leave Claude or Antigravity bound to
  -- the previous copy.
  if package.loaded["claudecode.diff"] then
    M.setup_claude()
  end
  if package.loaded["antigravity-cli.diff"] then
    M.setup_antigravity()
  end
end

--- Review each Claude Code `openDiff` inline (claudecode.nvim).
function M.setup_claude()
  require("ai_inline_diff.claude_adapter").setup()
end

--- Review each diff Antigravity 1.2 opens inline (antigravity-cli.nvim).
--- agy 1.5 opens none; it reaches Neovim through bin/agy-review-hook.lua.
function M.setup_antigravity()
  require("ai_inline_diff.antigravity_adapter").setup()
end

local agy_hook = require("ai_inline_diff.agy_hook").new({
  open_review = review_session.open,
  has_review = function()
    return review_session.is_open(review_session.current_id())
  end,
  close_review = function(id)
    review_session.resolve(id, false, false)
  end,
  read_file = target_file.read,
  find_loaded_buffer = target_file.loaded_buffer,
  when_saved = save_wait.when_saved,
})

--- Called by bin/agy-review-hook.lua over $NVIM with agy's PreToolUse
--- payload. Returns `{ id }` while the edit waits for review, or `{ reply }`.
---@param raw_payload string
---@return table
function M.antigravity_hook_start(raw_payload)
  return agy_hook:start(raw_payload)
end

--- The hook's decision for review `id`, or nil while it is still open.
---@param id string
---@return table?
function M.antigravity_hook_poll(id)
  return agy_hook:poll(id)
end

--- The `command` to put in agy's hooks.json, with this install's path.
--- Example: `:lua print(require("ai_inline_diff").antigravity_hook_command())`
---@return string
function M.antigravity_hook_command()
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
  return "nvim -l " .. vim.fn.shellescape(plugin_root .. "/bin/agy-review-hook.lua")
end

--- Enter agent terminals in terminal mode and leave them with <C-w>.
--- Example: `require("ai_inline_diff").setup_terminal({ window_keys = false })`
---@param opts AiInlineDiffTerminalOpts?
function M.setup_terminal(opts)
  require("ai_inline_diff.terminal").setup(opts)
end

--- Show lines of a file in an editor window, keeping focus where it is.
--- Without `first_line` the file opens and nothing is highlighted.
--- Example: `require("ai_inline_diff").open_location("lua/app.lua", 10, 25)`
---@param path string
---@param first_line integer?
---@param last_line integer?
function M.open_location(path, first_line, last_line)
  require("ai_inline_diff.location").open(path, first_line, last_line)
end

--- Show several locations at once, one tab each or in splits.
--- Example: `open_locations({ { path = "a.lua", first_line = 10 } }, "tab")`
---@param locations AiInlineDiffLocation[]
---@param layout AiInlineDiffLayout?
function M.open_locations(locations, layout)
  require("ai_inline_diff.location").open_many(locations, layout)
end

--- Reload open files that agents write directly (OpenCode "Always allow",
--- Claude auto-accept) and mark what changed until you edit them.
function M.setup_live_changes()
  live_changes.setup()
end

--- Let agents run `nvim-open-location` from terminals opened afterwards.
function M.setup_open_location()
  require("ai_inline_diff.location").setup()
end

--- Path of the instructions that teach an agent to use nvim-open-location.
---@return string
function M.open_location_instructions()
  return require("ai_inline_diff.location").instructions_path()
end

return M
