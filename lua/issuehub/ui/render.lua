---@brief Issue → buffer lines (§6).
---
--- Output is line-based Markdown so Treesitter, folding, `/` search, marks, and
--- any markdown renderer plugin work unmodified. issuehub implements no editor
--- of its own (§1.2).

local M = {}

---@param s string
---@return string[]
local function split(s)
  if s == nil or s == "" then
    return {}
  end
  return vim.split(s:gsub("\r\n", "\n"), "\n", { plain = true })
end

---@param entry issuehub.CacheEntry?
---@return string
local function freshness(entry)
  if not entry or not entry.fetched_at then
    return "never synced"
  end
  return "synced " .. entry.fetched_at
end

---@class issuehub.RenderResult
---@field lines string[]
---@field sections table<string, { first: integer, last: integer }>  1-indexed, inclusive

---@param issue issuehub.Issue
---@param entry issuehub.CacheEntry?
---@return issuehub.RenderResult
function M.issue(issue, entry)
  local lines = {}
  local sections = {}

  local function push(...)
    for _, line in ipairs({ ... }) do
      lines[#lines + 1] = line
    end
  end

  ---@param name string
  ---@param fn fun()
  local function section(name, fn)
    local first = #lines + 1
    fn()
    sections[name] = { first = first, last = #lines }
  end

  section("header", function()
    push(("# %s  %s"):format(issue.id, issue.title))
    push("")
    push(("- Status:   %s%s"):format(issue.status.name, issue.status.closed and "  (closed)" or ""))
    push(("- Assignee: %s"):format(issue.assignee or "-"))
    push(("- Reporter: %s"):format(issue.reporter or "-"))
    if #issue.labels > 0 then
      push(("- Labels:   %s"):format(table.concat(issue.labels, ", ")))
    end
    push(("- Updated:  %s  (%s)"):format(issue.updated_at, freshness(entry)))
    if issue.url then
      push(("- URL:      %s"):format(issue.url))
    end
    push("")
  end)

  section("description", function()
    push("## Description")
    push("")
    local body = split(issue.description)
    if #body == 0 then
      push("_(empty)_")
    else
      for _, line in ipairs(body) do
        push(line)
      end
    end
    push("")
  end)

  section("comments", function()
    local total = issue.raw and issue.raw.comment_total or #issue.comments
    push(("## Comments (%d)"):format(total or #issue.comments))
    push("")
    if #issue.comments == 0 then
      push("_(none)_")
      push("")
    end
    for _, c in ipairs(issue.comments) do
      push(("### %s — %s"):format(c.author or "unknown", c.created_at or ""))
      push("")
      for _, line in ipairs(split(c.body)) do
        push(line)
      end
      push("")
    end
    -- Comments are capped at fetch time, not just at render time (§23.3).
    if total and total > #issue.comments then
      push(("_%d older comment(s) not fetched._"):format(total - #issue.comments))
      push("")
    end
  end)

  -- Memo / Metadata / Prompt become editable regions in 0.2. They are rendered
  -- now as placeholders so the layout users learn does not shift later.
  section("workspace", function()
    push("## Memo")
    push("")
    push("_(editable in 0.2)_")
    push("")
  end)

  return { lines = lines, sections = sections }
end

return M
