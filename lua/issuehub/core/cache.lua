---@brief Remote snapshot persistence. Disposable; never a source of truth.
local fs = require("issuehub.util.fs")
local repository = require("issuehub.core.repository")
local issue_mod = require("issuehub.core.issue")

local M = {}

---@class issuehub.CacheEntry
---@field fetched_at string
---@field partial boolean  True when the issue came from list()/search() and so
---                        lacks description and comments (§7).
---@field issue issuehub.Issue

---@param uri string
---@return issuehub.CacheEntry? entry
---@return string? err
function M.get(uri)
  local path, err = repository.cache_file(uri)
  if not path then
    return nil, err
  end
  if not fs.exists(path) then
    return nil
  end
  local entry, rerr = fs.read_json(path)
  if not entry then
    return nil, rerr
  end
  entry.issue = issue_mod.normalize(entry.issue or {})
  return entry
end

---Write the cache file, without touching the index.
---@param issue issuehub.Issue
---@param partial boolean
---@return boolean ok
---@return string? err
local function write_entry(issue, partial)
  local path, err = repository.cache_file(issue.uri)
  if not path then
    return false, err
  end

  local ok_case, cerr = repository.check_case_collision(issue.uri)
  if not ok_case then
    return false, cerr
  end

  -- A partial result must never overwrite a complete one: the picker refreshing
  -- a list would otherwise blank out descriptions already fetched by get().
  if partial then
    local existing = M.get(issue.uri)
    if existing and not existing.partial then
      partial = false
      issue = vim.tbl_extend("force", existing.issue, issue)
      issue.description = existing.issue.description
      issue.comments = existing.issue.comments
    end
  end

  -- No fsync: this file lives under .state/ and is rebuildable by definition.
  local ok, werr = fs.write_json(path, {
    fetched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    partial = partial,
    issue = issue,
  }, { sync = false })
  if not ok then
    return false, werr
  end
  return true
end

---@param issue issuehub.Issue
---@param opts { partial: boolean? }?
---@return boolean ok
---@return string? err
function M.put(issue, opts)
  local ok, err = write_entry(issue, opts and opts.partial == true or false)
  if not ok then
    return false, err
  end
  require("issuehub.core.index").get():put(issue)
  return true
end

---Store results from list()/search(), which carry no description or comments.
---
--- Files first, then ONE index write: indexing per issue spawns a sqlite3
--- process per issue, which is what makes a large sync unusable.
---@param issues issuehub.Issue[]
---@return integer written
function M.put_all(issues)
  local stored = {}
  for _, issue in ipairs(issues) do
    if write_entry(issue, true) then
      stored[#stored + 1] = issue
    end
  end
  require("issuehub.core.index").get():put_many(stored)
  return #stored
end

---@param uri string
---@param stale_after integer seconds
---@return boolean
function M.is_stale(uri, stale_after)
  local entry = M.get(uri)
  if not entry or not entry.fetched_at then
    return true
  end
  -- A partial entry is never "fresh enough": it has no description or comments,
  -- so age is beside the point.
  if entry.partial then
    return true
  end
  local y, mo, d, h, mi, s = entry.fetched_at:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return true
  end
  local fetched = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  -- Both sides are compared in UTC terms; os.time() built a local-time epoch
  -- from a UTC wall clock, so shift it back before comparing.
  local now = os.time(os.date("!*t") --[[@as osdateparam]])
  return os.difftime(now, fetched) > stale_after
end

---@param uri string
function M.delete(uri)
  local path = repository.cache_file(uri)
  if path and fs.exists(path) then
    vim.uv.fs_unlink(path)
  end
  require("issuehub.core.index").get():delete(uri)
end

return M
