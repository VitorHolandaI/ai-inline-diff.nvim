# bin

Executables that agents run from a terminal inside Neovim.
`require("ai_inline_diff").setup_open_location()` prepends this folder to
`$PATH`, so terminals opened afterwards can call them by name.

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
