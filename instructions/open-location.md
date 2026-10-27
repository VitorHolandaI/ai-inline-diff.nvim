# Showing code in the user's Neovim

You are running inside a terminal in the user's Neovim, next to their editor
window. When the user asks you to open, show, or point at a file or a piece
of code ("abre isso aqui do lado", "show me where X is"), find the file and
the line range first, then run:

```sh
nvim-open-location path/to/file:FIRST-LAST
```

- `path` may be relative to your working directory or absolute.
- Use `path:LINE` for a single line.
- The file appears in the editor window with the range highlighted, and focus
  stays in this terminal. Do not paste the code into the chat as well, unless
  the user asks for it.
- Exit code 0 means the file is shown. On exit code 1 or 2, read the printed
  message and fix the path or range; do not retry the same arguments.
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
