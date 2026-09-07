# ai-inline-diff.nvim

Single-window inline review for edits proposed by Claude Code, OpenCode, and Antigravity.

The plugin renders removed lines with `DiffDelete` virtual lines and proposed
lines with `DiffAdd`. Claude and Antigravity proposals remain editable; OpenCode proposals are
read-only because its permission API accepts or rejects the original patch.

## Local Lazy.nvim setup

```lua
{
  name = "ai-inline-diff.nvim",
  dir = vim.fn.expand("~/tinker_git/ai-inline-diff.nvim"),
  lazy = false,
}
```

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
