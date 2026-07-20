---@brief Merging an exported file back into the workspace.
---
--- The inverse of `core/export`, deliberately asymmetric: **only the local half
--- is merged.** Issue columns (title, status, dates, assignee…) are read and
--- discarded, because the tracker owns them — importing them would let a stale
--- spreadsheet overwrite the cache with fiction. What comes back is what you
--- could have typed: `memo`, `meta.*`, and `bookmarked`.
---
--- The file wins on conflict. That is defensible only because the workspace is a
--- Git repository: `git diff` is the undo, and the report names every issue
--- touched so you know where to look. When the workspace is *not* a Git repo
--- that safety net is absent, and the caller is expected to say so.

local fs = require("issuehub.util.fs")
local issue_mod = require("issuehub.core.issue")
local overlay = require("issuehub.core.overlay")
local workspace = require("issuehub.core.workspace")
local yaml = require("issuehub.util.yaml")

local M = {}

---@class issuehub.ImportRow
---@field uri string
---@field memo string?
---@field metadata table<string, any>?
---@field bookmarked boolean?

---@class issuehub.ImportResult
---@field imported string[]         URIs whose workspace changed.
---@field unchanged integer
---@field overwritten table[]       { uri, field } pairs that replaced local content.
---@field errors string[]
---@field metadata_comments string[] URIs whose metadata.yaml comments were lost.

---Parse one CSV record set. Handles quoted fields containing commas, newlines,
---and doubled quotes — all three of which `core/export` emits.
---@param text string
---@return string[][] rows
function M.parse_csv(text)
  local rows, row, field = {}, {}, {}
  local i, n = 1, #text
  local quoted = false

  local function end_field()
    row[#row + 1] = table.concat(field)
    field = {}
  end
  local function end_row()
    end_field()
    -- A trailing newline must not produce a final empty record.
    if #row > 1 or row[1] ~= "" then
      rows[#rows + 1] = row
    end
    row = {}
  end

  while i <= n do
    local c = text:sub(i, i)
    if quoted then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          quoted = false
        end
      else
        field[#field + 1] = c
      end
    elseif c == '"' then
      quoted = true
    elseif c == "," then
      end_field()
    elseif c == "\n" then
      end_row()
    elseif c ~= "\r" then
      field[#field + 1] = c
    end
    i = i + 1
  end
  if #field > 0 or #row > 0 then
    end_row()
  end
  return rows
end

---@param value string
---@return boolean?
local function to_boolean(value)
  local v = tostring(value):lower()
  if v == "true" or v == "yes" or v == "1" then
    return true
  end
  if v == "false" or v == "no" or v == "0" or v == "" then
    return false
  end
  return nil
end

---Export flattens multi-value fields with `; `, so reverse that on the way in.
---@param value any
---@return any
local function unflatten(value)
  if type(value) ~= "string" or not value:find("; ", 1, true) then
    return value
  end
  local list = {}
  for part in (value .. "; "):gmatch("(.-); ") do
    part = vim.trim(part)
    if part ~= "" then
      list[#list + 1] = part
    end
  end
  return #list > 1 and list or value
end

---@param record table<string, any>
---@return issuehub.ImportRow?
---@return string? err
local function to_row(record)
  local uri = record.uri
  if type(uri) ~= "string" or not issue_mod.is_uri(uri) then
    return nil, ("not a valid issue URI: %s"):format(tostring(uri))
  end

  local metadata = nil
  for key, value in pairs(record) do
    local name = key:match("^meta%.(.+)$")
    if name and value ~= nil and value ~= "" then
      metadata = metadata or {}
      metadata[name] = unflatten(value)
    end
  end

  return {
    uri = uri,
    -- Absent column vs empty cell are different: absent means "not in this
    -- file, leave it alone"; empty means "clear it".
    memo = record.memo,
    metadata = metadata,
    bookmarked = record.bookmarked ~= nil and to_boolean(record.bookmarked) or nil,
  }
end

---@param path string
---@return issuehub.ImportRow[]? rows
---@return string? err
function M.parse(path)
  local expanded = fs.expand(path)
  local text = fs.read(expanded)
  if not text then
    return nil, ("cannot read %s"):format(expanded)
  end

  local records
  if expanded:match("%.json$") then
    local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if not ok or type(decoded) ~= "table" then
      return nil, ("invalid JSON in %s"):format(expanded)
    end
    records = vim.islist(decoded) and decoded or { decoded }
  else
    local csv = M.parse_csv(text)
    if #csv < 2 then
      return nil, ("%s has no data rows"):format(expanded)
    end
    local header = csv[1]
    records = {}
    for i = 2, #csv do
      local record = {}
      for c, name in ipairs(header) do
        record[name] = csv[i][c]
      end
      records[#records + 1] = record
    end
  end

  local rows, errors = {}, {}
  for _, record in ipairs(records) do
    local row, err = to_row(record)
    if row then
      rows[#rows + 1] = row
    else
      errors[#errors + 1] = err
    end
  end

  if #rows == 0 then
    return nil, ("no importable rows in %s (%s)"):format(expanded, errors[1] or "no uri column?")
  end
  return rows
end

---Merge parsed metadata into whatever the issue already has.
---
--- Keys absent from the import are preserved, so a partial column set does not
--- wipe the rest. Comments and key order in the existing file cannot survive —
--- the file is regenerated — which is why callers report it.
---@param uri string
---@param incoming table
---@return string text
---@return boolean had_comments
local function merged_metadata(uri, incoming)
  local existing_text = overlay.read(uri).metadata
  local had_comments = existing_text:find("\n%s*#") ~= nil or existing_text:match("^%s*#") ~= nil
  local merged = yaml.parse(existing_text)
  for key, value in pairs(incoming) do
    merged[key] = value
  end
  return vim.trim(yaml.encode(merged)), had_comments
end

---Apply parsed rows to the workspace.
---@param rows issuehub.ImportRow[]
---@param opts { dry_run: boolean? }?
---@return issuehub.ImportResult
function M.apply(rows, opts)
  opts = opts or {}
  local result = { imported = {}, unchanged = 0, overwritten = {}, errors = {}, metadata_comments = {} }

  for _, row in ipairs(rows) do
    local current = overlay.read(row.uri)
    local changes = {}

    if row.memo ~= nil then
      local incoming = (tostring(row.memo):gsub("\r\n", "\n"):gsub("%s+$", ""))
      if incoming ~= current.memo then
        changes.memo = incoming
        if current.memo ~= "" then
          result.overwritten[#result.overwritten + 1] = { uri = row.uri, field = "memo" }
        end
      end
    end

    if row.metadata then
      local text, had_comments = merged_metadata(row.uri, row.metadata)
      if text ~= current.metadata then
        changes.metadata = text
        if current.metadata ~= "" then
          result.overwritten[#result.overwritten + 1] = { uri = row.uri, field = "metadata" }
          if had_comments then
            result.metadata_comments[#result.metadata_comments + 1] = row.uri
          end
        end
      end
    end

    local bookmark_changed = row.bookmarked ~= nil and row.bookmarked ~= workspace.state(row.uri).bookmarked

    if vim.tbl_isempty(changes) and not bookmark_changed then
      result.unchanged = result.unchanged + 1
    else
      if not opts.dry_run then
        if not vim.tbl_isempty(changes) then
          local _, err = overlay.write(row.uri, changes)
          if err then
            result.errors[#result.errors + 1] = ("%s: %s"):format(row.uri, err)
          end
        end
        if bookmark_changed then
          workspace.set_state(row.uri, { bookmarked = row.bookmarked })
          require("issuehub.core.index").get():set_bookmark(row.uri, row.bookmarked)
        end
      end
      result.imported[#result.imported + 1] = row.uri
    end
  end

  return result
end

---@param path string
---@param opts { dry_run: boolean? }?
---@return issuehub.ImportResult? result
---@return string? err
function M.run(path, opts)
  local rows, err = M.parse(path)
  if not rows then
    return nil, err
  end
  return M.apply(rows, opts)
end

return M
