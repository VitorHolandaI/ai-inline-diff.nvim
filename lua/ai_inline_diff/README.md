# lua/ai_inline_diff

The Lua module that Neovim loads for `require("ai_inline_diff")`. It gives the
user's configuration three things: an inline review that intercepts edits from
the agent plugins (claudecode.nvim, opencode.nvim, antigravity-cli.nvim),
terminal helpers for moving between the editor and the agents' terminals, and
a way for an agent to show a file range in the editor.

- `init.lua` is the public entry point and the review engine. It renders the
  proposed file in place of an editor window, with removed lines as
  `DiffDelete` virtual lines, and hooks into each agent plugin:
  `setup_claude()` replaces `claudecode.diff` functions, `setup_opencode()`
  listens to the `OpencodeEvent:permission.*` autocmds and answers through
  `opencode.server`, and `setup_antigravity()` replaces
  `antigravity-cli.diff`. `setup_terminal()`, `open_location()`,
  `setup_open_location()` and `open_location_instructions()` only forward to
  `terminal.lua` and `location.lua`.
- `windows.lua` decides which window a file should appear in:
  `find_editor_window()` prefers a window already showing the file, then the
  current or nearest window that is not a terminal, float or sidebar.
  `init.lua` uses it to place reviews and `location.lua` to place ranges.
- `paths.lua` holds `canonical_path()`, the absolute, symlink-resolved form
  used to compare file names. `init.lua`, `windows.lua` and `location.lua`
  all compare paths through it.
- `terminal.lua` owns terminal focus behaviour. It creates the
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
