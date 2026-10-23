-- clingo.nvim — filetype detection, parser lookup and LSP autostart for
-- Clingo/ASP files. The server itself lives in lua/clingo_lsp.lua.
if vim.g.loaded_clingo_nvim == 1 then
  return
end
vim.g.loaded_clingo_nvim = 1

vim.filetype.add({
  extension = {
    lp = "clingo",
    clingo = "clingo",
  },
})

-- The parser can come from the runtimepath (a plugin, nvim-treesitter, or a
-- Nix-managed profile) or from stdpath("data")/site/parser/clingo.so, which is
-- where home-manager places it when built with tree-sitter.buildGrammar.
local function ensure_parser()
  if pcall(vim.treesitter.language.add, "clingo") then
    return true
  end
  local path = vim.fn.stdpath("data") .. "/site/parser/clingo.so"
  if vim.uv.fs_stat(path) then
    return pcall(vim.treesitter.language.add, "clingo", { path = path })
  end
  return false
end

if vim.g.clingo_nvim_autostart ~= 0 then
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "clingo",
    group = vim.api.nvim_create_augroup("clingo.nvim", { clear = true }),
    callback = function(args)
      ensure_parser()
      require("clingo_lsp").setup(args.buf)
    end,
  })
end
