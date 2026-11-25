local M = {}

---@class AiInlineDiffReviewActions
---@field accept fun()
---@field reject fun()
---@field keep_change fun()
---@field drop_change fun()
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
--- Example: `map(buf, { accept = a, reject = r, keep_change = k, ... })`
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
    { { "n", "x", "i" }, "<M-y>", from_any_mode(actions.keep_change), "Keep this AI change" },
    { { "n", "x", "i" }, "<M-x>", from_any_mode(actions.drop_change), "Drop this AI change" },
    { { "n", "x" }, "]c", actions.next_change, "Next AI change" },
    { { "n", "x" }, "[c", actions.previous_change, "Previous AI change" },
    -- No leave_insert_and_visual(): the selection starts with <C-\><C-n>.
    { { "n", "x", "i" }, "<M-n>", actions.next_change, "Next AI change" },
    { { "n", "x", "i" }, "<M-p>", actions.previous_change, "Previous AI change" },
  }
  for _, keymap in ipairs(keymaps) do
    vim.keymap.set(keymap[1], keymap[2], keymap[3], { buf = buf, desc = keymap[4] })
  end
end

---@param lhs string
---@return table? the global Terminal-mode map for `lhs`, as mapset() takes it
local function global_terminal_map(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap("t")) do
    if map.lhs == lhs then
      return map
    end
  end
end

--- While a review is open, <M-a>/<M-r> in any terminal answer it: focus is
--- often back in the agent's terminal, where the keys used to reach the
--- agent and leave the review waiting. Returns a function that gives the
--- keys back, restoring a global Terminal-mode map the user had.
--- Example: `local release = map_terminal({ accept = a, reject = r })`
---@param actions { accept: fun(), reject: fun() }
---@return fun() release
function M.map_terminal(actions)
  local keys = {
    { "<M-a>", actions.accept, "Accept the open AI review" },
    { "<M-r>", actions.reject, "Reject the open AI review" },
  }
  local previous = {} ---@type table<string, table|false>
  for _, key in ipairs(keys) do
    previous[key[1]] = global_terminal_map(key[1]) or false
    vim.keymap.set("t", key[1], key[2], { desc = key[3] })
  end
  return function()
    for lhs, map in pairs(previous) do
      pcall(vim.keymap.del, "t", lhs)
      if map then
        vim.fn.mapset("t", false, map)
      end
    end
  end
end

return M
