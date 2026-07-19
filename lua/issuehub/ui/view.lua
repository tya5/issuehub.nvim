---@brief View — the single list model (§0.1, §9.3).
---
--- A View is what the picker renders AND what export, analysis, and collections
--- consume. Because every list-shaped operation takes a View rather than a
--- picker, adding a picker backend adds zero code paths to export.

local M = {}

---@class issuehub.ViewImpl : issuehub.View
local View = {}
View.__index = View

---The most recently shown View.
---
---This is what makes `:IssueHub export csv` act on "what I was just looking at"
---without export knowing anything about pickers (§9.3).
---@type issuehub.View?
local last = nil

---@param view issuehub.View
function M.set_last(view)
  last = view
end

---@return issuehub.View?
function M.last()
  return last
end

---Built-in fields, spelled the same way metadata is.
---
--- `status:open` should behave like `priority:high` — a user filtering in the
--- picker has no reason to care which of the two came from the tracker and
--- which they typed themselves.
---@param item issuehub.ViewItem
---@return string
local function builtin_tokens(item)
  local provider = require("issuehub.core.issue").parse(item.uri)
  local tokens = {
    ("status:%s"):format(tostring(item.status or ""):lower():gsub("%s+", "-")),
    ("state:%s"):format(item.closed and "closed" or "open"),
    ("provider:%s"):format(tostring(provider or ""):lower()),
  }
  if item.assignee and item.assignee ~= "" then
    tokens[#tokens + 1] = ("assignee:%s"):format(tostring(item.assignee):lower():gsub("%s+", "-"))
  end
  if item.bookmarked then
    tokens[#tokens + 1] = "bookmarked:true"
  end
  return table.concat(tokens, " ")
end

---Fold each issue's notes and built-in fields into its item as hidden match
---text.
---
--- Pickers match on a text field and display something else, so this is what
--- lets typing in the picker reach memo, metadata, and status alike.
---@param items issuehub.ViewItem[]
---@return issuehub.ViewItem[]
function M.with_notes(items)
  local overlay = require("issuehub.core.overlay")
  -- Resolved once for the whole list: without it this opened three files per
  -- issue, nearly all of which do not exist.
  local has_workspace = require("issuehub.core.repository").workspace_uris()

  for _, item in ipairs(items) do
    local notes = has_workspace[item.uri] and overlay.searchable(item.uri) or ""
    item.notes = (builtin_tokens(item) .. (notes ~= "" and (" " .. notes) or ""))
  end
  return items
end

---@param opts { source: string, label: string, items: issuehub.ViewItem[] }
---@return issuehub.View
function M.new(opts)
  return setmetatable({
    source = opts.source or "query",
    label = opts.label or "issues",
    items = opts.items or {},
    _selected = nil,
  }, View)
end

---@param issues issuehub.Issue[]
---@param opts { source: string?, label: string? }?
---@return issuehub.View
function M.from_issues(issues, opts)
  opts = opts or {}
  local issue_mod = require("issuehub.core.issue")
  local items = {}
  for _, issue in ipairs(issues) do
    items[#items + 1] = issue_mod.to_item(issue)
  end
  return M.new({
    source = opts.source or "query",
    label = opts.label or "issues",
    items = require("issuehub.core.index").sort(items),
  })
end

---@return issuehub.ViewItem[]
function View:get_items()
  return self.items
end

---Selection, or every item when nothing is selected.
---
--- The fallback is what lets Level 2 pickers degrade gracefully: a backend
--- without multi_select simply never records a selection, and bulk operations
--- act on the whole view instead of erroring (§9.2).
---@return issuehub.ViewItem[]
function View:get_selected()
  if self._selected and #self._selected > 0 then
    return self._selected
  end
  return self.items
end

---@param items issuehub.ViewItem[]
function View:set_selected(items)
  self._selected = items
end

---@return integer
function View:count()
  return #self.items
end

---@return boolean
function View:is_empty()
  return #self.items == 0
end

---Filesystem-safe stem for export filenames.
---@return string
function View:slug()
  local slug = self.label:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return slug ~= "" and slug or "issues"
end

return M
