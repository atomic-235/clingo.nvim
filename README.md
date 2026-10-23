# clingo.nvim

An in-process language server for [Clingo](https://potassco.org/clingo/) / ASP
(`.lp`) in Neovim. No external LSP binary — it runs inside Neovim via
`vim.lsp.start` with a function `cmd`, and uses the tree-sitter Clingo grammar
for structure and the `clingo` binary for real solver diagnostics.

## Features

- **Diagnostics** — parse errors and grounding/solving errors, reported on the
  offending line. Tree-sitter catches structural problems; `clingo --text`
  supplies the rest (undefined atoms, unsafe variables, syntax errors at solve
  time). Debounced, and skipped when `clingo` is not on `PATH`.
- **Completion** — directives (`#show`, `#const`, `#program`, `#theory`, …),
  aggregates (`#count`, `#sum`, `#min`, `#max`, …), and predicates/constants
  collected from the current buffer, with arity-aware insertion.
- **Hover** — arity, defining line and leading comment for the predicate under
  the cursor.
- **Go to definition / references** — jumps between predicate definitions and
  uses in the same buffer.

## Requirements

- Neovim 0.10 or newer (uses `vim.uv` and function `cmd` for `vim.lsp.start`).
- The tree-sitter Clingo grammar, for highlighting and for the parts of the
  server that inspect the syntax tree.

  With Nix, [tree-sitter-clingo-flake](https://github.com/atomic-235/tree-sitter-clingo-flake)
  provides the parser and queries:

  ```nix
  { pkgs, ... }:
  {
    xdg.dataFile = {
      "nvim/site/parser/clingo.so".source = "${pkgs.tree-sitter-clingo}/parser";
      "nvim/site/queries/clingo/highlights.scm".source = "${pkgs.tree-sitter-clingo}/queries/highlights.scm";
      "nvim/site/queries/clingo/injections.scm".source = "${pkgs.tree-sitter-clingo}/queries/injections.scm";
      "nvim/site/queries/clingo/indents.scm".source = "${pkgs.tree-sitter-clingo}/queries/indents.scm";
      "nvim/site/queries/clingo/textobjects.scm".source = "${pkgs.tree-sitter-clingo}/queries/textobjects.scm";
    };
  }
  ```

  Without Nix, build the grammar with the `tree-sitter` CLI and point Neovim at
  it, or register it through your plugin manager.

- `clingo` on `PATH` (optional). Without it the server still completes, hovers
  and navigates; it just cannot report solver diagnostics.

## Install

lazy.nvim:

```lua
{ "atomic-235/clingo.nvim" }
```

The plugin registers the `clingo` filetype for `*.lp` / `*.clingo` and starts
the server on `FileType clingo`. It is deliberately not lazy-loaded: the
filetype is defined by the plugin itself, so it has to run at startup.

## Configuration

Disable automatic server start (the module stays available):

```lua
vim.g.clingo_nvim_autostart = 0
```

You can still start it manually:

```lua
require("clingo_lsp").setup(vim.api.nvim_get_current_buf())
```

## Notes

- The server is single-buffer and project-agnostic: `root_dir` is the nearest
  `.git` directory, falling back to the working directory.
- Diagnostics are debounced; `clingo --text` runs on a temporary copy of the
  buffer, so unsaved files are diagnosed as they are.

## License

Apache-2.0.
