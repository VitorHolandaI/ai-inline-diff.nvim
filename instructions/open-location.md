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
