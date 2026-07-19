-- Buffer-local settings for issuehub:// buffers.
-- Nothing global is touched, and no keys are mapped for the user.

vim.bo.commentstring = "<!-- %s -->"
vim.wo[0][0].wrap = true
vim.wo[0][0].linebreak = true

-- Markdown headings drive folding, which is how "## Comments" collapses without
-- issuehub implementing any folding of its own (§1.2).
vim.wo[0][0].foldmethod = "expr"
vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.wo[0][0].foldlevel = 99

vim.keymap.set("n", "gx", function()
  local url = vim.b.issuehub_url
  if url then
    vim.ui.open(url)
  end
end, { buffer = true, desc = "issuehub: open in browser" })
