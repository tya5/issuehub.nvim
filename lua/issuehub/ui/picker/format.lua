---@brief Shared item formatting for picker adapters.
local M = {}

---@param item issuehub.ViewItem
---@return string
function M.date(item)
  return (item.updated_at or ""):sub(1, 10)
end

---Column widths are computed across the whole view so IDs and statuses line up.
---@param items issuehub.ViewItem[]
---@return { id: integer, status: integer }
function M.widths(items)
  local w = { id = 8, status = 8 }
  for _, item in ipairs(items) do
    w.id = math.max(w.id, #(item.id or ""))
    w.status = math.max(w.status, #(item.status or ""))
  end
  w.id = math.min(w.id, 20)
  w.status = math.min(w.status, 16)
  return w
end

---@param item issuehub.ViewItem
---@param w { id: integer, status: integer }
---@return string
function M.line(item, w)
  local line = ("%s %-" .. w.id .. "s  %-" .. w.status .. "s  %s  %s"):format(
    item.bookmarked and "*" or " ",
    item.id or "",
    item.status or "",
    M.date(item),
    item.title or ""
  )
  -- Why this row matched, when the search knows (ripgrep path, §15).
  if item.matched_in then
    line = line .. ("  [%s]"):format(item.matched_in)
  end
  return line
end

---Single-line form for vim.ui.select, which has no column support at all.
---@param item issuehub.ViewItem
---@return string
function M.plain(item)
  return ("%s [%s] %s"):format(item.id or "", item.status or "", item.title or "")
end

return M
