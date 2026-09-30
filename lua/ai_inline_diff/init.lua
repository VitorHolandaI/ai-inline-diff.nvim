local M = {}

local namespace = vim.api.nvim_create_namespace("AiInlineDiff")
local reviews = {}
local current_review
local resolved_opencode_permissions = {}

local excluded_filetypes = {
  aerial = true,
  minifiles = true,
  netrw = true,
  neo_tree = true,
  ["neo-tree"] = true,
  NvimTree = true,
  oil = true,
  snacks_picker_list = true,
  tagbar = true,
}

local function split_text(text)
  local line_ending = text:find("\r\n", 1, true) and "\r\n" or "\n"
  text = text:gsub("\r\n", "\n")
  if text == "" then
    return {}, false, line_ending
  end

  local has_eol = text:sub(-1) == "\n"
  local lines = vim.split(text, "\n", { plain = true })
  if has_eol then
    table.remove(lines)
  end
  return lines, has_eol, line_ending
end

local function join_lines(lines, has_eol, line_ending)
  line_ending = line_ending or "\n"
  local text = table.concat(lines, line_ending)
  return has_eol and (text .. line_ending) or text
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end

  local text = file:read("*a")
  file:close()
  return text
end

local function canonical_path(path)
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return vim.uv.fs_realpath(absolute) or absolute
end

local function resolve_path(path, base_dir)
  if path:sub(1, 1) ~= "/" and base_dir then
    local directory = vim.fs.normalize(base_dir)
    while directory do
      local candidate = vim.fs.normalize(vim.fs.joinpath(directory, path))
      if vim.fn.filereadable(candidate) == 1 then
        return canonical_path(candidate)
      end
      local parent = vim.fs.dirname(directory)
      if not parent or parent == directory then
        break
      end
      directory = parent
    end
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(absolute) == 1 then
    return canonical_path(absolute)
  end

  if vim.env.HOME and vim.env.HOME ~= "" then
    local home_path = vim.fs.normalize(vim.fs.joinpath(vim.env.HOME, path))
    if vim.fn.filereadable(home_path) == 1 then
      return canonical_path(home_path)
    end
  end

  return vim.fs.normalize(absolute)
end

local function is_editor_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local config = vim.api.nvim_win_get_config(win)
  if config.relative and config.relative ~= "" then
    return false
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local buftype = vim.bo[buf].buftype
  local filetype = vim.bo[buf].filetype
  return buftype ~= "terminal" and buftype ~= "prompt" and not excluded_filetypes[filetype]
end

local function find_editor_window(path)
  local normalized_path = path and canonical_path(path)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if
      normalized_path
      and canonical_path(vim.api.nvim_buf_get_name(buf)) == normalized_path
      and is_editor_window(win)
    then
      return win
    end
  end

  local current = vim.api.nvim_get_current_win()
  if is_editor_window(current) then
    return current
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if is_editor_window(win) then
      return win
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_editor_window(win) then
      return win
    end
  end
end

local function find_loaded_buffer(path)
  local normalized_path = canonical_path(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and canonical_path(name) == normalized_path then
        return buf
      end
    end
  end
end

local function get_buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" and vim.b[buf].ai_inline_diff_empty then
    return ""
  end
  return join_lines(lines, vim.bo[buf].endofline, vim.b[buf].ai_inline_diff_line_ending)
end

local function restore_review(review)
  reviews[review.id] = nil
  if current_review == review.id then
    current_review = nil
  end

  if vim.api.nvim_win_is_valid(review.win) then
    if vim.api.nvim_win_get_buf(review.win) == review.buf and vim.api.nvim_buf_is_valid(review.previous_buf) then
      vim.api.nvim_win_set_buf(review.win, review.previous_buf)
      local line_count = vim.api.nvim_buf_line_count(review.previous_buf)
      local cursor = { math.min(review.previous_cursor[1], math.max(line_count, 1)), review.previous_cursor[2] }
      pcall(vim.api.nvim_win_set_cursor, review.win, cursor)
    end
    vim.wo[review.win].signcolumn = review.previous_signcolumn
  end

  if vim.api.nvim_buf_is_valid(review.buf) then
    vim.api.nvim_buf_delete(review.buf, { force = true })
  end
end

local function resolve_review(id, accepted, invoke_callback)
  local review = reviews[id]
  if not review or review.resolving then
    return false
  end

  if accepted then
    local disk_text = read_file(review.path) or ""
    local target_changed = disk_text ~= review.original_text
    local target_buf = find_loaded_buffer(review.path)
    if target_buf then
      target_changed = target_changed or vim.bo[target_buf].modified
      if target_buf == review.target_buf then
        target_changed = target_changed or vim.api.nvim_buf_get_changedtick(target_buf) ~= review.target_changedtick
      end
    end
    if target_changed then
      vim.notify(
        "AI edit is stale: the target changed during review; reject it and request a new edit",
        vim.log.levels.ERROR
      )
      return false
    end
  end

  review.resolving = true
  local proposed_text = get_buffer_text(review.buf)
  vim.bo[review.buf].modified = false
  restore_review(review)

  if invoke_callback ~= false then
    local callback = accepted and review.on_accept or review.on_reject
    local ok, err = pcall(callback, proposed_text)
    if not ok then
      vim.notify("Failed to resolve AI edit: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  return true
end

local function navigate(review, direction)
  if not vim.api.nvim_win_is_valid(review.win) or #review.hunks == 0 then
    return
  end

  local row = vim.api.nvim_win_get_cursor(review.win)[1]
  local target
  if direction == "next" then
    for _, hunk in ipairs(review.hunks) do
      local hunk_row = math.max(hunk[3], 1)
      if hunk_row > row then
        target = hunk_row
        break
      end
    end
    target = target or math.max(review.hunks[1][3], 1)
  else
    for index = #review.hunks, 1, -1 do
      local hunk_row = math.max(review.hunks[index][3], 1)
      if hunk_row < row then
        target = hunk_row
        break
      end
    end
    target = target or math.max(review.hunks[#review.hunks][3], 1)
  end

  local line_count = vim.api.nvim_buf_line_count(review.buf)
  vim.api.nvim_win_set_cursor(review.win, { math.min(target, line_count), 0 })
end

local function render_hunks(review, old_lines, new_lines)
  for _, hunk in ipairs(review.hunks) do
    local old_start, old_count, new_start, new_count = unpack(hunk)

    if old_count > 0 then
      local virtual_lines = {}
      for index = old_start, old_start + old_count - 1 do
        virtual_lines[#virtual_lines + 1] = {
          { "- ", "DiffDelete" },
          { old_lines[index] or "", "DiffDelete" },
        }
      end

      local row
      local above
      if new_count > 0 or new_start == 0 then
        row = math.max(new_start - 1, 0)
        above = true
      else
        row = math.max(new_start - 1, 0)
        above = false
      end

      vim.api.nvim_buf_set_extmark(review.buf, namespace, row, 0, {
        strict = false,
        virt_lines = virtual_lines,
        virt_lines_above = above,
      })
    end

    for index = new_start, new_start + new_count - 1 do
      if index >= 1 and index <= #new_lines then
        vim.api.nvim_buf_set_extmark(review.buf, namespace, index - 1, 0, {
          line_hl_group = "DiffAdd",
          sign_text = "+",
          sign_hl_group = "DiffAdd",
        })
      end
    end
  end
end

local function open_review(opts)
  if current_review and reviews[current_review] then
    resolve_review(current_review, false)
  end

  local win = find_editor_window(opts.path)
  if not win then
    return nil, "No editor window is available for the inline diff"
  end

  local old_lines, old_has_eol = split_text(opts.old_text)
  local new_lines, new_has_eol, new_line_ending = split_text(opts.new_text)
  local normalized_old = join_lines(old_lines, old_has_eol)
  local normalized_new = join_lines(new_lines, new_has_eol)
  local hunks = vim.diff(normalized_old, normalized_new, {
    algorithm = "histogram",
    result_type = "indices",
  })

  local buf = vim.api.nvim_create_buf(false, true)
  local safe_id = tostring(opts.id):gsub("[^%w_.-]", "_")
  local name = string.format("ai-inline-diff://%s/%s", safe_id, vim.fs.basename(opts.path))
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].undofile = false
  vim.bo[buf].endofline = new_has_eol
  vim.bo[buf].fixendofline = false
  vim.bo[buf].fileformat = new_line_ending == "\r\n" and "dos" or "unix"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #new_lines == 0 and { "" } or new_lines)
  vim.bo[buf].modifiable = opts.editable ~= false
  vim.bo[buf].modified = false
  vim.b[buf].ai_inline_diff_empty = #new_lines == 0
  vim.b[buf].ai_inline_diff_id = opts.id
  vim.b[buf].ai_inline_diff_line_ending = new_line_ending
  if opts.claude_tab_name then
    vim.b[buf].claudecode_diff_tab_name = opts.claude_tab_name
  end

  local filetype = vim.filetype.match({ filename = opts.path })
  if filetype then
    vim.bo[buf].filetype = filetype
  end

  local review = {
    id = opts.id,
    buf = buf,
    win = win,
    path = opts.path,
    hunks = hunks,
    previous_buf = vim.api.nvim_win_get_buf(win),
    previous_cursor = vim.api.nvim_win_get_cursor(win),
    previous_signcolumn = vim.wo[win].signcolumn,
    original_text = opts.old_text,
    target_buf = find_loaded_buffer(opts.path),
    on_accept = opts.on_accept,
    on_reject = opts.on_reject,
    client_id = opts.client_id,
  }
  review.target_changedtick = review.target_buf and vim.api.nvim_buf_get_changedtick(review.target_buf) or nil
  reviews[opts.id] = review
  current_review = opts.id

  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].signcolumn = "yes"
  render_hunks(review, old_lines, new_lines)

  local first_hunk = hunks[1]
  if first_hunk then
    vim.api.nvim_win_set_cursor(win, { math.min(math.max(first_hunk[3], 1), vim.api.nvim_buf_line_count(buf)), 0 })
  end
  vim.api.nvim_set_current_win(win)

  local function accept()
    resolve_review(opts.id, true)
  end
  local function reject()
    resolve_review(opts.id, false)
  end

  vim.keymap.set("n", "da", accept, { buffer = buf, desc = "Accept AI edit" })
  vim.keymap.set("n", "dr", reject, { buffer = buf, desc = "Reject AI edit" })
  vim.keymap.set("n", "q", reject, { buffer = buf, desc = "Reject AI edit" })
  vim.keymap.set("n", "]c", function()
    navigate(review, "next")
  end, { buffer = buf, desc = "Next AI change" })
  vim.keymap.set("n", "[c", function()
    navigate(review, "previous")
  end, { buffer = buf, desc = "Previous AI change" })
  vim.keymap.set("n", "<leader>aa", accept, { buffer = buf, desc = "Accept AI edit" })
  vim.keymap.set("n", "<leader>ad", reject, { buffer = buf, desc = "Reject AI edit" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = accept,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if reviews[opts.id] and not review.resolving then
        resolve_review(opts.id, false)
      end
    end,
  })

  vim.notify("AI edit: da accept, dr/q reject, [c/]c navigate", vim.log.levels.INFO)
  return review
end

local function detect_trimmed_patch_prefix(old_lines, patch_lines)
  local old_index = 1
  local patch_index = 1
  local detected_prefix
  local matched_directly = false
  local matched_with_prefix = false

  while patch_index <= #patch_lines do
    local line = patch_lines[patch_index]
    local old_start, old_count, _, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if not old_start then
      patch_index = patch_index + 1
    else
      old_start = tonumber(old_start)
      old_count = tonumber(old_count ~= "" and old_count or "1")
      new_count = tonumber(new_count ~= "" and new_count or "1")
      old_index = math.max(old_count == 0 and old_start + 1 or old_start, 1)
      patch_index = patch_index + 1

      local consumed_old = 0
      local consumed_new = 0
      while patch_index <= #patch_lines and (consumed_old < old_count or consumed_new < new_count) do
        line = patch_lines[patch_index]
        local kind = line:sub(1, 1)
        local content = line:sub(2)
        if kind == " " or kind == "-" then
          local original_line = old_lines[old_index]
          if original_line == content then
            if content ~= "" then
              matched_directly = true
            end
          elseif original_line and content ~= "" and #content <= #original_line then
            local prefix_length = #original_line - #content
            local prefix = original_line:sub(1, prefix_length)
            if original_line:sub(prefix_length + 1) ~= content or not prefix:match("^%s+$") then
              return nil, "Patch content does not match the original file"
            end
            if detected_prefix and detected_prefix ~= prefix then
              return nil, "Patch has inconsistent trimmed indentation"
            end
            detected_prefix = prefix
            matched_with_prefix = true
          else
            return nil, "Patch content does not match the original file"
          end
          old_index = old_index + 1
          consumed_old = consumed_old + 1
          if kind == " " then
            consumed_new = consumed_new + 1
          end
        elseif kind == "+" then
          consumed_new = consumed_new + 1
        else
          return nil, "Unsupported patch line: " .. line
        end
        patch_index = patch_index + 1
        if patch_lines[patch_index] == "\\ No newline at end of file" then
          patch_index = patch_index + 1
        end
      end
    end
  end

  if matched_directly and matched_with_prefix then
    return nil, "Patch has ambiguous trimmed indentation"
  end
  return detected_prefix or ""
end

function M.apply_unified_patch(original, patch)
  if patch:match("^%*%*%* Begin Patch") then
    local patch_lines = split_text(patch)
    local output = {}
    local collecting = false

    for _, line in ipairs(patch_lines) do
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

  local old_lines, old_has_eol, line_ending = split_text(original)
  local patch_lines = split_text(patch)
  local trimmed_prefix, prefix_err = detect_trimmed_patch_prefix(old_lines, patch_lines)
  if not trimmed_prefix then
    return nil, prefix_err
  end
  local output = {}
  local old_index = 1
  local patch_index = 1
  local found_hunk = false
  local new_has_eol = old_has_eol

  while patch_index <= #patch_lines do
    local line = patch_lines[patch_index]
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if not old_start then
      local is_header = line == ""
        or line:match("^diff %-%-git ")
        or line:match("^index ")
        or line:match("^%-%-%- ")
        or line:match("^%+%+%+ ")
      if not is_header then
        return nil, "Unexpected patch line outside a hunk: " .. line
      end
      patch_index = patch_index + 1
    else
      found_hunk = true
      old_start = tonumber(old_start)
      old_count = tonumber(old_count ~= "" and old_count or "1")
      new_start = tonumber(new_start)
      new_count = tonumber(new_count ~= "" and new_count or "1")

      local target = old_count == 0 and old_start + 1 or old_start
      target = math.max(target, 1)
      if target < old_index or target > #old_lines + 1 then
        return nil, "Patch hunks overlap or point outside the original file"
      end
      while old_index < target do
        output[#output + 1] = old_lines[old_index]
        old_index = old_index + 1
      end
      local expected_new_lines_before = new_count == 0 and new_start or new_start - 1
      if #output ~= expected_new_lines_before then
        return nil, "Patch hunks have inconsistent new-file positions"
      end

      patch_index = patch_index + 1
      local consumed_old = 0
      local consumed_new = 0
      local last_kind
      local last_new_line_has_eol
      local touches_eof = (old_count == 0 and target == #old_lines + 1)
        or (old_count > 0 and old_start + old_count - 1 >= #old_lines)
      while patch_index <= #patch_lines and (consumed_old < old_count or consumed_new < new_count) do
        line = patch_lines[patch_index]
        local kind = line:sub(1, 1)
        local content = line:sub(2)
        local restored_content = content == "" and "" or trimmed_prefix .. content

        if kind == " " then
          if old_lines[old_index] ~= content and old_lines[old_index] ~= restored_content then
            return nil, "Patch context does not match " .. tostring(old_index)
          end
          output[#output + 1] = old_lines[old_index]
          old_index = old_index + 1
          consumed_old = consumed_old + 1
          consumed_new = consumed_new + 1
          last_new_line_has_eol = true
        elseif kind == "-" then
          if old_lines[old_index] ~= content and old_lines[old_index] ~= restored_content then
            return nil, "Patch removal does not match " .. tostring(old_index)
          end
          old_index = old_index + 1
          consumed_old = consumed_old + 1
        elseif kind == "+" then
          output[#output + 1] = restored_content
          consumed_new = consumed_new + 1
          last_new_line_has_eol = true
        else
          return nil, "Unsupported patch line: " .. line
        end

        last_kind = kind
        patch_index = patch_index + 1
        if patch_lines[patch_index] == "\\ No newline at end of file" then
          if last_kind == "+" or last_kind == " " then
            last_new_line_has_eol = false
          end
          patch_index = patch_index + 1
        end
      end

      if consumed_old ~= old_count or consumed_new ~= new_count then
        return nil, "Patch hunk has inconsistent line counts"
      end
      if touches_eof then
        if new_count > 0 then
          new_has_eol = last_new_line_has_eol
        else
          new_has_eol = #output > 0
        end
      end
    end
  end

  if not found_hunk then
    return nil, "No unified diff hunks were found"
  end

  while old_index <= #old_lines do
    output[#output + 1] = old_lines[old_index]
    old_index = old_index + 1
  end
  return join_lines(output, new_has_eol, line_ending)
end

local function opencode_permission_key(url, id)
  return tostring(url) .. ":" .. tostring(id)
end

local function notify_permission_error(err)
  vim.notify("Failed to answer OpenCode permission: " .. tostring(err), vim.log.levels.ERROR)
end

function M.setup_opencode()
  pcall(vim.api.nvim_del_augroup_by_name, "OpencodeEdits")
  local group = vim.api.nvim_create_augroup("AiInlineOpencodeEdits", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "OpencodeEvent:permission.asked", "OpencodeEvent:permission.replied" },
    callback = function(args)
      local event = args.data.event
      if event.type == "permission.replied" then
        local key = opencode_permission_key(args.data.url, event.properties.requestID)
        resolved_opencode_permissions[key] = true
        resolve_review("opencode:" .. key, false, false)
        vim.defer_fn(function()
          resolved_opencode_permissions[key] = nil
        end, 60000)
        return
      end
      if event.type ~= "permission.asked" or event.properties.permission ~= "edit" then
        return
      end

      local permission_key = opencode_permission_key(args.data.url, event.properties.id)
      resolved_opencode_permissions[permission_key] = false
      local id = "opencode:" .. permission_key
      require("opencode.server")
        .new(args.data.url)
        :next(function(server)
          if resolved_opencode_permissions[permission_key] then
            return
          end

          local function submit_reply(choice, on_failure)
            if resolved_opencode_permissions[permission_key] then
              return
            end
            server:permit(event.properties.id, choice):catch(function(err)
              notify_permission_error(err)
              if not resolved_opencode_permissions[permission_key] and on_failure then
                on_failure()
              end
            end)
          end

          local function reject_with_retry()
            local function retry_reject()
              vim.ui.select(
                { "Retry reject", "Leave pending" },
                { prompt = "OpenCode rejection failed" },
                function(choice)
                  if choice == "Retry reject" and not resolved_opencode_permissions[permission_key] then
                    submit_reply("reject", retry_reject)
                  end
                end
              )
            end
            submit_reply("reject", retry_reject)
          end

          local path = resolve_path(event.properties.metadata.filepath, server.cwd)
          local loaded_buf = find_loaded_buffer(path)
          if loaded_buf and vim.bo[loaded_buf].modified then
            vim.notify("OpenCode edit rejected: the target buffer has unsaved changes", vim.log.levels.ERROR)
            reject_with_retry()
            return
          end

          local original = read_file(path) or ""
          local proposed, patch_err = M.apply_unified_patch(original, event.properties.metadata.diff)
          if not proposed then
            vim.notify(
              "OpenCode diff could not be rendered; answer the pending permission in its terminal: " .. patch_err,
              vim.log.levels.WARN
            )
            return
          end

          local function show_review()
            if resolved_opencode_permissions[permission_key] then
              return
            end
            if current_review and current_review ~= id then
              vim.notify("OpenCode edit rejected because another AI review is active", vim.log.levels.WARN)
              reject_with_retry()
              return
            end

            local function reply(choice)
              submit_reply(choice, show_review)
            end

            local _, open_err = open_review({
              id = id,
              path = path,
              old_text = original,
              new_text = proposed,
              editable = false,
              on_accept = function()
                reply("once")
              end,
              on_reject = function()
                reply("reject")
              end,
            })
            if open_err then
              vim.notify("Cannot open OpenCode inline diff: " .. open_err, vim.log.levels.ERROR)
              reply("reject")
            end
          end
          show_review()
        end)
        :catch(function(err)
          vim.notify("Failed to review OpenCode edit: " .. tostring(err), vim.log.levels.ERROR)
        end)
    end,
    desc = "Review OpenCode edits inline",
  })

  -- A manual module reload must not leave Claude or Antigravity bound to the previous copy.
  if package.loaded["claudecode.diff"] then
    M.setup_claude()
  end
  if package.loaded["antigravity-cli.diff"] then
    M.setup_antigravity()
  end
end

local function claude_result(saved, tab_name, content)
  if saved then
    return { content = { { type = "text", text = "FILE_SAVED" }, { type = "text", text = content } } }
  end
  return { content = { { type = "text", text = "DIFF_REJECTED" }, { type = "text", text = tab_name } } }
end

function M.setup_claude()
  local diff = require("claudecode.diff")
  local originals = rawget(diff, "_ai_inline_diff_originals")
  if not originals then
    originals = {
      accept = diff.accept_current_diff,
      reject = diff.deny_current_diff,
      close = diff.close_diff_by_tab_name,
      cleanup_all = diff._cleanup_all_active_diffs,
      close_all = diff.close_all_diffs,
      close_pending = diff.close_pending_diffs,
      close_for_client = diff.close_diffs_for_client,
    }
    diff._ai_inline_diff_originals = originals
  end

  diff.open_diff_blocking = function(old_file_path, _, new_file_contents, tab_name, client_id)
    local co, is_main = coroutine.running()
    if not co or is_main then
      error({ code = -32000, message = "Internal server error", data = "openDiff must run in coroutine context" })
    end

    local path = resolve_path(old_file_path)
    local loaded_buf = find_loaded_buffer(path)
    if loaded_buf and vim.bo[loaded_buf].modified then
      error({
        code = -32000,
        message = "Inline diff setup failed",
        data = "The target buffer has unsaved changes: " .. path,
      })
    end

    local original = read_file(path) or ""
    local id = "claude:" .. tab_name

    local function resume(result)
      local ok, resumed_result = coroutine.resume(co, result)
      local co_key = tostring(co)
      local sender = _G.claude_deferred_responses and _G.claude_deferred_responses[co_key]
      if sender then
        if ok then
          sender(resumed_result)
        else
          sender({ error = { code = -32603, message = "Internal error", data = tostring(resumed_result) } })
        end
        _G.claude_deferred_responses[co_key] = nil
      end
    end

    local _, open_err = open_review({
      id = id,
      path = path,
      old_text = original,
      new_text = new_file_contents,
      claude_tab_name = tab_name,
      client_id = client_id,
      on_accept = function(content)
        resume(claude_result(true, tab_name, content))
      end,
      on_reject = function()
        resume(claude_result(false, tab_name))
      end,
    })
    if open_err then
      error({ code = -32000, message = "Inline diff setup failed", data = open_err })
    end

    return coroutine.yield()
  end

  diff.accept_current_diff = function()
    local id = vim.b.ai_inline_diff_id
    if id and reviews[id] then
      resolve_review(id, true)
      return
    end
    originals.accept()
  end

  diff.deny_current_diff = function()
    local id = vim.b.ai_inline_diff_id
    if id and reviews[id] then
      resolve_review(id, false)
      return
    end
    originals.reject()
  end

  diff.close_diff_by_tab_name = function(tab_name)
    local id = "claude:" .. tab_name
    if reviews[id] then
      resolve_review(id, false)
      return true
    end
    vim.defer_fn(function()
      vim.cmd("checktime")
    end, 100)
    return originals.close(tab_name)
  end

  local function reject_claude_reviews(predicate)
    local ids = {}
    for id, review in pairs(reviews) do
      if id:sub(1, 7) == "claude:" and predicate(review) then
        ids[#ids + 1] = id
      end
    end
    for _, id in ipairs(ids) do
      resolve_review(id, false)
    end
    return #ids
  end

  diff._cleanup_all_active_diffs = function(...)
    reject_claude_reviews(function()
      return true
    end)
    return originals.cleanup_all(...)
  end

  if originals.close_all then
    diff.close_all_diffs = function(...)
      local count = reject_claude_reviews(function()
        return true
      end)
      local result = originals.close_all(...)
      return type(result) == "number" and result + count or result or count
    end
  end

  if originals.close_pending then
    diff.close_pending_diffs = function(...)
      local count = reject_claude_reviews(function()
        return true
      end)
      local result = originals.close_pending(...)
      return type(result) == "number" and result + count or result or count
    end
  end

  if originals.close_for_client then
    diff.close_diffs_for_client = function(client_id, ...)
      local count = reject_claude_reviews(function(review)
        return review.client_id == client_id
      end)
      local result = originals.close_for_client(client_id, ...)
      return type(result) == "number" and result + count or result or count
    end
  end
end

function M.setup_antigravity()
  local ok, diff = pcall(require, "antigravity-cli.diff")
  if not ok then
    return
  end

  local originals = rawget(diff, "_ai_inline_diff_originals")
  if not originals then
    originals = {
      open = diff.open,
      close = diff.close,
      close_all = diff.close_all_diffs,
    }
    diff._ai_inline_diff_originals = originals
  end

  local function send_diff_response(method, filePath)
    if type(diff.send_diff_response) == "function" then
      diff.send_diff_response(method, filePath)
    else
      local server_ok, server = pcall(require, "antigravity-cli.server")
      if server_ok and server.notify then
        server.notify({
          method = method,
          params = {
            filePath = filePath,
          },
        })
      end
    end
  end

  local function reject_antigravity_reviews(predicate)
    local ids = {}
    for id, review in pairs(reviews) do
      if id:sub(1, 12) == "antigravity:" and (not predicate or predicate(review)) then
        ids[#ids + 1] = id
      end
    end
    for _, id in ipairs(ids) do
      resolve_review(id, false)
    end
    return #ids
  end

  diff.open = function(filePath, content)
    local path = resolve_path(filePath)
    local loaded_buf = find_loaded_buffer(path)
    if loaded_buf and vim.bo[loaded_buf].modified then
      vim.notify(
        "Antigravity edit rejected: the target buffer has unsaved changes: " .. path,
        vim.log.levels.ERROR
      )
      send_diff_response("ide/diffRejected", filePath)
      return { status = "rejected" }
    end

    local win = find_editor_window(path)
    if not win then
      vim.cmd("split")
    end

    local original = read_file(path) or ""
    local id = "antigravity:" .. path

    local _, open_err = open_review({
      id = id,
      path = path,
      old_text = original,
      new_text = content,
      editable = true,
      on_accept = function(new_content)
        local target_buf = find_loaded_buffer(path)
        if not target_buf then
          target_buf = vim.fn.bufnr(path, true)
        end
        if not vim.api.nvim_buf_is_loaded(target_buf) then
          vim.fn.bufload(target_buf)
        end

        local lines, has_eol = split_text(new_content)
        if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
          vim.bo[target_buf].endofline = has_eol
          vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
          vim.api.nvim_buf_call(target_buf, function()
            vim.cmd("silent! write!")
          end)
        else
          local file, write_err = io.open(path, "wb")
          if file then
            file:write(new_content)
            file:close()
          else
            vim.notify(
              "Failed to write Antigravity edit to " .. path .. ": " .. tostring(write_err),
              vim.log.levels.ERROR
            )
          end
        end

        send_diff_response("ide/diffAccepted", filePath)
        vim.defer_fn(function()
          vim.cmd("checktime")
        end, 100)
      end,
      on_reject = function()
        send_diff_response("ide/diffRejected", filePath)
      end,
    })

    if open_err then
      vim.notify("Cannot open Antigravity inline diff: " .. open_err, vim.log.levels.ERROR)
      send_diff_response("ide/diffRejected", filePath)
      return { status = "rejected" }
    end

    return { status = "opened" }
  end

  vim.api.nvim_create_user_command("AntigravityDiffAccept", function()
    local buf = vim.api.nvim_get_current_buf()
    local id = vim.b[buf].ai_inline_diff_id
    if id and reviews[id] then
      resolve_review(id, true)
      return
    end
    if current_review and current_review:sub(1, 12) == "antigravity:" then
      resolve_review(current_review, true)
      return
    end
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%(proposed%)$") then
      vim.cmd("write")
    else
      vim.notify("Antigravity CLI: Not in a diff buffer", vim.log.levels.ERROR)
    end
  end, { force = true })

  vim.api.nvim_create_user_command("AntigravityDiffDeny", function()
    local buf = vim.api.nvim_get_current_buf()
    local id = vim.b[buf].ai_inline_diff_id
    if id and reviews[id] then
      resolve_review(id, false)
      return
    end
    if current_review and current_review:sub(1, 12) == "antigravity:" then
      resolve_review(current_review, false)
      return
    end
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%(proposed%)$") then
      vim.cmd("quit")
    else
      vim.notify("Antigravity CLI: Not in a diff buffer", vim.log.levels.ERROR)
    end
  end, { force = true })

  diff.close_all_diffs = function(...)
    local count = reject_antigravity_reviews()
    if originals.close_all then
      local result = originals.close_all(...)
      return type(result) == "number" and result + count or result or count
    end
    return count
  end

  if originals.close then
    diff.close = function(filePath, ...)
      local id = "antigravity:" .. resolve_path(filePath)
      if reviews[id] then
        resolve_review(id, false)
        return true
      end
      return originals.close(filePath, ...)
    end
  end
end

return M
