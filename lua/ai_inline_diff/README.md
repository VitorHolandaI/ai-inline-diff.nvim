# lua/ai_inline_diff

The Lua module that Neovim loads for `require("ai_inline_diff")`. It gives the
user's configuration three things: an inline review that intercepts edits from
the agent plugins (claudecode.nvim, opencode.nvim, antigravity-cli.nvim) and
from agy's PreToolUse hook (`../../bin/agy-review-hook.lua`), terminal
helpers for moving between the editor and the agents' terminals, and a way
for an agent to show a file range in the editor.

## Entry point

- `init.lua` is the public API and nothing else. `setup_claude()`,
  `setup_opencode()` and `setup_antigravity()` call `setup()` on the matching
  adapter below; `setup_opencode()` also sets the other two up again when
  their plugins are loaded, so a manual module reload leaves none bound to
  the previous copy. `apply_unified_patch()` forwards to `unified_patch.lua`.
  `antigravity_hook_start()` and `antigravity_hook_poll()` are what the agy
  hook script calls over `$NVIM`; they forward to the `agy_hook.lua` queue,
  built here at load time with `review_session.lua`, `target_file.lua` and
  `save_wait.lua` as its dependencies. `antigravity_hook_command()` gives
  the `command` line for agy's `hooks.json`. `setup_terminal()`,
  `open_location()`, `open_locations()`, `setup_open_location()`,
  `setup_live_changes()` and `open_location_instructions()` forward to
  `terminal.lua`, `location.lua` and `live_changes.lua`.

## The review

- `review_session.lua` owns the open reviews. `open(opts)` diffs the old and
  new text, puts a scratch buffer with the proposal in the window
  `windows.lua` picks, and hands it to `review_changes.lua` for drawing,
  `review_selection.lua` for the first selection and `review_keys.lua` for
  the mappings; it rejects an older review still open first. `resolve(id,
  accepted, invoke_callback)` refuses a stale accept (the file changed on
  disk or has unsaved edits), tells `live_changes.lua` to expect the
  accepted write, restores the window and calls the agent's `on_accept` or
  `on_reject`. `is_open()`, `current_id()` and `reject_matching(prefix,
  predicate)` let the adapters find their own reviews, and `close_result()`
  combines an agent plugin's "close all" return value with the count this
  plugin rejected. Every adapter and `agy_hook.lua` open reviews only
  through here.
- `review_changes.lua` draws a review (removed lines as `DiffDelete` virtual
  lines, proposed lines as `DiffAdd`, a `✓` sign on kept changes, through
  `draw()`, which `live_changes.lua` also uses) and
  handles `<M-y>`/`<M-x>`. `keep_selected()` marks the selected change in
  the `AiInlineDiffKept` namespace; `drop_selected()` writes the original
  lines back into the buffer. Both then diff the original against the
  buffer again and either select the next undecided change through
  `review_selection.lua` or, when none is left, call the accept or reject
  function `review_session.open()` passed in.
- `review_selection.lua` moves the cursor inside a review. `select_hunk()`
  selects a change's proposed lines in linewise Visual mode,
  `select_adjacent()` does the same for the change after or before the
  cursor, and `hunk_rows()` gives the rows a change occupies.
  `review_session.lua` calls `select_hunk()` when a review opens, `]c`/`[c`
  and `<M-n>`/`<M-p>` call `select_adjacent()`, and `review_changes.lua`
  uses all three.
- `review_keys.lua` sets the buffer-local maps of a review: `da`, `dr`, `q`,
  `<leader>aa/ad` and `]c`/`[c` in Normal and Visual mode, and `<M-a>`,
  `<M-r>`, `<M-y>`, `<M-x>`, `<M-n>`, `<M-p>` in Normal, Visual and Insert
  mode. `review_session.open()` passes it the functions to call, so it
  never touches review state. Before resolving or deciding a change it
  leaves Insert or Visual mode. `map_terminal()` also maps `<M-a>`/`<M-r>`
  in Terminal mode for as long as a review is open, since focus is often
  back in the agent's terminal; the function it returns, which
  `review_session.lua` calls when the review closes, removes them and
  restores a global Terminal-mode map the user had.
- `save_wait.lua` holds an agent edit while the target buffer has unsaved
  changes. `when_saved()` runs its callback at once for a clean buffer;
  otherwise it puts a winbar notice on the windows showing the buffer and
  waits for `BufModifiedSet` (`:w`, `:e!`, undo back to the saved text) or
  a wipe, then restores the winbars and runs it. It returns a cancel
  function. The adapters and `agy_hook.lua` call it before building a
  review, and cancel it when the agent answers or closes the diff itself.

## One adapter per agent

Each adapter turns its agent's request into a `review_session.open()` call
and turns the user's answer into the agent's reply.

- `claude_adapter.lua` replaces `claudecode.diff` functions. Its
  `open_diff_blocking()` runs in the coroutine Claude Code's `openDiff`
  waits on, waits for unsaved edits, opens the review and resumes the
  coroutine with `FILE_SAVED` and the final text, or `DIFF_REJECTED`,
  through claudecode.nvim's `claude_deferred_responses` table. It also
  routes `accept_current_diff`, `deny_current_diff`, `close_diff_by_tab_name`
  and the close-all functions to the inline reviews.
- `opencode_adapter.lua` listens to the `OpencodeEvent:permission.*`
  autocmds. An `edit` request for one file has its patch rebuilt by
  `unified_patch.lua` from the file as OpenCode saw it, waits for unsaved
  edits, and opens a read-only review whose answer goes back through
  `opencode_event.permit()` (`once` or `reject`, with a retry prompt when a
  rejection fails). A `permission.replied` event closes a review answered
  elsewhere.
- `antigravity_adapter.lua` replaces `antigravity-cli.diff` for agy 1.2,
  where the editor writes the accepted file itself and answers
  `ide/diffAccepted` or `ide/diffRejected`. It also defines
  `:AntigravityDiffAccept` and `:AntigravityDiffDeny`; with no review open
  they say so, and when the buffer has live-change marks
  (`live_changes.has_marks()`) that the agent already wrote those lines.
- `agy_hook.lua` turns agy 1.5's `edit_file`/`write_file` calls into
  reviews. `new(deps)` returns a queue with `start(raw_payload)` and
  `poll(id)`: `start()` decodes the payload, answers `{ reply = allow }` at
  once when there is nothing to review (another tool, a target not in the
  file, an agy artifact), and otherwise queues the request. One request at
  a time waits for unsaved edits (`save_wait`) and then opens a review
  through the injected `open_review()`; the others wait until no review is
  open. `proposed_text()` rebuilds the file agy would write (edit_file
  replaces every match, as agy does) and `accepted_reply()` maps the
  accepted text to `allow`, or to `allow` plus agy's `overwrite` when it
  differs from the proposal. A timer closes the review when the script
  stops polling, which is what happens when agy kills the hook at its
  timeout.
- `opencode_event.lua` reads an OpenCode edit permission request from
  either event shape, 1.x `{ type, properties }` or 2.x `{ id, type, data }`
  with the diff in `data.metadata.files`, and answers with `permit()`, which
  takes `(id, choice)` on 1.x and `(sessionID, id, choice)` on 2.x. It
  returns a reason instead of an edit when a 2.x request has no diff or
  covers several files. `with_server()` hands the handler the server
  opencode.nvim is connected to when its url matches the event: the 2.x
  daemon needs credentials the autocmd data does not carry, so a server
  rebuilt from the url gets 401. Only `opencode_adapter.lua` uses this
  module.

## Files and text

- `target_file.lua` reads the file an agent wants to change (`read()`),
  turns the path the agent sent into an absolute one (`resolve()`, trying
  the agent's cwd and its parents, Neovim's cwd, then `$HOME`), and finds
  its loaded buffer (`loaded_buffer()`). The adapters, `review_session.lua`
  and, through `init.lua`, `agy_hook.lua` use it.
- `unified_patch.lua` rebuilds the file an OpenCode patch produces.
  `apply(original, patch)` takes a unified diff, including jsdiff's
  `Index:` header that OpenCode 2.x writes, or a `*** Begin Patch` with one
  `*** Add File:` section. Before applying it checks whether every patch
  line lost the same leading whitespace and, if so, puts it back. It
  returns `(nil, message)` for anything it cannot apply exactly.
  `opencode_adapter.lua` and `init.lua`'s `apply_unified_patch()` use it.
- `text.lua` splits file content into lines and joins it back, keeping the
  final newline and CRLF endings. `review_session.lua`,
  `unified_patch.lua` and `antigravity_adapter.lua` use it, and
  `review_changes.lua` diffs the buffer against the original with it.
- `paths.lua` holds `canonical_path()`, the absolute, symlink-resolved form
  used to compare file names. `target_file.lua`, `windows.lua` and
  `location.lua` all compare paths through it.
- `windows.lua` decides which window a file should appear in:
  `find_editor_window()` prefers a window already showing the file, then the
  current or nearest window that is not a terminal, float or sidebar.
  `review_session.lua` and `antigravity_adapter.lua` use it to place
  reviews and `location.lua` to place ranges.

## Outside the review

- `live_changes.lua` follows edits written without a review.
  `setup()` (called through `setup_live_changes()` in `init.lua`) keeps one
  libuv directory watcher per directory with open files, since a file
  replaced by rename would lose a per-file watcher. A change to an open,
  unmodified file reloads it with `:edit!` (cursors kept, undo kept through
  'undoreload') and draws the diff through `review_changes.draw()` in the
  `AiInlineDiffLive` namespace, cleared on InsertEnter or a later text
  change. Each such write is also announced with `vim.notify`, naming the
  file and the line counts, and why no review came (a saved OpenCode
  "Always allow", Claude in auto mode, or a shell write).
  `has_marks(buf)` tells whether a buffer shows such marks.
  `review_session.resolve()` calls
  `expect_accepted_write()` when the user accepts a review, so the agent's
  write that follows is not announced.
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

## Flow

The user config calls `setup_*()` on `init.lua` after each agent plugin is
set up, which installs that agent's adapter. An agent edit then goes:
adapter (or, for agy 1.5, `bin/agy-review-hook.lua` →
`antigravity_hook_start()` → `agy_hook.lua`) → `save_wait.when_saved()` →
`review_session.open()` → the user's keys in `review_keys.lua` →
`review_session.resolve()` → the adapter's callback, which answers the
agent. Terminal focus goes through the autocmd in `terminal.lua`, and an
agent that runs `nvim-open-location` lands in `location.lua` through
`--remote-expr`.

To support another agent, add an adapter that builds the review through
`review_session.open()` with an id prefix of its own, and a `setup_*()`
function in `init.lua` that calls it.
