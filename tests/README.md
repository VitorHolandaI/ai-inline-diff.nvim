# tests

Standalone scripts for the plugin, run with Neovim's Lua interpreter and no
external test framework. Each exits with code 1 on any failed check.
`scenarios_test.lua` and `claude_adapter_test.lua` also need git and network
access the first time, to clone the pinned agent plugins into `.deps/`.

- `helpers/embedded_nvim.lua` starts a child `nvim --embed --clean` with the
  plugin on `runtimepath` and drives it over RPC (`EmbeddedNvim`), and
  collects results (`CheckRecorder`). Terminal mode and window focus cannot
  be driven with `feedkeys` in one headless instance, so every test that
  types keys goes through `EmbeddedNvim`. `patch_test.lua` only needs
  `CheckRecorder`.
- `terminal_test.lua` checks `../lua/ai_inline_diff/terminal.lua` through
  `setup_terminal()`: terminal mode on focus, leaving with `<C-w>h` and
  `<C-h>`, and option validation.
- `location_test.lua` checks `../lua/ai_inline_diff/location.lua` through
  `open_location()`, and `../bin/nvim-open-location` as an agent would run
  it: from another cwd, with `$NVIM` pointing at the child. It also checks
  that `../instructions/open-location.md` keeps telling agents to prefer
  their edit tools and to announce any file they change through the shell,
  since a shell write skips the review.
- `review_test.lua` checks what a review looks like and how it ends, through
  `setup_antigravity()` with `FakeAntigravityDiff` standing in for
  `antigravity-cli.diff` and recording the replies sent to the agent. It
  covers the first change selected on open
  (`../lua/ai_inline_diff/review_selection.lua`), `]c`/`[c`, and `<M-n>`,
  `<M-p>`, `<M-a>`, `<M-r>` and `da` from each mode
  (`../lua/ai_inline_diff/review_keys.lua`).
- `scenarios_test.lua` replays each folder in `scenarios/` (see
  `scenarios/README.md`) in its own child Neovim and compares what the agent
  would write with the scenario's `expected.*`. Pass a folder name to run
  only that one. `reply = "pending"` means no answer may be sent, as for an
  OpenCode 2.x edit over several files. It goes through two helpers:
  - `helpers/agent_plugins.lua` pins claudecode.nvim and
    antigravity-cli.nvim to the commits in the main README's "Versions in
    use" and clones them into `.deps/` (git-ignored) on the first run.
  - `helpers/agent_doubles.lua` runs inside the child and plays the agent
    process: it calls `claudecode.diff.open_diff_blocking()` in a coroutine
    as Claude Code's `openDiff` would, replaces
    `antigravity-cli.server.notify` to record Antigravity's replies, and
    fires `OpencodeEvent:permission.asked` with `FakeOpencodeServer`
    standing in for `opencode.server`. Scenarios with agent `opencode-v2`
    send the OpenCode 2.x event shape instead, and `FakeOpencodeV2Server`
    only counts a reply made as `permit(sessionID, id, choice)`. Like the
    real 2.x daemon, it is reachable only as `opencode.server.connected`;
    `new(url)` fails with 401. `outcome()` reports what the agent
    would receive.
- `opencode_event_test.lua` calls `../lua/ai_inline_diff/opencode_event.lua`
  directly with 1.x and 2.x events: edits, other permissions, 2.x edits
  without a diff or over two files, replies, the `permit()` arguments for
  each version, and `with_server()` choosing the connected server.
- `save_wait_test.lua` checks `../lua/ai_inline_diff/save_wait.lua`: a
  clean buffer runs at once, an unsaved one waits with a winbar notice,
  and `:w`, `:e!` or a wipe run it exactly once and restore the winbar,
  while a cancelled wait never runs.
- `live_changes_test.lua` checks `../lua/ai_inline_diff/live_changes.lua`:
  a file written on disk reloads and gets marked, a second write replaces
  the marks, Insert mode or an edit clears them, unsaved user text is never
  replaced, the user's own `:w` is not marked, and a temp-file-and-rename
  write is still seen.
- `patch_test.lua` calls `apply_unified_patch()` directly with hunk headers
  at the edge of what the parser takes: omitted counts, leading zeros,
  numbers so large that `tonumber()` returns `1e+26` or `inf`, non-ASCII
  digits, and the `Index:` / `====` header that OpenCode 2.x's jsdiff
  writes. Each must give the right text or a clean `(nil, message)` within
  100 ms.
- `claude_adapter_test.lua` loads the pinned claudecode.nvim and checks how
  `setup_claude()` answers through `_G.claude_deferred_responses`, the
  table claudecode.nvim fills while Claude waits on `openDiff`: the stored
  sender gets FILE_SAVED or DIFF_REJECTED once and is removed, an error in
  the waiting coroutine reaches it as a JSON-RPC error, and a missing table
  changes nothing.
- `deprecated_api_test.lua` wraps `vim.diff()` and `vim.keymap.set()` in a
  child, drives a review, the per-change keys and `open_location()`, and
  fails if a plugin file calls `vim.diff()` or passes `buffer =` to a
  keymap.
- `lint.lua` is not a `*_test.lua` file, so `coverage.lua` does not run it.
  It runs lua-language-server on `../lua/` with a config written per run
  (Neovim's type stubs live in `$VIMRUNTIME`), stylua with
  `../stylua.toml` and `../.styluaignore`, and shellcheck on
  `../bin/nvim-open-location`, and fails on any finding or missing tool.
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
nvim -l tests/scenarios_test.lua
nvim -l tests/patch_test.lua
nvim -l tests/claude_adapter_test.lua
nvim -l tests/deprecated_api_test.lua
nvim -l tests/opencode_event_test.lua
nvim -l tests/save_wait_test.lua
nvim -l tests/live_changes_test.lua
nvim -l tests/lint.lua
nvim -l tests/coverage.lua --missing
```
