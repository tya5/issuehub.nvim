---@brief Highlight groups, linked to standard ones so every colorscheme works.
local M = {}

local GROUPS = {
  IssueHubTitle = "Title",
  IssueHubId = "Identifier",
  IssueHubStatus = "Statement",
  IssueHubStatusClosed = "Comment",
  IssueHubLabel = "Type",
  IssueHubMeta = "Comment",
  IssueHubStale = "WarningMsg",

  -- Section markers. Read-only and editable regions looked identical, which is
  -- a problem when edits to one of them get reverted.
  IssueHubReadOnly = "Comment",
  IssueHubEditable = "Special",
  IssueHubDivider = "Comment",
}

function M.setup()
  for group, link in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

return M
