# tests/scenarios

Scripted review sessions for `../scenarios_test.lua`. Each folder is one
session: an agent proposes an edit to a file, someone types keys into the
review, and the folder says what the agent must end up writing. The runner
copies the original into a fresh directory, opens it beside an agent
terminal in a child Neovim, and plays the keys one entry at a time, the way
a macro would.

A folder holds:

- `scenario.lua` returns `{ agent = ..., keys = { ... }, reply = ... }`.
  `agent` is `"claude"`, `"antigravity"` or `"opencode"`; `keys` uses
  `nvim_input()` notation such as `"<M-n>"` or `"ciwfoo<Esc>"`; `reply` is
  `"accepted"` or `"rejected"`.
- `original.<ext>` is the file before the edit. Leave it out to propose a
  new file; the target is then named after `expected.<ext>`.
- `proposed.<ext>` is the full file the agent proposes, for Claude and
  Antigravity. OpenCode sends a patch instead, so its folders hold
  `patch.diff` (a unified diff from `diff -u`, or a `*** Begin Patch`
  block with one `*** Add File:` section).
- `expected.<ext>` is the exact content the agent writes when the reply is
  `"accepted"`. Rejected scenarios have none; the runner checks the file is
  unchanged.

To add a scenario, copy the closest folder, change the files, and run
`nvim -l tests/scenarios_test.lua <folder>`. Write `expected.<ext>` by hand
from what the keys should produce, not from a run, or the test only
confirms whatever the code already does.
