local M = {}

local function greet(name)
  return "hello " .. name
end

function M.sum(values)
  local total = 0
  for _, value in ipairs(values) do
    total = total + value
  end
  return total
end

function M.run()
  print(greet("world"))
  print(M.average({ 1, 2, 3 }))
end

return M
