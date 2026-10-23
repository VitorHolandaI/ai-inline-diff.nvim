# How an edit flows through the plugin

This page follows one edit from the moment an agent proposes it to the
moment the file changes on disk, with the code that runs at each step. Line
numbers are from `v0.1.0-rc.4` and will drift as the code changes, so
search by function name if one looks off.

## The example

Claude Code wants to change three places in `sample.lua`. This is the
`claude-pick-changes` scenario in `tests/scenarios/`, so you can replay it
with `nvim -l tests/scenarios_test.lua claude-pick-changes`.

```diff
@@ -4 +4 @@
-  return "hello " .. name
+  return "hi " .. name
@@ -10 +10,3 @@
-    total = total + value
+    if value > 0 then
+      total = total + value
+    end
@@ -20 +22 @@
-  print(greet("world"))
+  print(greet("neovim"))
```

You keep the first change with `<M-y>`, drop the second with `<M-x>`, and
keep the third with `<M-y>`. Claude ends up writing the file with lines 4
and 20 changed and the loop body untouched.

## 1. The agent hands over the edit

Each agent reaches Neovim through its own plugin, and `setup_claude()`,
`setup_opencode()` or `setup_antigravity()` puts this plugin in that path.
All three end in the same call to `open_review()` with the original text,
the proposed text, and two callbacks: what to do on accept and on reject.

Claude Code calls its `openDiff` tool. claudecode.nvim runs the tool in a
coroutine and calls `diff.open_diff_blocking()`, which `setup_claude()`
replaces (`lua/ai_inline_diff/init.lua:640`):

```lua
diff.open_diff_blocking = function(old_file_path, _, new_file_contents, tab_name, client_id)
  -- ...
  local original = read_file(path) or ""
  -- ...
  local _, open_err = open_review({
    id = id,
    path = path,
    old_text = original,
    new_text = new_file_contents,
    -- ...
    on_accept = function(content)
      resume(claude_result(true, tab_name, content))
    end,
    on_reject = function()
      resume(claude_result(false, tab_name))
    end,
  })
  -- ...
  return coroutine.yield()
end
```

The coroutine stops at `coroutine.yield()`. Claude keeps waiting until one
of the callbacks resumes it.

OpenCode sends a patch instead of the full file. It arrives as the
`OpencodeEvent:permission.asked` autocmd, in one of two shapes: OpenCode
1.x puts it in `properties.metadata.diff`, 2.x in
`data.metadata.files[1].patch`. `opencode_event.edit_request()` reads
either one, and the plugin rebuilds the proposed file from the patch before
it opens the review (`init.lua:559`):

```lua
local original = read_file(path) or ""
local proposed, patch_err = M.apply_unified_patch(original, edit.diff)
```

If the patch cannot be rebuilt, no review opens and the permission stays
pending in OpenCode's terminal. Antigravity calls `antigravity-cli.diff.open()`
with the full proposed file, which `setup_antigravity()` replaces.

## 2. The texts become a list of changes

`open_review()` diffs the two texts (`init.lua:156`):

```lua
local hunks = vim.text.diff(normalized_old, normalized_new, {
  algorithm = "histogram",
  result_type = "indices",
})
```

With `result_type = "indices"`, `vim.text.diff()` returns one entry per
change: `{ old_start, old_count, new_start, new_count }`, counted in
lines from 1. For the example it returns:

```lua
{ { 4, 1, 4, 1 }, { 10, 1, 10, 3 }, { 20, 1, 22, 1 } }
```

The second entry reads as "1 line at line 10 of the original becomes 3
lines at line 10 of the proposal". The third starts at line 22 in the
proposal because the second change added two lines above it.

## 3. The review replaces the editor window

`open_review()` then builds a scratch buffer holding the proposed text and
puts it in the window that showed the file (`init.lua:161-208`). The
buffer has `buftype=acwrite`, so `:write` triggers the plugin instead of
touching the disk. The window's previous buffer and cursor are saved so
they can come back when the review ends.

`review_changes.render()` (`lua/ai_inline_diff/review_changes.lua:50`)
draws each change with extmarks. The proposed lines get `DiffAdd` and a
`+` sign; the original lines are not in the buffer at all, so they are
shown as virtual lines in `DiffDelete` above the change. Finally
`review_selection.select_hunk()` (`review_selection.lua:23`) moves the
cursor to the first change and selects it in linewise Visual mode.

## 4. You decide, change by change

`review_keys.map()` (`review_keys.lua:35`) maps the keys in the review
buffer only. `<M-y>` calls `review_changes.keep_selected()`
(`review_changes.lua:159`), which marks the change with an extmark in the
`AiInlineDiffKept` namespace. The mark sits on the text, so it moves
along when lines above it are added or removed.

`<M-x>` calls `drop_selected()` (`review_changes.lua:172`), which writes
the original lines back over the proposed ones
(`restore_original_lines()`, line 110):

```lua
local original = vim.list_slice(old_lines, hunk[1], hunk[1] + hunk[2] - 1)
if hunk[4] > 0 then
  vim.api.nvim_buf_set_lines(review.buf, hunk[3] - 1, hunk[3] - 1 + hunk[4], false, original)
else
  vim.api.nvim_buf_set_lines(review.buf, hunk[3], hunk[3], false, original)
end
```

In the example, dropping `{ 10, 1, 10, 3 }` replaces buffer lines 10 to 12
(`if value > 0 then`, `total = total + value`, `end`) with original line
10 (`total = total + value`).

Both keys then call `continue_or_finish()` (line 126). It diffs the
original against the buffer again, because the buffer no longer matches
the list from step 2: the dropped change is gone and the third change
moved up from line 22 to line 20. Then it picks the next change without a
kept mark. When none is left, it ends the review: accept if any change is
still in the buffer, reject if you dropped them all.

```lua
if #pending == 0 then
  local finish = #review.hunks > 0 and resolvers.accept or resolvers.reject
  finish()
  return
end
```

`<M-a>` and `<M-r>` skip all of this and accept or reject the buffer as it
is. You can also edit the buffer by hand before accepting (Claude and
Antigravity only, since OpenCode reviews are read-only).

## 5. Accepting reads the buffer back

`resolve_review()` (`init.lua:101`) first checks that the file did not
change while you were reviewing. It compares the file on disk with the
original text and looks at the file's buffer for unsaved changes or a new
`changedtick`. If anything moved, it refuses with "AI edit is stale" and
the review stays open.

Then it reads the review buffer as text, puts the original buffer back in
the window, and calls the agent's callback with that text:

```lua
local proposed_text = get_buffer_text(review.buf)
vim.bo[review.buf].modified = false
restore_review(review)

if invoke_callback ~= false then
  local callback = accepted and review.on_accept or review.on_reject
  local ok, err = pcall(callback, proposed_text)
  -- ...
end
```

`get_buffer_text()` (`init.lua:72`) joins the lines with the file's own
line ending (LF or CRLF) and keeps or drops the final newline to match.

## 6. The file gets written

Which side writes the file depends on the agent. For Claude Code, the
accept callback resumes the waiting coroutine with `FILE_SAVED` and the
final text (`claude_result()`, `init.lua:617`):

```lua
return { content = { { type = "text", text = "FILE_SAVED" }, { type = "text", text = content } } }
```

claudecode.nvim's own diff view sends the same reply
(`claudecode/diff.lua`), so hand edits made in the review travel with the
text. Neovim leaves the file alone here and Claude Code writes it once the
reply arrives. A rejection sends `DIFF_REJECTED` instead.

Antigravity's accept callback writes the file from Neovim
(`init.lua:846`). It puts the text into the file's buffer, runs
`:write!`, and then tells Antigravity the diff was accepted:

```lua
local lines, has_eol = split_text(new_content)
-- ...
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
vim.api.nvim_buf_call(target_buf, function()
  vim.cmd("silent! write!")
end)
-- ...
send_diff_response("ide/diffAccepted", filePath)
```

OpenCode applies its own patch. The plugin only answers the permission
request with `once` or `reject` through `opencode_event.permit()`
(`init.lua:526`), which calls `server:permit(id, choice)` on 1.x and
`server:permit(sessionID, id, choice)` on 2.x. On 2.x the reply has to go
through the server opencode.nvim is already connected to
(`opencode_event.with_server()`): the background server requires
credentials, and the autocmd only passes its url.
The review is read-only, so what you saw is the patch OpenCode was asking
to apply, rebuilt by `apply_unified_patch()`.

## Where this is tested

`tests/scenarios_test.lua` replays the example and 18 other cases through
the real claudecode.nvim and antigravity-cli.nvim, and checks the final
text byte for byte. `tests/patch_test.lua` covers how OpenCode patches are
rebuilt, `tests/claude_adapter_test.lua` covers the reply to Claude, and
`tests/review_test.lua` covers selection and the keys in each mode.
