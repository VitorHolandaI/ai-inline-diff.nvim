local M = {}

local function greet(name)
  return "hello " .. name
end

function M.sum(values)
  local total = 0
  for _, value in ipairs(values) do
    if value > 0 then
      total = total + value
    end
  end
  return total
end

function M.average(values)
  return M.sum(values) / #values
end

function M.run()
  print(greet("neovim"))
  print(M.average({ 1, 2, 3 }))
end

return M
