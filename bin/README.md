# bin

Executables that agents run from a terminal inside Neovim.
`require("ai_inline_diff").setup_open_location()` prepends this folder to
`$PATH`, so terminals opened afterwards can call them by name.

- `nvim-open-location` takes `path[:first[-last]]`, resolves a relative path
  against its own working directory, and calls
  `ai_inline_diff.location.open_for_remote()` in the parent Neovim through
  `nvim --server "$NVIM" --remote-expr`. It prints Neovim's answer and exits
  0 when the range is shown, 1 when Neovim refused it, and 2 on bad
  arguments or an empty `$NVIM`. Agents learn about it from
  `../instructions/open-location.md`; `../tests/location_test.lua` covers it.
