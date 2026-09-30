# lua/ai_inline_diff

The Lua module that Neovim loads for `require("ai_inline_diff")`. It gives the
user's configuration two things: an inline review that intercepts edits from
the agent plugins (claudecode.nvim, opencode.nvim, antigravity-cli.nvim), and
terminal helpers that make it quick to move between the editor and those
agents' terminals.

- `init.lua` is the public entry point and the review engine. It renders the
  proposed file in place of an editor window, with removed lines as
  `DiffDelete` virtual lines, and hooks into each agent plugin:
  `setup_claude()` replaces `claudecode.diff` functions, `setup_opencode()`
  listens to the `OpencodeEvent:permission.*` autocmds and answers through
  `opencode.server`, and `setup_antigravity()` replaces
  `antigravity-cli.diff`. `setup_terminal()` only forwards to `terminal.lua`.
- `terminal.lua` owns terminal focus behaviour. It creates the
  `AiInlineDiffTerminalInsert` autocmd group that enters terminal mode on
  focus, and the terminal-mode maps for `<C-w>` and `<C-h/j/k/l>`. It talks
  only to Neovim's API and does not know about any agent plugin, so it works
  for every terminal. `init.lua` is its only caller;
  `../../tests/terminal_test.lua` exercises it.

Flow: the user config calls `setup_*()` on `init.lua` after each agent plugin
is set up. From then on, edits reach `open_review()` through the adapter for
that agent, and terminal focus changes go through the autocmd in
`terminal.lua`.
