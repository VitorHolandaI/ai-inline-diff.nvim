# tests

Standalone scripts for the plugin, run with Neovim's Lua interpreter and no
external test framework.

- `terminal_test.lua` checks `../lua/ai_inline_diff/terminal.lua` through
  `require("ai_inline_diff").setup_terminal()`. Terminal mode cannot be
  driven with `feedkeys` in one headless instance, so it starts a child
  `nvim --embed --clean` with the plugin on `runtimepath`, sends keys with
  `nvim_input` over RPC, and reads the focused window and mode back. Exit
  code 1 on any failed check.

Run from the repository root: `nvim -l tests/terminal_test.lua`.
