-- Buffer-local settings for issuehub:// buffers.
-- Nothing global is touched, and no keys are mapped for the user.

local buf = vim.api.nvim_get_current_buf()

vim.bo.commentstring = "<!-- %s -->"
vim.wo[0][0].wrap = true
vim.wo[0][0].linebreak = true

-- The buffer is Markdown, but its filetype stays `issuehub` on purpose: adopting
-- `markdown` would pull in the user's whole Markdown setup (conceal, render
-- plugins, LSP) onto a mostly read-only buffer, against §1.2. So highlight it
-- ourselves — the Tree-sitter Markdown parser when it is installed, the legacy
-- syntax file otherwise — and keep issuehub's own extmark highlights on top.
local has_ts_markdown = pcall(vim.treesitter.start, buf, "markdown")
if not has_ts_markdown then
  -- No parser: fall back to regex syntax. Setting `syntax` (not `filetype`)
  -- loads syntax/markdown.vim without triggering the markdown ftplugin.
  --
  -- Deferred, because `:syntax on` installs its own FileType handler that sets
  -- `syntax` to match the filetype (`issuehub`, which has no syntax file) in
  -- this same event — setting it inline here loses that race. A scheduled write
  -- lands after the sync and sticks.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].syntax = "markdown"
    end
  end)
end

-- Markdown headings drive folding, which is how "## Comments" collapses without
-- issuehub implementing any folding of its own (§1.2). Tree-sitter's foldexpr
-- only works when the parser above actually started; without it, fall back to a
-- heading-based marker so folding still works on the legacy path.
if has_ts_markdown then
  vim.wo[0][0].foldmethod = "expr"
  vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
else
  vim.wo[0][0].foldmethod = "expr"
  vim.wo[0][0].foldexpr = "getline(v:lnum)=~'^#'?'>'..(len(matchstr(getline(v:lnum),'^#*'))):'='"
end
vim.wo[0][0].foldlevel = 99

vim.keymap.set("n", "gx", function()
  local url = vim.b.issuehub_url
  if url then
    vim.ui.open(url)
  end
end, { buffer = true, desc = "issuehub: open in browser" })
