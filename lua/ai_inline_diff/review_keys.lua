local M = {}

---@class AiInlineDiffReviewActions
---@field accept fun()
---@field reject fun()
---@field next_change fun()
---@field previous_change fun()

-- Accepting from Insert or Visual mode would otherwise leave that mode
-- active in the buffer the window returns to.
local function leave_insert_and_visual()
  local mode = vim.api.nvim_get_mode().mode
  if mode:find("^[vV\22]") then
    vim.cmd("normal! \27")
  elseif mode:find("^i") then
    vim.cmd.stopinsert()
  end
end

---@param action fun()
---@return fun()
local function from_any_mode(action)
  return function()
    leave_insert_and_visual()
    action()
  end
end

--- Map the keys that resolve and navigate a review in its buffer.
--- Example: `map(buf, { accept = a, reject = r, next_change = n, previous_change = p })`
---@param buf integer
---@param actions AiInlineDiffReviewActions
function M.map(buf, actions)
  local accept = from_any_mode(actions.accept)
  local reject = from_any_mode(actions.reject)
  local keymaps = {
    -- Visual mode too: a review opens with its first change selected, and
    -- a plain `d` there would delete the change instead of accepting it.
    { { "n", "x" }, "da", accept, "Accept AI edit" },
    { { "n", "x" }, "dr", reject, "Reject AI edit" },
    { { "n", "x" }, "q", reject, "Reject AI edit" },
    { { "n", "x" }, "<leader>aa", accept, "Accept AI edit" },
    { { "n", "x" }, "<leader>ad", reject, "Reject AI edit" },
    { { "n", "x", "i" }, "<M-a>", accept, "Accept AI edit" },
    { { "n", "x", "i" }, "<M-r>", reject, "Reject AI edit" },
    { { "n", "x" }, "]c", actions.next_change, "Next AI change" },
    { { "n", "x" }, "[c", actions.previous_change, "Previous AI change" },
    -- No leave_insert_and_visual(): the selection starts with <C-\><C-n>.
    { { "n", "x", "i" }, "<M-n>", actions.next_change, "Next AI change" },
    { { "n", "x", "i" }, "<M-p>", actions.previous_change, "Previous AI change" },
  }
  for _, keymap in ipairs(keymaps) do
    vim.keymap.set(keymap[1], keymap[2], keymap[3], { buffer = buf, desc = keymap[4] })
  end
end

return M
