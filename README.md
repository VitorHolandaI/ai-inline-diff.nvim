# ai-inline-diff.nvim

Single-window inline review for edits proposed by Claude Code, OpenCode, and Antigravity.

The plugin renders removed lines with `DiffDelete` virtual lines and proposed
lines with `DiffAdd`. Claude and Antigravity proposals remain editable; OpenCode proposals are
read-only because its permission API accepts or rejects the original patch.

## Requirements

This plugin does not talk to the AI tools directly. It hooks into the Neovim
plugin of each tool, so install at least one of them:

| Tool        | Required plugin                                                                   | Setup call                |
| ----------- | --------------------------------------------------------------------------------- | ------------------------- |
| Claude Code | [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)                 | `setup_claude()`          |
| OpenCode    | [nickjvandyke/opencode.nvim](https://github.com/nickjvandyke/opencode.nvim)       | `setup_opencode()`        |
| Antigravity | [McEazy2700/antigravity-cli.nvim](https://github.com/McEazy2700/antigravity-cli.nvim) | `setup_antigravity()` |

## Installation (lazy.nvim)

```lua
{
  "VitorHolandaI/ai-inline-diff.nvim",
  lazy = false,
  dependencies = {
    -- keep only the integrations you use
    "coder/claudecode.nvim",
    "nickjvandyke/opencode.nvim",
    "McEazy2700/antigravity-cli.nvim",
  },
}
```

Call the setup functions after the corresponding plugin is configured.

After configuring `coder/claudecode.nvim`:

```lua
require("ai_inline_diff").setup_claude()
```

After configuring `McEazy2700/antigravity-cli.nvim`:

```lua
require("ai_inline_diff").setup_antigravity()
```

After configuring `nickjvandyke/opencode.nvim`:

```lua
require("ai_inline_diff").setup_opencode()
```

OpenCode must run with edit permissions set to `ask`:

```lua
env = {
  OPENCODE_CONFIG_CONTENT = '{"permission":{"edit":"ask"}}',
}
```

## Review mappings

- `da` or `<leader>aa`: accept.
- `dr`, `q`, or `<leader>ad`: reject.
- `[c` and `]c`: navigate changes.
- `:write`: accept.

Run `:help ai` for usage, safety guarantees, and troubleshooting.
