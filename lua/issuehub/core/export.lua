---@brief Export (§14).
---
--- Input is always a View, never a picker: that is what lets the same call work
--- whether the set came from snacks multi-select, a collection file, or a script
--- that built one by hand.
---
--- Export performs no network I/O. It reads the latest *cached* issue plus the
--- Workspace overlay, and records `fetched_at` so staleness is visible in the
--- output rather than implied.

local cache = require("issuehub.core.cache")
local overlay = require("issuehub.core.overlay")
local workspace = require("issuehub.core.workspace")
local fs = require("issuehub.util.fs")
local yaml = require("issuehub.util.yaml")

local M = {}

---@class issuehub.Exporter
---@field ext string
---@field write fun(rows: table[], columns: string[]): string

---@type table<string, issuehub.Exporter>
local registry = {}

---Columns always present, in this order. Metadata keys are appended as
---`meta.<key>`, so a flat table can carry free-form YAML without a schema.
---
--- Ordered for analysis rather than for reading: the identity columns, then the
--- dates a defect curve is built from (`created_at`, `closed_at`, and
--- `age_days` / `days_to_close` precomputed because a spreadsheet does date
--- arithmetic badly), then the rest.
local BASE_COLUMNS = {
  "uri",
  "provider",
  "id",
  "title",
  "status",
  "closed",
  "created_at",
  "closed_at",
  "updated_at",
  "age_days",
  "days_to_close",
  "assignee",
  "reporter",
  "labels",
  "comments",
  "url",
  "bookmarked",
  "fetched_at",
  "memo",
}

---Whole days between two ISO 8601 timestamps.
---@param from string?
---@param to string?
---@return number?
local function days_between(from, to)
  if not from or from == "" or not to or to == "" then
    return nil
  end
  local function epoch(stamp)
    local y, mo, d, h, mi, sec = stamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
      return nil
    end
    return os.time({
      year = tonumber(y),
      month = tonumber(mo),
      day = tonumber(d),
      hour = tonumber(h),
      min = tonumber(mi),
      sec = tonumber(sec),
      isdst = false,
    })
  end
  local a, b = epoch(from), epoch(to)
  if not a or not b then
    return nil
  end
  return math.floor(os.difftime(b, a) / 86400 * 10 + 0.5) / 10
end

---@param value any
---@return string
local function stringify(value)
  if value == nil then
    return ""
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  if type(value) == "table" then
    -- Multi-value fields join with "; " rather than "," so they survive CSV
    -- without depending on quoting.
    local parts = {}
    for _, item in ipairs(value) do
      parts[#parts + 1] = tostring(item)
    end
    return table.concat(parts, "; ")
  end
  return tostring(value)
end

---Assemble one row: cached issue + overlay + state.
---@param item issuehub.ViewItem
---@return table
local function row_for(item)
  local entry = cache.get(item.uri)
  local issue = entry and entry.issue
  local o = overlay.read(item.uri)
  local state = workspace.state(item.uri)

  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local created = issue and issue.created_at or ""
  local closed_at = issue and issue.closed_at or nil

  local row = {
    uri = item.uri,
    provider = select(1, require("issuehub.core.issue").parse(item.uri)) or "",
    id = item.id,
    title = issue and issue.title or item.title,
    status = issue and issue.status.name or item.status,
    closed = issue and issue.status.closed or item.closed,
    created_at = created,
    closed_at = closed_at or "",
    updated_at = issue and issue.updated_at or item.updated_at,
    -- Precomputed because date arithmetic in a spreadsheet is where these
    -- analyses usually go wrong.
    age_days = days_between(created, closed_at or now),
    days_to_close = closed_at and days_between(created, closed_at) or nil,
    assignee = issue and issue.assignee or item.assignee,
    reporter = issue and issue.reporter or "",
    labels = issue and issue.labels or {},
    comments = issue and ((issue.raw or {}).comment_total or #(issue.comments or {})) or nil,
    -- Freshness travels with the data: an export is a snapshot of the cache,
    -- not of the tracker.
    fetched_at = entry and entry.fetched_at or "",
    bookmarked = state.bookmarked,
    url = issue and issue.url or "",
    memo = o.memo,
  }

  for key, value in pairs(yaml.parse(o.metadata)) do
    row["meta." .. key] = value
  end

  return row
end

---@param view issuehub.View
---@return table[] rows
---@return string[] columns
function M.rows(view)
  local rows = {}
  for _, item in ipairs(view:get_selected()) do
    rows[#rows + 1] = row_for(item)
  end

  -- Metadata is schema-free, so the column set is the union across rows.
  local meta_keys = {}
  for _, row in ipairs(rows) do
    for key in pairs(row) do
      if key:match("^meta%.") then
        meta_keys[key] = true
      end
    end
  end

  local extra = vim.tbl_keys(meta_keys)
  table.sort(extra)

  local columns = vim.list_extend({}, BASE_COLUMNS)
  vim.list_extend(columns, extra)
  return rows, columns
end

---@param value string
---@return string
local function csv_cell(value)
  if value:find('[",\n\r]') then
    return '"' .. value:gsub('"', '""') .. '"'
  end
  return value
end

M.builtin = {
  csv = {
    ext = "csv",
    write = function(rows, columns)
      local lines = { table.concat(vim.tbl_map(csv_cell, columns), ",") }
      for _, row in ipairs(rows) do
        local cells = {}
        for _, column in ipairs(columns) do
          cells[#cells + 1] = csv_cell(stringify(row[column]))
        end
        lines[#lines + 1] = table.concat(cells, ",")
      end
      return table.concat(lines, "\n") .. "\n"
    end,
  },

  markdown = {
    ext = "md",
    write = function(rows, columns)
      -- Memo is multi-line prose; a table cell is the wrong shape for it.
      local table_columns = vim.tbl_filter(function(column)
        return column ~= "memo"
      end, columns)

      local lines = {
        "| " .. table.concat(table_columns, " | ") .. " |",
        "|" .. (" --- |"):rep(#table_columns),
      }
      for _, row in ipairs(rows) do
        local cells = {}
        for _, column in ipairs(table_columns) do
          cells[#cells + 1] = stringify(row[column]):gsub("\n", " "):gsub("|", "\\|")
        end
        lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
      end

      local with_memo = {}
      for _, row in ipairs(rows) do
        if row.memo ~= "" then
          with_memo[#with_memo + 1] = ("\n### %s  %s\n\n%s"):format(row.id, row.title, row.memo)
        end
      end
      if #with_memo > 0 then
        lines[#lines + 1] = "\n## Notes"
        vim.list_extend(lines, with_memo)
      end

      return table.concat(lines, "\n") .. "\n"
    end,
  },

  json = {
    ext = "json",
    write = function(rows)
      return vim.json.encode(rows) .. "\n"
    end,
  },

  yaml = {
    ext = "yaml",
    write = function(rows)
      local chunks = {}
      for _, row in ipairs(rows) do
        chunks[#chunks + 1] = "- " .. yaml.encode(row):gsub("\n(.)", "\n  %1"):gsub("^", ""):gsub("\n%s*$", "")
      end
      return table.concat(chunks, "\n") .. "\n"
    end,
  },
}

for name, exporter in pairs(M.builtin) do
  registry[name] = exporter
end

---Register a third-party exporter.
---@param name string
---@param exporter issuehub.Exporter
function M.register(name, exporter)
  registry[name] = exporter
end

---@return string[]
function M.formats()
  local names = vim.tbl_keys(registry)
  table.sort(names)
  return names
end

---@param format string
---@param view issuehub.View
---@param opts { path: string? }?
---@return string? path
---@return string? err
function M.write(format, view, opts)
  opts = opts or {}

  local exporter = registry[format]
  if not exporter then
    return nil, ("unknown export format '%s' (available: %s)"):format(format, table.concat(M.formats(), ", "))
  end
  if view:is_empty() then
    return nil, "nothing to export"
  end

  local rows, columns = M.rows(view)
  local ok, content = pcall(exporter.write, rows, columns)
  if not ok then
    return nil, ("exporter '%s' failed: %s"):format(format, tostring(content))
  end

  local path = opts.path
  if not path then
    local dir = require("issuehub.config").get().export.dir or vim.fn.getcwd()
    path = vim.fs.joinpath(fs.expand(dir), ("%s.%s"):format(view:slug(), exporter.ext))
  end
  path = fs.expand(path)

  local written, err = fs.write(path, content)
  if not written then
    return nil, err
  end
  return path
end

return M
