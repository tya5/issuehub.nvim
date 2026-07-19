---@brief Analysis viewer.
---
--- A read-only Markdown buffer. No custom viewer: it is plain Markdown so
--- folding, search, and any renderer plugin work (§1.2). Staleness is shown in
--- the header because it is a property of the analysis, not a transient notice.

local analysis = require("issuehub.core.analysis")

local M = {}

---@param uri string
---@param stamp string
---@return string
local function bufname(uri, stamp)
  return ("issuehub://%s/analyses/%s"):format(uri:gsub("://", "/"), stamp)
end

---@param entry issuehub.Analysis
---@return string[]
function M.render(entry)
  local lines = {
    ("# Analysis %s"):format(entry.stamp),
    "",
    ("- Issue:    %s"):format(entry.uri),
    ("- Created:  %s"):format(entry.created_at),
    ("- Backend:  %s%s"):format(entry.backend or "?", entry.model and (" / " .. entry.model) or ""),
  }

  if entry.status == "outdated" then
    -- Derived from the recorded revision, so this cannot be stale itself.
    lines[#lines + 1] = ("- Status:   OUTDATED — the issue moved since this ran (was %s)"):format(
      entry.issue_updated_at or "?"
    )
  elseif entry.status == "current" then
    lines[#lines + 1] = "- Status:   current"
  else
    lines[#lines + 1] = "- Status:   unknown (issue not cached)"
  end

  vim.list_extend(lines, { "", "## Prompt", "" })
  vim.list_extend(lines, vim.split(entry.prompt, "\n", { plain = true }))
  vim.list_extend(lines, { "", "## Response", "" })
  vim.list_extend(lines, vim.split(entry.response, "\n", { plain = true }))

  return lines
end

---@param uri string
---@param stamp string
function M.open(uri, stamp)
  local entry = analysis.get(uri, stamp)
  if not entry then
    return vim.notify(("issuehub: no analysis %s for %s"):format(stamp, uri), vim.log.levels.ERROR)
  end

  local name = bufname(uri, stamp)
  local buf
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(candidate) and vim.api.nvim_buf_get_name(candidate):sub(-#name) == name then
      buf = candidate
      break
    end
  end

  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.render(entry))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].issuehub_uri = uri
  vim.b[buf].issuehub_analysis = stamp

  vim.api.nvim_win_set_buf(0, buf)
end

return M
