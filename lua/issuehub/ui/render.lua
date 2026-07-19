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
---@field readonly_until integer  Last line of the read-only prefix.

---Headings that delimit the editable regions. These are sentinels: writeback
---re-parses the buffer by locating them, so they must be stable and unique.
M.SECTIONS = {
  { field = "memo", heading = "## Memo" },
  { field = "metadata", heading = "## Metadata" },
  { field = "prompt", heading = "## Prompt" },
}

---@param lines string[]
---@return table<string, {first: integer, last: integer}>? sections
---@return string? err
function M.parse_sections(lines)
  local found = {}
  for index, line in ipairs(lines) do
    for _, section in ipairs(M.SECTIONS) do
      if line == section.heading then
        if found[section.field] then
          return nil, ("duplicate '%s' heading"):format(section.heading)
        end
        found[section.field] = index
      end
    end
  end

  local order = {}
  for _, section in ipairs(M.SECTIONS) do
    if not found[section.field] then
      return nil, ("missing '%s' heading"):format(section.heading)
    end
    order[#order + 1] = { field = section.field, at = found[section.field] }
  end
  table.sort(order, function(a, b)
    return a.at < b.at
  end)

  local ranges = {}
  for i, entry in ipairs(order) do
    local next_at = order[i + 1] and order[i + 1].at or (#lines + 1)
    -- Content starts after the heading and the blank line beneath it.
    ranges[entry.field] = { first = entry.at + 1, last = next_at - 1 }
  end
  return ranges
end

---Extract the edited text of each editable region.
---@param lines string[]
---@return table<string, string>? content
---@return string? err
function M.extract(lines)
  local ranges, err = M.parse_sections(lines)
  if not ranges then
    return nil, err
  end

  local out = {}
  for field, range in pairs(ranges) do
    local body = {}
    for i = range.first, range.last do
      body[#body + 1] = lines[i] or ""
    end
    -- Strip the framing blank lines the renderer adds, and any the user left.
    local text = table.concat(body, "\n")
    out[field] = (text:gsub("^%s*\n", ""):gsub("%s+$", ""))
  end
  return out
end

---@param issue issuehub.Issue
---@param entry issuehub.CacheEntry?
---@param overlay issuehub.Overlay?
---@return issuehub.RenderResult
function M.issue(issue, entry, overlay)
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

  -- Editable regions. Everything above is read-only; these three map to files
  -- in the Workspace and are written back on :w (§6).
  overlay = overlay or { memo = "", metadata = "", prompt = "" }

  local readonly_until = #lines

  for _, spec in ipairs(M.SECTIONS) do
    section(spec.field, function()
      push(spec.heading)
      push("")
      for _, line in ipairs(split(overlay[spec.field] or "")) do
        push(line)
      end
      -- A trailing blank line gives the user somewhere to type in an empty
      -- section without first having to open a line.
      push("")
    end)
  end

  return { lines = lines, sections = sections, readonly_until = readonly_until }
end

return M
