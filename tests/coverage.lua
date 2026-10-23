-- Run with: nvim -l tests/coverage.lua [--missing]
-- Runs every tests/*_test.lua with tests/helpers/coverage_hook.lua loaded in
-- each child Neovim, then prints line coverage for lua/ai_inline_diff/*.lua.
-- --missing also lists the line ranges that never ran.

local jit_util = require("jit.util")

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local show_missing = vim.tbl_contains(_G.arg, "--missing")

---@param proto function|userdata a function or a LuaJIT prototype
---@param lines table<integer, true>
local function collect_proto_lines(proto, lines)
  local pc = 1
  while jit_util.funcbc(proto, pc) do
    local line = jit_util.funcinfo(proto, pc).currentline
    if line and line > 0 then
      lines[line] = true
    end
    pc = pc + 1
  end
  -- Nested functions are stored as negative-index constants of their parent.
  local index = -1
  local constant = jit_util.funck(proto, index)
  while constant ~= nil do
    if type(constant) == "proto" then
      collect_proto_lines(constant, lines)
    end
    index = index - 1
    constant = jit_util.funck(proto, index)
  end
end

--- Lines that hold at least one bytecode instruction, i.e. lines that can run.
---@param path string
---@return table<integer, true>
local function executable_lines(path)
  local chunk, err = loadfile(path)
  if not chunk then
    error(string.format("cannot compile '%s': %s", path, err))
  end
  local lines = {}
  collect_proto_lines(chunk, lines)
  return lines
end

---@param coverage_dir string
---@return string[] failed test files
local function run_tests(coverage_dir)
  local failed = {}
  for _, test in ipairs(vim.fn.glob(plugin_root .. "/tests/*_test.lua", false, true)) do
    local result = vim
      .system({ "nvim", "-l", test }, { env = { AI_INLINE_DIFF_COVERAGE_DIR = coverage_dir }, text = true })
      :wait()
    print(string.format("%-4s %s", result.code == 0 and "ok" or "FAIL", vim.fs.basename(test)))
    if result.code ~= 0 then
      failed[#failed + 1] = vim.fs.basename(test)
    end
  end
  return failed
end

---@param coverage_dir string
---@return table<string, table<integer, true>>
local function read_hits(coverage_dir)
  local hits = {}
  for _, dump in ipairs(vim.fn.glob(coverage_dir .. "/*.tsv", false, true)) do
    for _, row in ipairs(vim.fn.readfile(dump)) do
      local file, line = row:match("^(.-)\t(%d+)\t%d+$")
      if not file then
        error(string.format("bad coverage row in '%s': %q, expected file<TAB>line<TAB>count", dump, row))
      end
      hits[file] = hits[file] or {}
      hits[file][tonumber(line)] = true
    end
  end
  return hits
end

---@param lines integer[] sorted line numbers
---@return string ranges like "12-15, 40"
local function format_ranges(lines)
  local ranges = {}
  local first, previous = lines[1], lines[1]
  for i = 2, #lines + 1 do
    local line = lines[i]
    if line ~= previous + 1 then
      ranges[#ranges + 1] = first == previous and tostring(first) or (first .. "-" .. previous)
      first = line
    end
    previous = line
  end
  return table.concat(ranges, ", ")
end

---@param hits table<string, table<integer, true>>
local function print_report(hits)
  local total_run, total_lines = 0, 0
  print(string.format("\n%-40s %9s %7s", "file", "lines", "cover"))
  for _, path in ipairs(vim.fn.glob(plugin_root .. "/lua/ai_inline_diff/*.lua", false, true)) do
    local run, count, missing = 0, 0, {}
    for line in pairs(executable_lines(path)) do
      count = count + 1
      if (hits[path] or {})[line] then
        run = run + 1
      else
        missing[#missing + 1] = line
      end
    end
    total_run, total_lines = total_run + run, total_lines + count
    local relative = path:sub(#plugin_root + 2)
    print(string.format("%-40s %4d/%-4d %6.1f%%", relative, run, count, 100 * run / count))
    if show_missing and #missing > 0 then
      table.sort(missing)
      print("    missing: " .. format_ranges(missing))
    end
  end
  print(string.format("%-40s %4d/%-4d %6.1f%%", "total", total_run, total_lines, 100 * total_run / total_lines))
end

local coverage_dir = vim.fn.tempname()
vim.fn.mkdir(coverage_dir, "p")
local failed = run_tests(coverage_dir)
print_report(read_hits(coverage_dir))
vim.fn.delete(coverage_dir, "rf")
if #failed > 0 then
  print("failed: " .. table.concat(failed, ", "))
  os.exit(1)
end
