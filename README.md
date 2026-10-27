# ai-inline-diff.nvim

Review edits from Claude Code, OpenCode, and Antigravity inside the window you
are already editing in, instead of a side-by-side diff or a new tab.

This is a personal plugin, built for one workflow: Claude Code, OpenCode and
Antigravity running in terminals inside Neovim, on the versions listed under
[Versions in use](#versions-in-use). It is public in case it helps someone
with a similar setup. Keys, behavior and supported versions change whenever
that workflow does, and other setups are not tested.

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
      require("ai_inline_diff").setup_live_changes()
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

### Agent permission modes

A review only opens when the agent asks before it edits. In any mode that
edits without asking, the change goes straight to disk and nothing shows up
in Neovim.

#### Claude Code: `default` mode

Run Claude Code in `default` mode (`⏸ manual mode on` in the status bar).
`acceptEdits` and `auto` write edits without asking, `bypassPermissions`
skips every prompt, and `plan` makes no edits at all. Claude Code starts in
`auto`, so set the default in `~/.claude/settings.json`:

```json
{
  "permissions": { "defaultMode": "default" }
}
```

`Shift+Tab` cycles the modes during a session. From `auto`, the first press
switches to `default`.

#### OpenCode: `edit` set to `ask`, and no saved "Always allow"

OpenCode 2.x runs one background server for every client and reads its
configuration when that server starts, so an environment variable set on the
terminal inside Neovim only applies if that terminal happens to start the
server. Put the setting in `~/.config/opencode/opencode.jsonc` instead:

```jsonc
{
  "permission": { "edit": "ask" }
}
```

OpenCode outside Neovim then asks too, in its own interface.

Answering "Always allow" to an edit request saves an `edit *` rule for the
whole project, and the rule outlives the session. From then on OpenCode
edits every file in that project without asking. OpenCode's database holds
the saved rules, one per project, and its API removes one by id:

```sh
sqlite3 ~/.local/share/opencode/opencode.db \
  "select p.id, pr.worktree from permission p join project pr on pr.id = p.project_id"
opencode api DELETE /api/permission/saved/<id>
```

`opencode api GET /api/permission/saved` only lists the rules of one
project, and not always the one you ran it from, so read the ids from the
database.

#### Both agents: edit tools first, and a notice for shell edits

Setting the permission modes is not enough. An agent can also change a file
by running a shell command: `sed -i`, `echo >> file`, `cat <<EOF > file`,
`tee`, or a Python script that calls `write_text()`. That command goes
through the agent's shell permission, not its edit permission, so Neovim
never gets a review. The change is already on disk when you see it.

Agents do this most with Markdown and other docs. Over three days of real
use, OpenCode changed every `.md` file through the shell and never with its
edit tools. Asked to write "hello world" at the top of a notes file, Claude
Code ran `sed -i '1i hello world' anotacao.md`.

Forbidding the shell outright would cost tokens: the same mechanical change
across many files is one `sed` command but dozens of edit calls. So both
agents load [`instructions/open-location.md`](instructions/open-location.md),
whose "Changing files" section asks for two things:

1. Use the edit and write tools by default, Markdown included.
2. Use a shell write only when it clearly saves work, and then say so in the
   reply right after the command, naming every file it changed:

   > Edited through the shell, not reviewed: `path/one.md`, `path/two.lua`

That line tells you which files to check yourself. If those files are open
in Neovim, [`setup_live_changes()`](#edits-written-without-a-review) also
marks the changed lines. Shell commands that only read files need no
notice.

- **Claude Code** reads it through `--append-system-prompt-file`, set in the
  claudecode.nvim config (see [Setup](#setup)). It applies to Claude
  sessions started after the change. Sessions already open keep the old
  prompt.
- **OpenCode** reads it from the `instructions` list in
  `~/.config/opencode/opencode.jsonc`:

  ```jsonc
  {
    "permission": { "edit": "ask" },
    "instructions": ["/path/to/ai-inline-diff.nvim/instructions/open-location.md"]
  }
  ```

  Run `opencode service restart` after adding it. The shared background
  server reads its configuration only when it starts.

This is an instruction to the model, not a lock, so a model can still skip
the notice. To check, look at the tool the agent ran: an edit tool means a
review opened, while `Bash`/`shell` running `sed -i` or a script means the
file was written without one. See
[What gets reviewed](#what-gets-reviewed).

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
   the `instructions` list in its global config. The file tells the agent to
   run the script when you ask to see code, and what to do when the script
   fails. It also tells the agent to change files with its edit tools, and
   to name any file it changes through the shell instead, since those
   changes skip the review.
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
-- ~/.config/opencode/opencode.jsonc (see Agent permission modes above):
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
cursor goes to where the lines were and you stay in Normal mode. A
notification lists the keys that work for that agent and stays up for a
minute, or until the review ends. With snacks.nvim's notifier there is only
ever one: a new review replaces the box instead of stacking another, and
accepting or rejecting closes it.

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

`<M-a>` is Vim's notation for Alt-a, and the same goes for the other `<M-…>`
keys; the in-editor hint spells them as `Alt-a`.

`<M-a>` and `<M-r>` cover the whole edit, even when only one change is
selected. To decide change by change, use `<M-y>` to keep the selected
change and `<M-x>` to put its original lines back. Either one moves the
selection to the next undecided change, and the review ends by itself after
the last one: it is accepted with the changes you kept, or rejected if you
dropped them all. `<M-a>` in the middle accepts what is left as proposed.
Kept changes show a `✓` sign. OpenCode takes or refuses its patch as a
whole, so in an OpenCode review `<M-y>` and `<M-x>` only show a warning.
When the review ends you are in Normal mode in the original buffer.

### Files with unsaved changes

When the agent wants to edit a file you have open with unsaved changes, the
review waits instead of throwing your typing away. The window showing the
file gets a notice, `AI edit waiting: save with :w to review it, or :e! to
discard your changes`, and the review opens on its own once you save,
discard with `:e!`, or undo back to the saved text. Answering the agent in
its own terminal stops the wait.

The review then compares what is on disk with what the agent will write.
Claude Code and OpenCode write the content they prepared when they asked,
so anything you saved in the meantime, including changes made by a
format-on-save hook, shows up as lines the edit would revert.

### Edits written without a review

When an agent writes a file without asking, as OpenCode does after "Always
allow" or Claude Code in `auto` or `acceptEdits` mode, there is no review
to show. `setup_live_changes()` watches the files open in Neovim instead:
when one changes on disk and its buffer has no unsaved changes, the buffer
reloads at once and the changed lines are marked the same way a review marks
them.
The marks stay until you enter Insert mode or change the text, or until the
agent writes again. `u` undoes the agent's change. A buffer with unsaved
changes is left alone.

Each such write also leaves a message that outlasts the marks:

```text
Agent changed docs/notes.md without a review: +2 -1 lines
```

It goes through `vim.notify`, so it shows in the notification history
(`:messages`, or your notifier's history: `<leader>n` in LazyVim). The
write an agent makes right after you accept its review is not announced,
since you already saw it.

OpenCode 2.x does not tell opencode.nvim when it writes a file (its file
watcher only follows `.git/HEAD`), so without this the buffer only reloads
when Neovim checks the disk, for example when you leave the agent's
terminal.

### What gets reviewed

The plugin only sees edits that the agent sends to Neovim for approval.
With Claude Code that is an `openDiff` request, with OpenCode an `edit`
permission request, and with Antigravity a diff it opens. An edit the agent
makes by running a shell command, such as `sed -i` or `echo >> file`, goes
straight to disk and never shows up as a review. Neovim's `'autoread'`, on
by default, reloads the buffer once it notices the change. The instruction
file asks agents to prefer their edit tools and to name any file they change
through the shell. Models usually follow it, but it is an instruction, not a
guarantee.

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
nvim -l tests/save_wait_test.lua
nvim -l tests/live_changes_test.lua
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
