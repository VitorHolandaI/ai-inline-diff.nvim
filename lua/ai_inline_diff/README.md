# lua/ai_inline_diff

The Lua module that Neovim loads for `require("ai_inline_diff")`. It gives the
user's configuration three things: an inline review that intercepts edits from
the agent plugins (claudecode.nvim, opencode.nvim, antigravity-cli.nvim) and
from agy's PreToolUse hook (`../../bin/agy-review-hook.lua`), terminal helpers for moving between the editor and the agents' terminals, and
a way for an agent to show a file range in the editor.

- `init.lua` is the public entry point and the review engine. It replaces
  an editor window with the proposed file and hooks into each agent plugin:
  `setup_claude()` replaces `claudecode.diff` functions, `setup_opencode()`
  listens to the `OpencodeEvent:permission.*` autocmds and answers through
  `opencode.server`, and `setup_antigravity()` replaces
  `antigravity-cli.diff`. `open_review()` builds the review buffer and hands
  it to `review_changes.lua` for drawing, `review_selection.lua` for the
  first selection and `review_keys.lua` for mappings. `setup_terminal()`,
  `open_location()`, `setup_open_location()` and
  `open_location_instructions()` only forward to `terminal.lua` and
  `location.lua`.
  `antigravity_hook_start()` and `antigravity_hook_poll()` are what the agy
  hook script calls over `$NVIM`; they hand off to `agy_hook.lua`, built at
  load time with `open_review()`, `resolve_review()` and `save_wait` as its
  dependencies. `antigravity_hook_command()` gives the `command` line for
  agy's `hooks.json`.
- `agy_hook.lua` turns agy's `edit_file`/`write_file` calls into reviews.
  `new(deps)` returns a queue with `start(raw_payload)` and `poll(id)`:
  `start()` decodes the payload, answers `{ reply = allow }` at once when
  there is nothing to review (another tool, a target not in the file, an
  agy artifact), and otherwise queues the request. One request at a time
  waits for unsaved edits (`save_wait`) and then opens a review through the
  injected `open_review()`; the others wait until no review is open.
  `proposed_text()` rebuilds the file agy would write (edit_file replaces
  every match, as agy does) and `accepted_reply()` maps the accepted text
  to `allow`, or to `allow` plus agy's `overwrite` when it differs from the
  proposal. A timer closes the review when the script stops polling, which
  is what happens when agy kills the hook at its timeout.
- `opencode_event.lua` reads an OpenCode edit permission request from
  either event shape, 1.x `{ type, properties }` or 2.x `{ id, type, data }`
  with the diff in `data.metadata.files`, and answers with `permit()`, which
  takes `(id, choice)` on 1.x and `(sessionID, id, choice)` on 2.x. It
  returns a reason instead of an edit when a 2.x request has no diff or
  covers several files. `with_server()` hands the handler the server
  opencode.nvim is connected to when its url matches the event: the 2.x
  daemon needs credentials the autocmd data does not carry, so a server
  rebuilt from the url gets 401. Only `setup_opencode()` in `init.lua` uses
  this module.
- `save_wait.lua` holds an agent edit while the target buffer has unsaved
  changes. `when_saved()` runs its callback at once for a clean buffer;
  otherwise it puts a winbar notice on the windows showing the buffer and
  waits for `BufModifiedSet` (`:w`, `:e!`, undo back to the saved text) or
  a wipe, then restores the winbars and runs it. It returns a cancel
  function. The three adapters in `init.lua` call it before building a
  review, and cancel it when the agent answers or closes the diff itself.
- `text.lua` splits file content into lines and joins it back, keeping the
  final newline and CRLF endings. `init.lua` uses it to read proposals and
  OpenCode patches, and `review_changes.lua` to diff the buffer against the
  original.
- `review_changes.lua` draws a review (removed lines as `DiffDelete` virtual
  lines, proposed lines as `DiffAdd`, a `✓` sign on kept changes, through
  `draw()`, which `live_changes.lua` also uses) and
  handles `<M-y>`/`<M-x>`. `keep_selected()` marks the selected change in
  the `AiInlineDiffKept` namespace; `drop_selected()` writes the original
  lines back into the buffer. Both then diff the original against the
  buffer again and either select the next undecided change through
  `review_selection.lua` or, when none is left, call the accept or reject
  function `open_review()` passed in.
- `live_changes.lua` follows edits written without a review.
  `setup()` (called through `setup_live_changes()` in `init.lua`) keeps one
  libuv directory watcher per directory with open files, since a file
  replaced by rename would lose a per-file watcher. A change to an open,
  unmodified file reloads it with `:edit!` (cursors kept, undo kept through
  'undoreload') and draws the diff through `review_changes.draw()` in the
  `AiInlineDiffLive` namespace, cleared on InsertEnter or a later text
  change. Each such write is also announced with `vim.notify`, naming the
  file and the line counts. `init.lua` calls `expect_accepted_write()` when
  the user accepts a review, so the agent's write that follows is not
  announced.
- `review_selection.lua` moves the cursor inside a review. `select_hunk()`
  selects a change's proposed lines in linewise Visual mode,
  `select_adjacent()` does the same for the change after or before the
  cursor, and `hunk_rows()` gives the rows a change occupies. `init.lua`
  calls `select_hunk()` when a review opens, `]c`/`[c` and `<M-n>`/`<M-p>`
  call `select_adjacent()`, and `review_changes.lua` uses all three.
- `review_keys.lua` sets the buffer-local maps of a review: `da`, `dr`, `q`,
  `<leader>aa/ad` and `]c`/`[c` in Normal and Visual mode, and `<M-a>`,
  `<M-r>`, `<M-y>`, `<M-x>`, `<M-n>`, `<M-p>` in Normal, Visual and Insert
  mode. `open_review()` passes it the functions to call, so it never
  touches review state. Before resolving or deciding a change it leaves
  Insert or Visual mode.
- `windows.lua` decides which window a file should appear in:
  `find_editor_window()` prefers a window already showing the file, then the
  current or nearest window that is not a terminal, float or sidebar.
  `init.lua` uses it to place reviews and `location.lua` to place ranges.
- `paths.lua` holds `canonical_path()`, the absolute, symlink-resolved form
  used to compare file names. `init.lua`, `windows.lua` and `location.lua`
  all compare paths through it.
- `terminal.lua` owns terminal focus behavior. It creates the
  `AiInlineDiffTerminalInsert` autocmd group that enters terminal mode on
  focus, and the terminal-mode maps for `<C-w>` and `<C-h/j/k/l>`. It knows
  nothing about any agent plugin, so it works for every terminal.
- `location.lua` shows file ranges without moving focus. `open()` handles one
  location and `open_many()` a list, under a layout: `smart` picks a window
  through `windows.lua`, `tab` gives each location its own tab and returns to
  the tab the user was in, and `vsplit`/`split` open one split per location.
  Every file and range is checked before any window changes, a window with a
  pending review is never replaced (it would be wiped and rejected), and the
  ranges are highlighted in the `AiInlineDiffLocation` namespace. A location
  without a range opens the file with nothing highlighted.
  `open_for_remote()` is what `../../bin/nvim-open-location` calls over
  `$NVIM`; `setup()` puts that script on `$PATH`, and `instructions_path()`
  points at `../../instructions/open-location.md` for the agents.

Flow: the user config calls `setup_*()` on `init.lua` after each agent plugin
is set up. Agent edits then reach `open_review()` through the adapter for
that agent, or for agy 1.5 through `bin/agy-review-hook.lua`, which calls
`antigravity_hook_start()` and then polls `antigravity_hook_poll()`; terminal focus goes through the autocmd in `terminal.lua`; and an
agent that runs `nvim-open-location` lands in `location.lua` through
`--remote-expr`.
