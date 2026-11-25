# bin

Executables that agents run from a terminal inside Neovim.
`require("ai_inline_diff").setup_open_location()` prepends this folder to
`$PATH`, so terminals opened afterwards can call them by name.
`agy-review-hook.lua` is run by agy itself, from its `hooks.json`, so it
needs no `$PATH` entry.

- `nvim-open-location` takes `[--tab|--vsplit|--split] path[:first[-last]] ...`,
  resolves a relative path against its own working directory, and calls
  `ai_inline_diff.location.open_for_remote()` in the parent Neovim through
  `nvim --server "$NVIM" --remote-expr` with the whole request as one payload
  (`layout` plus a list of paths and ranges). It prints Neovim's answer and
  exits 0 when everything is shown, 1 when Neovim refused a location, and 2 on
  bad arguments or an empty `$NVIM`. A bare `path` has no range, so Neovim
  opens the file without highlighting. One location uses the `smart` layout;
  several default to `tab`, one tab each, and `--vsplit`/`--split` put them in
  splits instead. Agents learn about it from
  `../instructions/open-location.md`; `../tests/location_test.lua` covers it.
- `agy-review-hook.lua` is Antigravity's `PreToolUse` hook, run as
  `nvim -l bin/agy-review-hook.lua` from `~/.gemini/antigravity-cli/hooks.json`
  with the tool call as JSON on stdin. It connects to `$NVIM` with
  `sockconnect()`, hands the raw payload to
  `ai_inline_diff.antigravity_hook_start()` and polls
  `antigravity_hook_poll()` every 200 ms until the review ends
  (`../lua/ai_inline_diff/agy_hook.lua` does the work). It prints agy's
  decision on stdout: `allow`, `allow` with `overwrite` for an edited
  review, or `deny`. agy blocks the edit when a hook prints nothing or
  crashes, so it always prints one: `allow` when `$NVIM` is empty or the
  plugin is not loaded there, and `deny` with the error once a review may
  be on screen. `../tests/agy_hook_test.lua` covers it.
