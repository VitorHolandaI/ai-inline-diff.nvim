-- Run with: nvim -l tests/patch_test.lua
-- Locks down apply_unified_patch() on hunk headers at the edges of what the
-- parser accepts. Its counts come from tonumber() on pattern captures, which
-- LuaLS flags as possibly nil; these cases show what really comes out:
-- huge numbers turn into 1e+26 or inf, never nil, and must still end in a
-- clean (nil, message) instead of an error or a hang.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = plugin_root .. "/tests/?.lua;" .. package.path
vim.opt.rtp:prepend(plugin_root)
local recorder = require("helpers.embedded_nvim").CheckRecorder.new()
local apply_unified_patch = require("ai_inline_diff").apply_unified_patch

local original = "a\nb\nc\n"
local many_nines = string.rep("9", 400)

---@class PatchCase
---@field name string
---@field patch string
---@field result string? expected text, nil when the patch must be refused
---@field error string? text the refusal message must contain

---@type PatchCase[]
local cases = {
  { name = "replaces a line", patch = "@@ -2,1 +2,1 @@\n-b\n+B\n", result = "a\nB\nc\n" },
  { name = "omitted counts mean 1", patch = "@@ -2 +2 @@\n-b\n+B\n", result = "a\nB\nc\n" },
  { name = "inserts before line 1", patch = "@@ -0,0 +1,1 @@\n+top\n", result = "top\na\nb\nc\n" },
  { name = "removes a line", patch = "@@ -2,1 +1,0 @@\n-b\n", result = "a\nc\n" },
  { name = "leading zeros", patch = "@@ -002,01 +002,01 @@\n-b\n+B\n", result = "a\nB\nc\n" },
  {
    name = "start too large for the file (1e+26)",
    patch = "@@ -99999999999999999999999999,1 +1,1 @@\n-b\n+B\n",
    error = "does not match",
  },
  {
    name = "start that overflows to inf",
    patch = "@@ -" .. many_nines .. ",1 +1,1 @@\n-b\n+B\n",
    error = "does not match",
  },
  {
    name = "count that overflows to inf",
    patch = "@@ -2," .. many_nines .. " +2,1 @@\n-b\n+B\n",
    error = "inconsistent line counts",
  },
  { name = "non-ASCII digits are not a hunk header", patch = "@@ -١,1 +1,1 @@\n-b\n+B\n" },
  { name = "letters in the header", patch = "@@ -1x +1 @@\n-b\n+B\n" },
  { name = "no hunk at all", patch = "", error = "No unified diff hunks" },
}

for _, case in ipairs(cases) do
  local started = vim.uv.hrtime()
  local ok, result, err = pcall(apply_unified_patch, original, case.patch)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  recorder:check(case.name .. ": returns instead of raising", ok, true)
  recorder:check(case.name .. ": finishes within 100 ms", elapsed_ms < 100, true)
  if case.result then
    recorder:check(case.name .. ": result", { result, err }, { case.result, nil })
  else
    local refused = result == nil and type(err) == "string"
    recorder:check(case.name .. ": refused with a message", refused, true)
    if case.error and refused then
      recorder:check(case.name .. ": message", err:find(case.error, 1, true) ~= nil, true)
    end
  end
end
recorder:finish()
