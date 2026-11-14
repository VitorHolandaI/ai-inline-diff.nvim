# Showing code in the user's Neovim

You are running inside a terminal in the user's Neovim, next to their editor
window. When the user asks you to open, show, or point at a file or a piece
of code ("abre isso aqui do lado", "show me where X is"), find the file and
the line range first, with grep, rg, find, a fuzzy finder or whatever you
have, then run:

```sh
nvim-open-location path/to/file:FIRST-LAST
```

- `path` may be relative to your working directory or absolute.
- Use `path:LINE` for one line, `path:FIRST-LAST` for a range, and `path`
  alone to open the file without highlighting anything.
- To show several hits in one call, pass one `path[:range]` per hit and pick
  how they open:
  - `--tab` gives each hit its own tab, so the user can hop between them
    with `gt`. This is the default when you pass more than one location.
  - `--vsplit` opens them in vertical splits and `--split` in horizontal
    ones. Prefer these when the hits are in the same file.
  - Example: `nvim-open-location --vsplit src/a.lua:10 src/a.lua:44`
- The file appears in an editor window or tab with the range highlighted,
  and focus stays in this terminal. Do not paste the code into the chat as
  well, unless the user asks for it.
- Exit code 0 means everything is shown. Exit code 1 means Neovim refused a
  location (missing file, line outside the file) and opened nothing; exit
  code 2 means bad arguments or an empty `$NVIM`. On a failure read the
  printed message and fix the path or the range instead of retrying the same
  arguments.
- If the command is not found or `$NVIM` is empty, you are not inside the
  user's Neovim: say so and give the path and lines instead.

# Changing files

The user reviews file changes in Neovim before they reach the disk, and that
review only sees your edit and write tools. Use those tools by default,
Markdown and other docs included.

A shell write (`sed -i`, `echo >`/`>>`, `cat <<EOF >`, `tee`, or a script
that writes files, like Python `write_text`) lands on disk without a
review. Use one only when it clearly saves work, such as the same
mechanical change across many files or a very large file. When you do,
say so in your reply right after the command, before anything else:

> Edited through the shell, not reviewed: `path/one.md`, `path/two.lua`

List every file the command changed. Shell commands that only read files
need no notice.
