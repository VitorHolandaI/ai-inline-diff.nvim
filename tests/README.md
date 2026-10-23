# tests

Standalone scripts for the plugin, run with Neovim's Lua interpreter and no
external test framework. Each exits with code 1 on any failed check.

- `helpers/embedded_nvim.lua` starts a child `nvim --embed --clean` with the
  plugin on `runtimepath` and drives it over RPC (`EmbeddedNvim`), and
  collects results (`CheckRecorder`). Terminal mode and window focus cannot
  be driven with `feedkeys` in one headless instance, which is why every test
  file goes through it.
- `terminal_test.lua` checks `../lua/ai_inline_diff/terminal.lua` through
  `setup_terminal()`: terminal mode on focus, leaving with `<C-w>h` and
  `<C-h>`, and option validation.
- `location_test.lua` checks `../lua/ai_inline_diff/location.lua` through
  `open_location()`, and `../bin/nvim-open-location` as an agent would run
  it: from another cwd, with `$NVIM` pointing at the child.

- `review_test.lua` checks what a review looks like and how it ends, through
  `setup_antigravity()` with `FakeAntigravityDiff` standing in for
  `antigravity-cli.diff` and recording the replies sent to the agent. It
  covers the first change selected on open (`../lua/ai_inline_diff/review_selection.lua`),
  `]c`/`[c`, and `<M-n>`, `<M-p>`, `<M-a>`, `<M-r>` and `da` from each mode
  (`../lua/ai_inline_diff/review_keys.lua`).

- `coverage.lua` runs every `*_test.lua` with `AI_INLINE_DIFF_COVERAGE_DIR`
  set. `helpers/embedded_nvim.lua` sees the variable and loads
  `helpers/coverage_hook.lua` into each child, which counts the plugin lines
  that run (`debug.sethook`, with the JIT off so no line is skipped) and
  writes them out when the child stops. `coverage.lua` then compiles each
  file in `../lua/ai_inline_diff/` and reads the LuaJIT bytecode through
  `jit.util` to learn which lines are executable, and prints the share that
  ran. `--missing` adds the line ranges that never ran. It needs nothing
  beyond Neovim. The shell script `../bin/nvim-open-location` is exercised
  by `location_test.lua` but not measured.

Run from the repository root:

```sh
nvim -l tests/terminal_test.lua
nvim -l tests/location_test.lua
nvim -l tests/review_test.lua
nvim -l tests/coverage.lua --missing
```
