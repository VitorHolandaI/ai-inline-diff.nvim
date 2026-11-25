local M = {}

local text = require("ai_inline_diff.text")

local split_text = text.split
local join_lines = text.join
local no_newline_marker = "\\ No newline at end of file"

---@class AiInlineDiffHunkHeader
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---@class AiInlineDiffPatchOutput
---@field lines string[]
---@field old_index integer next original line to copy or match
---@field has_eol boolean whether the new file ends with a newline

---@class AiInlineDiffHunkProgress
---@field old integer original lines consumed
---@field new integer new lines produced
---@field last_has_eol boolean?

---@class AiInlineDiffPrefixScan
---@field prefix string? indentation the patch trimmed from every line
---@field direct boolean a non-empty line matched without trimming
---@field trimmed boolean a line matched only with the prefix

---@param line string
---@return AiInlineDiffHunkHeader?
local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return nil
  end
  -- (%d+) captures always convert; tests/patch_test.lua covers huge values.
  return {
    old_start = tonumber(old_start) --[[@as integer]],
    old_count = tonumber(old_count ~= "" and old_count or "1") --[[@as integer]],
    new_start = tonumber(new_start) --[[@as integer]],
    new_count = tonumber(new_count ~= "" and new_count or "1") --[[@as integer]],
  }
end

---@param header AiInlineDiffHunkHeader
---@return integer first original line the hunk touches
local function hunk_target(header)
  return math.max(header.old_count == 0 and header.old_start + 1 or header.old_start, 1)
end

---@param line string
---@return boolean
local function is_file_header(line)
  return line == ""
    or line:match("^diff %-%-git ") ~= nil
    or line:match("^index ") ~= nil
    -- jsdiff, which OpenCode 2.x uses, writes an Index line and an underline.
    or line:match("^Index: ") ~= nil
    or line:match("^=+$") ~= nil
    or line:match("^%-%-%- ") ~= nil
    or line:match("^%+%+%+ ") ~= nil
end

--- `*** Begin Patch` with a single `*** Add File:` section, as OpenCode's
--- apply_patch sends for a new file.
---@param patch string
---@return string?, string?
local function apply_add_file(patch)
  local output = {}
  local collecting = false

  for _, line in ipairs(split_text(patch)) do
    if line:match("^%*%*%* Add File: ") then
      if collecting then
        return nil, "Multiple Add File sections are not supported"
      end
      collecting = true
    elseif collecting and line:match("^%*%*%* ") then
      if line == "*** End Patch" then
        return join_lines(output, true, "\n")
      end
      return nil, "Only single-file Add File patches can be rendered"
    elseif collecting then
      if line:sub(1, 1) ~= "+" then
        return nil, "Add File content must start with +"
      end
      output[#output + 1] = line:sub(2)
    end
  end

  return nil, "No supported Add File section was found"
end

--- "" when `content` is `original_line`, the whitespace the patch trimmed
--- off its start when it is a suffix, or nil and an error.
---@param original_line string?
---@param content string
---@return string?, string?
local function trimmed_prefix_of(original_line, content)
  if original_line == content then
    return ""
  end
  local mismatch = "Patch content does not match the original file"
  if not original_line or content == "" or #content > #original_line then
    return nil, mismatch
  end
  local prefix_length = #original_line - #content
  local prefix = original_line:sub(1, prefix_length)
  if original_line:sub(prefix_length + 1) ~= content or not prefix:match("^%s+$") then
    return nil, mismatch
  end
  return prefix
end

---@param scan AiInlineDiffPrefixScan
---@param original_line string?
---@param content string
---@return boolean?, string?
local function record_prefix(scan, original_line, content)
  local prefix, err = trimmed_prefix_of(original_line, content)
  if not prefix then
    return nil, err
  end
  if prefix == "" then
    scan.direct = scan.direct or content ~= ""
    return true
  end
  if scan.prefix and scan.prefix ~= prefix then
    return nil, "Patch has inconsistent trimmed indentation"
  end
  scan.prefix = prefix
  scan.trimmed = true
  return true
end

---@param scan AiInlineDiffPrefixScan
---@param old_lines string[]
---@param patch_lines string[]
---@param patch_index integer first line after the hunk header
---@param header AiInlineDiffHunkHeader
---@return integer?, string? next patch line
local function scan_hunk_prefix(scan, old_lines, patch_lines, patch_index, header)
  local old_index = hunk_target(header)
  local consumed_old = 0
  local consumed_new = 0
  while patch_index <= #patch_lines and (consumed_old < header.old_count or consumed_new < header.new_count) do
    local line = patch_lines[patch_index]
    local kind = line:sub(1, 1)
    if kind == " " or kind == "-" then
      local ok, err = record_prefix(scan, old_lines[old_index], line:sub(2))
      if not ok then
        return nil, err
      end
      old_index = old_index + 1
      consumed_old = consumed_old + 1
      consumed_new = consumed_new + (kind == " " and 1 or 0)
    elseif kind == "+" then
      consumed_new = consumed_new + 1
    else
      return nil, "Unsupported patch line: " .. line
    end
    patch_index = patch_index + 1
    if patch_lines[patch_index] == no_newline_marker then
      patch_index = patch_index + 1
    end
  end
  return patch_index
end

--- Patch lines can arrive with the same leading whitespace cut from every
--- line; this finds that prefix so the patch still applies.
---@param old_lines string[]
---@param patch_lines string[]
---@return string?, string?
local function detect_trimmed_prefix(old_lines, patch_lines)
  local scan = { direct = false, trimmed = false } ---@type AiInlineDiffPrefixScan
  local patch_index = 1
  while patch_index <= #patch_lines do
    local header = parse_hunk_header(patch_lines[patch_index])
    patch_index = patch_index + 1
    if header then
      local next_index, err = scan_hunk_prefix(scan, old_lines, patch_lines, patch_index, header)
      if not next_index then
        return nil, err
      end
      patch_index = next_index
    end
  end

  if scan.direct and scan.trimmed then
    return nil, "Patch has ambiguous trimmed indentation"
  end
  return scan.prefix or ""
end

---@param output AiInlineDiffPatchOutput
---@param progress AiInlineDiffHunkProgress
---@param old_lines string[]
---@param line string
---@param trimmed_prefix string
---@return boolean?, string?
local function apply_hunk_line(output, progress, old_lines, line, trimmed_prefix)
  local kind = line:sub(1, 1)
  local content = line:sub(2)
  local restored_content = content == "" and "" or trimmed_prefix .. content
  if kind == "+" then
    output.lines[#output.lines + 1] = restored_content
    progress.new = progress.new + 1
    progress.last_has_eol = true
    return true
  end
  if kind ~= " " and kind ~= "-" then
    return nil, "Unsupported patch line: " .. line
  end

  local original_line = old_lines[output.old_index]
  if original_line ~= content and original_line ~= restored_content then
    local role = kind == " " and "context" or "removal"
    return nil, "Patch " .. role .. " does not match " .. tostring(output.old_index)
  end
  output.old_index = output.old_index + 1
  progress.old = progress.old + 1
  if kind == " " then
    output.lines[#output.lines + 1] = original_line
    progress.new = progress.new + 1
    progress.last_has_eol = true
  end
  return true
end

--- Copy the original lines before the hunk, checking the hunk's positions.
---@param output AiInlineDiffPatchOutput
---@param old_lines string[]
---@param header AiInlineDiffHunkHeader
---@return boolean?, string?
local function copy_up_to_hunk(output, old_lines, header)
  local target = hunk_target(header)
  if target < output.old_index or target > #old_lines + 1 then
    return nil, "Patch hunks overlap or point outside the original file"
  end
  while output.old_index < target do
    output.lines[#output.lines + 1] = old_lines[output.old_index]
    output.old_index = output.old_index + 1
  end
  local expected_new_lines_before = header.new_count == 0 and header.new_start or header.new_start - 1
  if #output.lines ~= expected_new_lines_before then
    return nil, "Patch hunks have inconsistent new-file positions"
  end
  return true
end

---@param header AiInlineDiffHunkHeader
---@param old_lines string[]
---@return boolean
local function touches_end_of_file(header, old_lines)
  if header.old_count == 0 then
    return hunk_target(header) == #old_lines + 1
  end
  return header.old_start + header.old_count - 1 >= #old_lines
end

---@param output AiInlineDiffPatchOutput
---@param header AiInlineDiffHunkHeader
---@param progress AiInlineDiffHunkProgress
local function set_final_newline(output, header, progress)
  if header.new_count > 0 then
    output.has_eol = progress.last_has_eol --[[@as boolean]]
  else
    output.has_eol = #output.lines > 0
  end
end

---@param output AiInlineDiffPatchOutput
---@param old_lines string[]
---@param patch_lines string[]
---@param patch_index integer first line after the hunk header
---@param header AiInlineDiffHunkHeader
---@param trimmed_prefix string
---@return integer?, string? next patch line
local function apply_hunk(output, old_lines, patch_lines, patch_index, header, trimmed_prefix)
  local copied, copy_err = copy_up_to_hunk(output, old_lines, header)
  if not copied then
    return nil, copy_err
  end
  local touches_eof = touches_end_of_file(header, old_lines)

  local progress = { old = 0, new = 0 } ---@type AiInlineDiffHunkProgress
  while patch_index <= #patch_lines and (progress.old < header.old_count or progress.new < header.new_count) do
    local line = patch_lines[patch_index]
    local ok, err = apply_hunk_line(output, progress, old_lines, line, trimmed_prefix)
    if not ok then
      return nil, err
    end
    patch_index = patch_index + 1
    if patch_lines[patch_index] == no_newline_marker then
      if line:sub(1, 1) ~= "-" then
        progress.last_has_eol = false
      end
      patch_index = patch_index + 1
    end
  end

  if progress.old ~= header.old_count or progress.new ~= header.new_count then
    return nil, "Patch hunk has inconsistent line counts"
  end
  if touches_eof then
    set_final_newline(output, header, progress)
  end
  return patch_index
end

--- Apply a unified diff (or a single `*** Add File:` patch) to `original`.
--- Example: `local text, err = unified_patch.apply(old_text, edit.diff)`
---@param original string
---@param patch string
---@return string?, string?
function M.apply(original, patch)
  if patch:match("^%*%*%* Begin Patch") then
    return apply_add_file(patch)
  end

  local old_lines, old_has_eol, line_ending = split_text(original)
  local patch_lines = split_text(patch)
  local trimmed_prefix, prefix_err = detect_trimmed_prefix(old_lines, patch_lines)
  if not trimmed_prefix then
    return nil, prefix_err
  end

  local output = { lines = {}, old_index = 1, has_eol = old_has_eol } ---@type AiInlineDiffPatchOutput
  local found_hunk = false
  local patch_index = 1
  while patch_index <= #patch_lines do
    local line = patch_lines[patch_index]
    local header = parse_hunk_header(line)
    if header then
      found_hunk = true
      local next_index, err = apply_hunk(output, old_lines, patch_lines, patch_index + 1, header, trimmed_prefix)
      if not next_index then
        return nil, err
      end
      patch_index = next_index
    elseif is_file_header(line) then
      patch_index = patch_index + 1
    else
      return nil, "Unexpected patch line outside a hunk: " .. line
    end
  end

  if not found_hunk then
    return nil, "No unified diff hunks were found"
  end
  for index = output.old_index, #old_lines do
    output.lines[#output.lines + 1] = old_lines[index]
  end
  return join_lines(output.lines, output.has_eol, line_ending)
end

return M
