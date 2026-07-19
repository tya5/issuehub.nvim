---@brief SQLite index backend, driven through the `sqlite3` CLI (§5.3).
---
--- Deliberately NOT sqlite.lua: that needs libsqlite3 plus a LuaJIT FFI binding,
--- which is a genuine hard dependency and §1.3 forbids those. The CLI is a
--- single optional binary, probed at runtime, degrading to the json backend when
--- absent — the same shape as the curl decision in §8.
---
--- CAVEAT: the sqlite3 CLI has no parameter-binding facility, so values are
--- escaped and interpolated by q() below rather than bound. That is acceptable
--- only because every value written here is derived from a provider payload and
--- the database holds nothing but a rebuildable projection of the cache — but it
--- is the reason q() must stay total. If this ever accepts user-authored SQL
--- fragments, move to a real binding layer first.

local repository = require("issuehub.core.repository")
local issue_mod = require("issuehub.core.issue")
local log = require("issuehub.util.log")

local M = {}

local SCHEMA = [[
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS issues (
  uri TEXT PRIMARY KEY,
  provider TEXT,
  id TEXT,
  title TEXT,
  status TEXT,
  closed INTEGER,
  assignee TEXT,
  updated_at TEXT,
  bookmarked INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_issues_open ON issues(closed, updated_at DESC);
]]

local FTS_SCHEMA = [[
CREATE VIRTUAL TABLE IF NOT EXISTS issues_fts USING fts5(
  uri UNINDEXED, title, description, memo, metadata, analyses,
  tokenize = 'unicode61'
);
]]

local available_cache = nil

---@return boolean
function M.available()
  if available_cache == nil then
    available_cache = vim.fn.executable("sqlite3") == 1
  end
  return available_cache
end

---@class issuehub.SqliteIndex : issuehub.Index
local Sqlite = {}
Sqlite.__index = Sqlite

function M.new()
  local self = setmetatable({ name = "sqlite", db = nil, fts = nil, ready = false }, Sqlite)
  return self
end

function Sqlite:_db()
  if not self.db then
    self.db = repository.state("index", "issues.db")
  end
  return self.db
end

---Run SQL, returning rows as tables. Serialized by virtue of being synchronous:
---only one sqlite3 process touches the database at a time, which is what keeps
---concurrent invocations off the write lock.
---@param sql string
---@return table[]? rows
---@return string? err
function Sqlite:_exec(sql)
  local db = self:_db()
  if not db then
    return nil, "workspace not configured"
  end
  require("issuehub.util.fs").mkdirp(vim.fs.dirname(db))

  local out = vim.system({ "sqlite3", "-json", db }, { stdin = sql, text = true }):wait()
  if out.code ~= 0 then
    local err = vim.trim(out.stderr or "")
    log.error("sqlite3 failed:", err)
    return nil, err
  end

  local stdout = vim.trim(out.stdout or "")
  if stdout == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
  if not ok then
    return nil, "unparseable sqlite3 output: " .. tostring(decoded)
  end
  return decoded
end

---SQL string literal escaping. Must be total: see the caveat in the header.
---
--- NULs are stripped because sqlite3 reads its script from stdin and would
--- truncate the statement at the first embedded NUL.
local function q(value)
  if value == nil then
    return "NULL"
  end
  if type(value) == "boolean" then
    return value and "1" or "0"
  end
  if type(value) == "number" then
    return tostring(value)
  end
  local s = tostring(value):gsub("%z", "")
  return "'" .. s:gsub("'", "''") .. "'"
end

function Sqlite:_ensure()
  if self.ready then
    return
  end
  self:_exec(SCHEMA)

  -- FTS5 is not compiled into every sqlite3 build. Probe once; without it the
  -- backend still serves list() and delegates search() to ripgrep (§15).
  local rows = self:_exec("SELECT 1 AS ok FROM pragma_compile_options WHERE compile_options = 'ENABLE_FTS5';")
  self.fts = rows ~= nil and #rows > 0
  if self.fts then
    self:_exec(FTS_SCHEMA)
  else
    log.warn("sqlite3 has no FTS5; full-text search will fall back to ripgrep")
  end

  self.ready = true
end

---@return boolean
function Sqlite:has_fts()
  self:_ensure()
  return self.fts == true
end

---@param issue issuehub.Issue
function Sqlite:put(issue)
  self:_ensure()
  local provider = issue_mod.parse(issue.uri)
  local sql = table.concat({
    "INSERT INTO issues (uri, provider, id, title, status, closed, assignee, updated_at)",
    ("VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"):format(
      q(issue.uri),
      q(provider),
      q(issue.id),
      q(issue.title),
      q(issue.status.name),
      q(issue.status.closed),
      q(issue.assignee),
      q(issue.updated_at)
    ),
    "ON CONFLICT(uri) DO UPDATE SET",
    "  title=excluded.title, status=excluded.status, closed=excluded.closed,",
    "  assignee=excluded.assignee, updated_at=excluded.updated_at;",
  }, "\n")
  self:_exec(sql)

  if self:has_fts() then
    self:_exec(("DELETE FROM issues_fts WHERE uri = %s;"):format(q(issue.uri)))
    self:_exec(
      ("INSERT INTO issues_fts (uri, title, description, memo, metadata, analyses) VALUES (%s, %s, %s, '', '', '');"):format(
        q(issue.uri),
        q(issue.title),
        q(issue.description)
      )
    )
  end
end

---@param uri string
function Sqlite:delete(uri)
  self:_ensure()
  self:_exec(("DELETE FROM issues WHERE uri = %s;"):format(q(uri)))
  if self:has_fts() then
    self:_exec(("DELETE FROM issues_fts WHERE uri = %s;"):format(q(uri)))
  end
end

---@param row table
---@return issuehub.ViewItem
local function to_item(row)
  return {
    uri = row.uri,
    id = row.id,
    title = row.title or "",
    status = row.status or "",
    closed = row.closed == 1 or row.closed == true,
    assignee = row.assignee,
    updated_at = row.updated_at or "",
    bookmarked = row.bookmarked == 1,
  }
end

---@param filter table?
---@return issuehub.ViewItem[]
function Sqlite:list(filter)
  self:_ensure()
  filter = filter or {}

  local where = {}
  if filter.closed ~= nil then
    where[#where + 1] = ("closed = %s"):format(q(filter.closed))
  end
  if filter.provider then
    where[#where + 1] = ("provider = %s"):format(q(filter.provider))
  end
  local clause = #where > 0 and ("WHERE " .. table.concat(where, " AND ")) or ""

  -- Ordering happens in SQL, which is the whole point of this backend: no O(n)
  -- Lua scan, and the idx_issues_open index covers it.
  local rows = self:_exec(("SELECT * FROM issues %s ORDER BY closed ASC, updated_at DESC;"):format(clause)) or {}
  return vim.tbl_map(to_item, rows)
end

---Ranked full-text search when FTS5 is present; LIKE otherwise.
---@param query string
---@return issuehub.ViewItem[]
function Sqlite:search(query)
  self:_ensure()
  if self:has_fts() then
    local rows = self:_exec(([[
      SELECT i.* FROM issues_fts f
      JOIN issues i ON i.uri = f.uri
      WHERE issues_fts MATCH %s
      ORDER BY rank;
    ]]):format(q(query)))
    if rows then
      return vim.tbl_map(to_item, rows)
    end
  end

  local like = q("%" .. query .. "%")
  local rows = self:_exec(
    ("SELECT * FROM issues WHERE title LIKE %s OR id LIKE %s ORDER BY closed ASC, updated_at DESC;"):format(like, like)
  ) or {}
  return vim.tbl_map(to_item, rows)
end

---@return integer count
function Sqlite:rebuild()
  self:_ensure()
  self:_exec("DELETE FROM issues;")
  if self:has_fts() then
    self:_exec("DELETE FROM issues_fts;")
  end

  local cache = require("issuehub.core.cache")
  local count = 0
  for _, uri in ipairs(repository.cached_uris()) do
    local entry = cache.get(uri)
    if entry and entry.issue then
      self:put(entry.issue)
      count = count + 1
    end
  end
  return count
end

---@return boolean ok
---@return string msg
function Sqlite:health()
  if not M.available() then
    return false, "sqlite3 not found in PATH"
  end
  self:_ensure()
  local rows = self:_exec("SELECT count(*) AS n FROM issues;")
  if not rows then
    return false, "sqlite3 present but the index is unreadable"
  end
  local n = rows[1] and rows[1].n or 0
  return true, ("sqlite index (%s entries, FTS5 %s)"):format(n, self.fts and "enabled" or "unavailable")
end

return M
