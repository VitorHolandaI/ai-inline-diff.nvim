# tests

Standalone scripts for the plugin, run with Neovim's Lua interpreter and no
external test framework. Each exits with code 1 on any failed check.

- `helpers/embedded_nvim.lua` starts a child `nvim --embed --clean` with the
  plugin on `runtimepath` and drives it over RPC (`EmbeddedNvim`), and
  collects results (`CheckRecorder`). Terminal mode and window focus cannot
  be driven with `feedkeys` in one headless instance, which is why both test
  files go through it.
- `terminal_test.lua` checks `../lua/ai_inline_diff/terminal.lua` through
  `setup_terminal()`: terminal mode on focus, leaving with `<C-w>h` and
  `<C-h>`, and option validation.
- `location_test.lua` checks `../lua/ai_inline_diff/location.lua` through
  `open_location()`, and `../bin/nvim-open-location` as an agent would run
  it: from another cwd, with `$NVIM` pointing at the child.

Run from the repository root:

```sh
nvim -l tests/terminal_test.lua
nvim -l tests/location_test.lua
```
