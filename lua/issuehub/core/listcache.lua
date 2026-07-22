---@brief Cached issue *lists* (§8, §10).
---
--- The issue cache answers "what is in PROJ-123". This answers "which issues
--- matched this query, and when did I last ask" — a separate fact with its own
--- freshness, which is why it has its own file rather than being derived from
--- the issue cache.
---
--- Pages merge in as they arrive, so a partial walk of a twenty-thousand-issue
--- backlog is still useful and resumable rather than all-or-nothing.

local fs = require("issuehub.util.fs")
local lock = require("issuehub.core.lock")
local repository = require("issuehub.core.repository")

local M = {}

---@class issuehub.CachedList
---@field provider string
---@field query any                Whatever the provider was given; nil for its default.
---@field uris string[]            Accumulated, in the order pages returned them.
---@field fetched_at string        When a page last merged in.
---@field started_at string?       When the current walk began.
---@field cursor any               Where to resume; nil when exhausted or unstarted.
---@field complete boolean         The provider ran out of pages.
---@field pages integer

---A stable, readable-ish key for a (provider, query) pair.
---@param provider string
---@param query any
---@return string
function M.key(provider, query)
  local encoded = query == nil and "default" or vim.json.encode(query)
  -- Hashed because a query can be long, contain slashes, or be a table.
  return ("%s-%s"):format(provider, vim.fn.sha256(encoded):sub(1, 16))
end

---@param key string
---@return string? path
local function path_of(key)
  local dir = repository.state("lists")
  return dir and vim.fs.joinpath(dir, key .. ".json") or nil
end

---@param provider string
---@param query any
---@return issuehub.CachedList?
function M.get(provider, query)
  local path = path_of(M.key(provider, query))
  if not path or not fs.exists(path) then
    return nil
  end
  local data = fs.read_json(path)
  if type(data) ~= "table" or type(data.uris) ~= "table" then
    return nil
  end
  return data
end

---@param list issuehub.CachedList
---@return boolean ok
---@return string? err
local function save(list)
  local path = path_of(M.key(list.provider, list.query))
  if not path then
    return false, "workspace not configured"
  end
  -- Derived: atomic but not durable, like the rest of `.state/`.
  return fs.write_json(path, list, { sync = false })
end

---Merge one page of results into the cached list.
---
--- Order is preserved and duplicates are dropped, so re-walking from the start
--- refreshes freshness without reshuffling or growing the list.
---@param provider string
---@param query any
---@param uris string[]
---@param opts { cursor: any, complete: boolean?, reset: boolean? }?
---@return issuehub.CachedList? list  nil on lock contention — callers must check.
---@return string? err
function M.merge(provider, query, uris, opts)
  -- A paginated fetch flushes per page; two of them against the same query
  -- would otherwise interleave read-modify-writes and lose whole pages.
  return lock.with("lists", M.key(provider, query), "listcache.merge", function()
    return M._merge_locked(provider, query, uris, opts)
  end)
end

---@param provider string
---@param query any
---@param uris string[]
---@param opts table?
---@return issuehub.CachedList
function M._merge_locked(provider, query, uris, opts)
  opts = opts or {}
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local list = (not opts.reset and M.get(provider, query))
    or {
      provider = provider,
      query = query,
      uris = {},
      started_at = now,
      pages = 0,
    }

  local seen = {}
  for _, uri in ipairs(list.uris) do
    seen[uri] = true
  end
  for _, uri in ipairs(uris) do
    if not seen[uri] then
      seen[uri] = true
      list.uris[#list.uris + 1] = uri
    end
  end

  list.fetched_at = now
  list.cursor = opts.cursor
  list.complete = opts.complete == true or opts.cursor == nil
  list.pages = (list.pages or 0) + 1

  save(list)
  return list
end

---@param provider string
---@param query any
function M.forget(provider, query)
  lock.with("lists", M.key(provider, query), "listcache.forget", function()
    local path = path_of(M.key(provider, query))
    if path and fs.exists(path) then
      vim.uv.fs_unlink(path)
    end
  end)
end

---Seconds since the list was last touched, or nil when never fetched.
---@param list issuehub.CachedList?
---@return integer?
function M.age(list)
  if not list or not list.fetched_at then
    return nil
  end
  local y, mo, d, h, mi, sec = list.fetched_at:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local at = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(sec),
    isdst = false,
  })
  return math.max(0, os.difftime(os.time(os.date("!*t") --[[@as osdateparam]]), at))
end

---Human-readable freshness, for picker titles.
---@param list issuehub.CachedList?
---@return string
function M.describe(list)
  local age = M.age(list)
  if not age then
    return "never fetched"
  end
  local text
  if age < 90 then
    text = ("%ds ago"):format(age)
  elseif age < 5400 then
    text = ("%dm ago"):format(math.floor(age / 60))
  elseif age < 172800 then
    text = ("%dh ago"):format(math.floor(age / 3600))
  else
    text = ("%dd ago"):format(math.floor(age / 86400))
  end
  return list.complete and text or (text .. ", partial")
end

---Every cached list, newest first.
---@return issuehub.CachedList[]
function M.all()
  local dir = repository.state("lists")
  if not dir or not fs.is_dir(dir) then
    return {}
  end
  local out = {}
  for _, name in ipairs(fs.list(dir)) do
    if name:match("%.json$") then
      local data = fs.read_json(vim.fs.joinpath(dir, name))
      if type(data) == "table" and data.uris then
        out[#out + 1] = data
      end
    end
  end
  table.sort(out, function(a, b)
    return (a.fetched_at or "") > (b.fetched_at or "")
  end)
  return out
end

return M
