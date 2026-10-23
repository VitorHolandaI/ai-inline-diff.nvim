# lua/ai_inline_diff

The Lua module that Neovim loads for `require("ai_inline_diff")`. It gives the
user's configuration three things: an inline review that intercepts edits from
the agent plugins (claudecode.nvim, opencode.nvim, antigravity-cli.nvim),
terminal helpers for moving between the editor and the agents' terminals, and
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
  lines, proposed lines as `DiffAdd`, a `✓` sign on kept changes) and
  handles `<M-y>`/`<M-x>`. `keep_selected()` marks the selected change in
  the `AiInlineDiffKept` namespace; `drop_selected()` writes the original
  lines back into the buffer. Both then diff the original against the
  buffer again and either select the next undecided change through
  `review_selection.lua` or, when none is left, call the accept or reject
  function `open_review()` passed in.
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
- `location.lua` shows a file range without moving focus. `open()` loads the
  file, picks a window through `windows.lua` (skipping a window with a
  pending review, which would be wiped and rejected), and highlights the
  range in the `AiInlineDiffLocation` namespace. `open_for_remote()` is what
  `../../bin/nvim-open-location` calls over `$NVIM`; `setup()` puts that
  script on `$PATH`, and `instructions_path()` points at
  `../../instructions/open-location.md` for the agents.

Flow: the user config calls `setup_*()` on `init.lua` after each agent plugin
is set up. Agent edits then reach `open_review()` through the adapter for
that agent; terminal focus goes through the autocmd in `terminal.lua`; and an
agent that runs `nvim-open-location` lands in `location.lua` through
`--remote-expr`.
