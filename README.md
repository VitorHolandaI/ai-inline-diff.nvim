# ai-inline-diff.nvim

Review edits from Claude Code, OpenCode, and Antigravity inside the window you
are already editing in, instead of a side-by-side diff or a new tab.

Removed lines show up as `DiffDelete` virtual lines and proposed lines are
highlighted with `DiffAdd`. You can edit Claude and Antigravity proposals
before accepting them. OpenCode proposals are read-only, because OpenCode's
permission API only accepts or rejects the original patch.

## Requirements

You need Neovim 0.12 or newer. That release renamed `vim.diff()` to
`vim.text.diff()` and the `buffer` option of `vim.keymap.set()` to `buf`,
and the plugin uses the new names.

You also need the Neovim plugin for each agent you use. This plugin never
talks to the agents directly; it hooks into their plugins.

| Agent       | Plugin                                                                                  | Setup call            |
| ----------- | --------------------------------------------------------------------------------------- | --------------------- |
| Claude Code | [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim)                       | `setup_claude()`      |
| OpenCode    | [nickjvandyke/opencode.nvim](https://github.com/nickjvandyke/opencode.nvim)             | `setup_opencode()`    |
| Antigravity | [McEazy2700/antigravity-cli.nvim](https://github.com/McEazy2700/antigravity-cli.nvim)   | `setup_antigravity()` |

### Versions in use

The plugin replaces internal functions of the agent plugins and listens to
their events, so a new release of any of them can break it. It is developed
and used with these versions:

| Component            | Version                          |
| -------------------- | -------------------------------- |
| Neovim               | 0.12.5                           |
| Claude Code CLI      | 2.1.282                          |
| claudecode.nvim      | `main` at `2390c6e` (v0.3.0+53)  |
| OpenCode CLI         | 2.1.4                            |
| opencode.nvim        | `main` at `e7643e9`              |
| Antigravity CLI      | `agy` 1.2.14                     |
| antigravity-cli.nvim | `main` at `43d0d38`              |

OpenCode 2.x needs opencode.nvim's `main` branch, which has no release yet,
so the spec below pins a commit. The plugin also still reads OpenCode 1.x
events; for 1.x, use opencode.nvim v1.0.2 (`version = "*"`) instead.

The automated tests in `tests/` load the pinned agent plugins but never
start an agent, so the agent CLI versions above come from daily use.

## Installation

### lazy.nvim

Add this to your plugin specs and keep only the agents you use. Each
`setup_*()` call goes in the agent plugin's own `config`, after that plugin's
`setup()`.

`version = "*"` installs the latest release of this plugin. The `commit` and
`tag` lines pin each agent plugin to the version in
[Versions in use](#versions-in-use). Drop them to follow the agent plugins'
latest code at your own risk.

```lua
return {
  {
    "VitorHolandaI/ai-inline-diff.nvim",
    version = "*",
    lazy = false,
    config = function()
      require("ai_inline_diff").setup_terminal()
    end,
  },
  {
    "coder/claudecode.nvim",
    commit = "2390c6e45c4789072c293ac69de051d169668b29",
    dependencies = { "folke/snacks.nvim", "VitorHolandaI/ai-inline-diff.nvim" },
    config = function(_, opts)
      require("claudecode").setup(opts)
      require("ai_inline_diff").setup_claude()
    end,
  },
  {
    "nickjvandyke/opencode.nvim",
    commit = "e7643e9efc878876bb9c68da6cf30c45d6c34e5a",
    dependencies = { "folke/snacks.nvim", "VitorHolandaI/ai-inline-diff.nvim" },
    config = function()
      require("ai_inline_diff").setup_opencode()
    end,
  },
  {
    "McEazy2700/antigravity-cli.nvim",
    commit = "43d0d38c325ec45da1f6591f1e5534fad9a0fc40",
    dependencies = { "folke/snacks.nvim", "VitorHolandaI/ai-inline-diff.nvim" },
    config = function(_, opts)
      require("antigravity-cli").setup(opts)
      require("ai_inline_diff").setup_antigravity()
    end,
  },
}
```

### vim.pack

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
review them. OpenCode 2.x runs one background server for every client and
reads its configuration when that server starts, so an environment variable
set on the terminal inside Neovim only applies if that terminal happens to
start the server. Put the setting in `~/.config/opencode/opencode.jsonc`
instead:

```jsonc
{
  "permission": { "edit": "ask" }
}
```

OpenCode outside Neovim then asks too, in its own interface.

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
   the `instructions` list in its global config. The file tells the agent to run the
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

-- Claude Code only. For OpenCode, add the file to
-- ~/.config/opencode/opencode.jsonc (see OpenCode permissions above):
--   "instructions": ["/path/to/ai-inline-diff.nvim/instructions/open-location.md"]
```

`:lua print(require("ai_inline_diff").open_location_instructions())` prints
that path.

You can also call it from Lua:
`require("ai_inline_diff").open_location(path, first, last)`.

## Reviewing an edit

When a review opens, the editor window takes focus and the first change is
selected in linewise Visual mode, showing which lines the agent wants to
write. A change that only removes lines has nothing to select, so the
cursor goes to where the lines were and you stay in Normal mode.

| Keys                    | Modes                  | Action                             |
| ----------------------- | ---------------------- | ---------------------------------- |
| `<M-a>`                 | Normal, Visual, Insert | accept the edit                    |
| `<M-r>`                 | Normal, Visual, Insert | reject the edit                    |
| `<M-y>`                 | Normal, Visual, Insert | keep the selected change           |
| `<M-x>`                 | Normal, Visual, Insert | drop the selected change           |
| `da`, `<leader>aa`      | Normal, Visual         | accept the edit                    |
| `dr`, `q`, `<leader>ad` | Normal, Visual         | reject the edit                    |
| `<M-n>`, `<M-p>`        | Normal, Visual, Insert | select the next or previous change |
| `]c`, `[c`              | Normal, Visual         | select the next or previous change |
| `:write`                | Normal                 | accept the edit                    |

`<M-a>` and `<M-r>` cover the whole edit, even when only one change is
selected. To decide change by change, use `<M-y>` to keep the selected
change and `<M-x>` to put its original lines back. Either one moves the
selection to the next undecided change, and the review ends by itself after
the last one: it is accepted with the changes you kept, or rejected if you
dropped them all. `<M-a>` in the middle accepts what is left as proposed.
Kept changes show a `✓` sign. OpenCode takes or refuses its patch as a
whole, so in an OpenCode review `<M-y>` and `<M-x>` only show a warning.
When the review ends you are in Normal mode in the original buffer.

### What gets reviewed

The plugin only sees edits that the agent sends to Neovim for approval.
With Claude Code that is an `openDiff` request, with OpenCode an `edit`
permission request, and with Antigravity a diff it opens. An edit the agent
makes by running a shell command, such as `sed -i` or `echo >> file`, goes
straight to disk and never shows up as a review. Neovim's `'autoread'`, on
by default, reloads the buffer once it notices the change.

[`docs/how-an-edit-flows.md`](docs/how-an-edit-flows.md) follows one edit
from the agent to the file on disk, with the code that runs at each step.

`:help ai` covers usage, safety checks, and troubleshooting.

## Tests

```sh
nvim -l tests/terminal_test.lua
nvim -l tests/location_test.lua
nvim -l tests/review_test.lua
nvim -l tests/scenarios_test.lua
nvim -l tests/patch_test.lua
nvim -l tests/claude_adapter_test.lua
nvim -l tests/deprecated_api_test.lua
nvim -l tests/opencode_event_test.lua
```

`scenarios_test.lua` replays each folder in `tests/scenarios/`. A simulated
agent proposes an edit, the scenario's keys are typed into the review, and
what the agent would write must match `expected.*` byte for byte. Claude
and Antigravity edits go through the real claudecode.nvim and
antigravity-cli.nvim, cloned at the pinned versions into `tests/.deps/` on
the first run. OpenCode edits arrive as its permission event.
[`tests/scenarios/README.md`](tests/scenarios/README.md) explains how to add
a scenario.

`nvim -l tests/lint.lua` runs lua-language-server, stylua and shellcheck and
fails on any finding. It takes each tool from `$PATH` or from Mason.

`nvim -l tests/coverage.lua` runs all of them and prints line coverage for
each file in `lua/ai_inline_diff/`. Add `--missing` to list the lines that
never ran.
