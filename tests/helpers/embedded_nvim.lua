-- Child Neovim driven over RPC. Terminal mode and window focus cannot be
-- exercised with feedkeys inside a single headless instance.

---@class EmbeddedNvim
---@field chan integer
local EmbeddedNvim = {}
EmbeddedNvim.__index = EmbeddedNvim

---@param plugin_root string
---@return EmbeddedNvim
function EmbeddedNvim.start(plugin_root)
  local chan = vim.fn.jobstart({ "nvim", "--embed", "--headless", "--clean" }, { rpc = true })
  if chan <= 0 then
    error(string.format("failed to start embedded nvim: jobstart returned %d, expected channel > 0", chan))
  end
  local self = setmetatable({ chan = chan }, EmbeddedNvim)
  self:lua("vim.opt.rtp:prepend(...)", plugin_root)
  return self
end

---@param code string
---@param ... unknown
---@return unknown
function EmbeddedNvim:lua(code, ...)
  return vim.rpcrequest(self.chan, "nvim_exec_lua", code, { ... })
end

---@param keys string
function EmbeddedNvim:input(keys)
  vim.rpcrequest(self.chan, "nvim_input", keys)
  vim.wait(150)
end

---@return { in_terminal: boolean, mode: string }
function EmbeddedNvim:focus()
  return self:lua([[
    return { in_terminal = vim.bo.buftype == "terminal", mode = vim.api.nvim_get_mode().mode }
  ]])
end

function EmbeddedNvim:stop()
  vim.fn.jobstop(self.chan)
end

---@class CheckRecorder
---@field failures integer
local CheckRecorder = {}
CheckRecorder.__index = CheckRecorder

---@return CheckRecorder
function CheckRecorder.new()
  return setmetatable({ failures = 0 }, CheckRecorder)
end

---@param name string
---@param actual unknown
---@param expected unknown
function CheckRecorder:check(name, actual, expected)
  if vim.deep_equal(actual, expected) then
    print("ok   " .. name)
    return
  end
  self.failures = self.failures + 1
  print(string.format("FAIL %s: got %s, expected %s", name, vim.inspect(actual), vim.inspect(expected)))
end

function CheckRecorder:finish()
  if self.failures > 0 then
    print(string.format("%d check(s) failed", self.failures))
    os.exit(1)
  end
  print("all checks passed")
end

return { EmbeddedNvim = EmbeddedNvim, CheckRecorder = CheckRecorder }
