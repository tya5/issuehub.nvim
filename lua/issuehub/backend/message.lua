---@brief Rendering a Request into the prose a model reads.
---
--- Shared by every backend that talks to a language model (A2A, OpenAI-compatible
--- …): the issue and the workspace go across as labelled Markdown sections, not
--- raw JSON, because the receiver is a model and prose survives the round trip
--- better than a serialized table. One renderer means the analysis a user sees
--- does not depend on which backend produced it.

local M = {}

---@param req issuehub.Request
---@return string
function M.render(req)
  local parts = {}

  local context = req.context or {}
  local issue = context.issue
  if issue then
    parts[#parts + 1] = ("# %s  %s"):format(issue.id or "", issue.title or "")
    parts[#parts + 1] = ("Status: %s\nAssignee: %s\nURL: %s"):format(
      issue.status and issue.status.name or "?",
      issue.assignee or "-",
      issue.url or "-"
    )
    if issue.description and issue.description ~= "" then
      parts[#parts + 1] = "## Description\n\n" .. issue.description
    end
    if issue.comments and #issue.comments > 0 then
      local comments = {}
      for _, comment in ipairs(issue.comments) do
        comments[#comments + 1] = ("- %s: %s"):format(comment.author or "?", comment.body or "")
      end
      parts[#parts + 1] = "## Comments\n\n" .. table.concat(comments, "\n")
    end
  end

  local overlay = context.overlay
  if overlay then
    if overlay.memo and overlay.memo ~= "" then
      parts[#parts + 1] = "## Memo\n\n" .. overlay.memo
    end
    if overlay.metadata and overlay.metadata ~= "" then
      parts[#parts + 1] = "## Metadata\n\n```yaml\n" .. overlay.metadata .. "\n```"
    end
  end

  for _, document in ipairs(context.documents or {}) do
    parts[#parts + 1] = ("## %s\n\n%s"):format(document.name, document.text)
  end

  if context.selection and context.selection ~= "" then
    parts[#parts + 1] = "## Selection\n\n" .. context.selection
  end

  parts[#parts + 1] = "## Task\n\n" .. req.prompt
  return table.concat(parts, "\n\n")
end

return M
