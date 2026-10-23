-- Run with: nvim -l tests/lint.lua
-- Runs the three static checks the project keeps at zero findings:
-- - lua-language-server --check on lua/: types from ---@ annotations,
--   possible nil, deprecated Neovim API, unknown fields
-- - stylua --check on lua/ and tests/ (../stylua.toml, ../.styluaignore)
-- - shellcheck on bin/nvim-open-location
-- Each tool is taken from $PATH or from Mason's bin directory. A missing tool
-- fails the run, so a clean result always means all three ran.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"
local failures = 0

---@param name string
---@return string? path
local function find_tool(name)
  local on_path = vim.fn.exepath(name)
  if on_path ~= "" then
    return on_path
  end
  if vim.fn.executable(mason_bin .. name) == 1 then
    return mason_bin .. name
  end
end

---@param label string
---@param ok boolean
---@param details string?
local function report(label, ok, details)
  print(string.format("%-5s %s", ok and "ok" or "FAIL", label))
  if not ok then
    failures = failures + 1
    if details and details ~= "" then
      print((details:gsub("\n+$", ""):gsub("\n", "\n      ")))
    end
  end
end

---@param name string
---@param install string how to get it
---@return string?
local function require_tool(name, install)
  local path = find_tool(name)
  if not path then
    report(name, false, string.format("not found in $PATH or %s; install with %s", mason_bin, install))
  end
  return path
end

---@param cmd string[]
---@return vim.SystemCompleted
local function run(cmd)
  return vim.system(cmd, { cwd = plugin_root, text = true }):wait()
end

local function check_stylua()
  local stylua = require_tool("stylua", ":MasonInstall stylua or pacman -S stylua")
  if stylua then
    local result = run({ stylua, "--check", "lua", "tests" })
    report("stylua: lua/ and tests/ formatted", result.code == 0, result.stdout .. result.stderr)
  end
end

local function check_shellcheck()
  local shellcheck = require_tool("shellcheck", ":MasonInstall shellcheck or pacman -S shellcheck")
  if shellcheck then
    local result = run({ shellcheck, "bin/nvim-open-location" })
    report("shellcheck: bin/nvim-open-location", result.code == 0, result.stdout .. result.stderr)
  end
end

-- Neovim's own type stubs live in $VIMRUNTIME, so the config is written per
-- run instead of hard-coding a path in the repository.
---@param work_dir string
---@return string config path
local function write_luals_config(work_dir)
  local config = work_dir .. "/luarc.json"
  local settings = {
    ["runtime.version"] = "LuaJIT",
    ["workspace.library"] = { vim.env.VIMRUNTIME .. "/lua" },
    ["workspace.checkThirdParty"] = false,
  }
  vim.fn.writefile({ vim.json.encode(settings) }, config)
  return config
end

---@param report_path string
---@return string[] one line per finding
local function read_luals_findings(report_path)
  if vim.fn.filereadable(report_path) == 0 then
    return {}
  end
  local findings = {}
  for uri, diagnostics in pairs(vim.json.decode(table.concat(vim.fn.readfile(report_path), "\n"))) do
    local file = vim.uri_to_fname(uri):sub(#plugin_root + 2)
    for _, diagnostic in ipairs(diagnostics) do
      local line = diagnostic.range.start.line + 1
      findings[#findings + 1] = string.format("%s:%d [%s] %s", file, line, diagnostic.code, diagnostic.message)
    end
  end
  table.sort(findings)
  return findings
end

local function check_luals()
  local luals =
    require_tool("lua-language-server", ":MasonInstall lua-language-server or pacman -S lua-language-server")
  if not luals then
    return
  end
  local work_dir = vim.fn.tempname()
  vim.fn.mkdir(work_dir, "p")
  local report_path = work_dir .. "/check.json"
  local result = run({
    luals,
    "--check=" .. plugin_root .. "/lua",
    "--configpath=" .. write_luals_config(work_dir),
    "--checklevel=Warning",
    "--check_format=json",
    "--check_out_path=" .. report_path,
    "--logpath=" .. work_dir,
  })
  local findings = read_luals_findings(report_path)
  local ran = result.code == 0 or #findings > 0
  report(
    "lua-language-server: lua/ has no warnings",
    ran and #findings == 0,
    ran and table.concat(findings, "\n") or result.stderr
  )
  vim.fn.delete(work_dir, "rf")
end

check_luals()
check_stylua()
check_shellcheck()
if failures > 0 then
  print(string.format("%d lint check(s) failed", failures))
  os.exit(1)
end
print("all lint checks passed")
