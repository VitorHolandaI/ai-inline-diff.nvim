# ai-inline-diff.nvim

Review edits from Claude Code, OpenCode, and Antigravity inside the window you
are already editing in, instead of a side-by-side diff or a new tab.

Removed lines show up as `DiffDelete` virtual lines and proposed lines are
highlighted with `DiffAdd`. You can edit Claude and Antigravity proposals
before accepting them. OpenCode proposals are read-only, because OpenCode's
permission API only accepts or rejects the original patch.

## Requirements

You need the Neovim plugin for each agent you use. This plugin never talks to
the agents directly; it hooks into their plugins.

| Agent       | Plugin                                                                                  | Setup call            |
| ----------- | --------------------------------------------------------------------------------------- | --------------------- |
| Claude Code | [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)                       | `setup_claude()`      |
| OpenCode    | [nickjvandyke/opencode.nvim](https://github.com/nickjvandyke/opencode.nvim)             | `setup_opencode()`    |
| Antigravity | [McEazy2700/antigravity-cli.nvim](https://github.com/McEazy2700/antigravity-cli.nvim)   | `setup_antigravity()` |

## Installation

### lazy.nvim

Add this to your plugin specs and keep only the agents you use. Each
`setup_*()` call goes in the agent plugin's own `config`, after that plugin's
`setup()`.

```lua
return {
  {
    "VitorHolandaI/ai-inline-diff.nvim",
    lazy = false,
    config = function()
      require("ai_inline_diff").setup_terminal()
    end,
  },
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim", "VitorHolandaI/ai-inline-diff.nvim" },
    config = function(_, opts)
      require("claudecode").setup(opts)
      require("ai_inline_diff").setup_claude()
    end,
  },
  {
    "nickjvandyke/opencode.nvim",
    dependencies = { "folke/snacks.nvim", "VitorHolandaI/ai-inline-diff.nvim" },
    config = function()
      require("ai_inline_diff").setup_opencode()
    end,
  },
  {
    "McEazy2700/antigravity-cli.nvim",
    dependencies = { "folke/snacks.nvim", "VitorHolandaI/ai-inline-diff.nvim" },
    config = function(_, opts)
      require("antigravity-cli").setup(opts)
      require("ai_inline_diff").setup_antigravity()
    end,
  },
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({ "https://github.com/VitorHolandaI/ai-inline-diff.nvim" })
require("ai_inline_diff").setup_terminal()
```

Then call `setup_claude()`, `setup_opencode()`, or `setup_antigravity()` after
you set up the matching agent plugin.

### Without a plugin manager

Clone it into Neovim's package directory and it loads on the next start:

```sh
git clone https://github.com/VitorHolandaI/ai-inline-diff.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/ai-inline-diff.nvim
```

The `setup_*()` calls are the same as above.

### OpenCode permissions

OpenCode has to ask before editing, or its edits land on disk before you can
review them. Start it with:

```lua
env = {
  OPENCODE_CONFIG_CONTENT = '{"permission":{"edit":"ask"}}',
}
```

## Moving between the editor and agent terminals

`setup_terminal()` changes how every terminal window behaves. Focusing a
terminal puts you in terminal mode right away, so you can type without
pressing `i`. From inside a terminal, `<C-w>{cmd}` (for example `<C-w>h` or
`<C-w>w`) and `<C-h/j/k/l>` move to another window.

The agent no longer receives `<C-w>`, so use Alt-Backspace to delete a word.
To keep either behavior off:

```lua
require("ai_inline_diff").setup_terminal({
  auto_insert = false, -- stay in Normal mode when focusing a terminal
  window_keys = false, -- leave <C-w> and <C-h/j/k/l> to the terminal
})
```

## Showing code from the agent

Ask Claude Code or OpenCode to show you something, for example "open the
place where the parser handles comments", and the file appears in your
editor window with those lines highlighted. Focus stays in the agent's
terminal, so you can keep talking while you read.

### How it works

1. At startup, `setup_open_location()` prepends the plugin's `bin/` folder to
   `$PATH`. Terminals opened after that inherit it and can run
   `nvim-open-location` by name. Terminals that were already open cannot.
2. Each agent starts with the instruction file
   [`instructions/open-location.md`](instructions/open-location.md). Claude
   Code reads it through `--append-system-prompt-file` and OpenCode through
   the `instructions` list in its config. The file tells the agent to run the
   script when you ask to see code, and what to do when the script fails.
3. The agent finds the code the way it always does, by reading and searching
   files, and then runs something like:

   ```sh
   nvim-open-location src/parser.lua:40-72
   ```

4. Neovim sets `$NVIM` in every terminal it starts to the address of its own
   server. The script makes the path absolute, because the agent's working
   directory can differ from Neovim's, and asks that server to run
   `open_for_remote()` through `nvim --server $NVIM --remote-expr`.
5. Inside Neovim, `location.lua` loads the file and picks a window. It
   prefers one that already shows the file, then the nearest editor window in
   the current tab. It skips a window with a pending review, because
   replacing that buffer would reject the edit, and opens a split beside the
   terminal when no window fits. The cursor goes to the first line, centered,
   and the range is highlighted. The current window never changes.
6. The script prints Neovim's reply. It exits with 0 when the range is shown,
   1 when Neovim refused it (missing file or a line outside the file) and 2
   on bad arguments or an empty `$NVIM`. On a failure the agent reads the
   message and fixes the path or the range.

The highlight goes away when you enter Insert mode in that buffer or when the
agent shows another range.

### Setup

Put the script on `$PATH` and hand each agent the instructions file:

```lua
require("ai_inline_diff").setup_open_location()

-- claudecode.nvim, inside its config function:
local instructions = require("ai_inline_diff").open_location_instructions()
opts.terminal_cmd = "claude --append-system-prompt-file " .. vim.fn.shellescape(instructions)

-- opencode.nvim, in the snacks terminal env:
OPENCODE_CONFIG_CONTENT = vim.json.encode({
  permission = { edit = "ask" },
  instructions = { require("ai_inline_diff").open_location_instructions() },
}),
```

You can also call it from Lua:
`require("ai_inline_diff").open_location(path, first, last)`.

## Review mappings

- `da` or `<leader>aa` accepts the edit, and so does `:write`.
- `dr`, `q`, or `<leader>ad` rejects it.
- `[c` and `]c` jump between changes.

`:help ai` covers usage, safety checks, and troubleshooting.

## Tests

```sh
nvim -l tests/terminal_test.lua
nvim -l tests/location_test.lua
```
