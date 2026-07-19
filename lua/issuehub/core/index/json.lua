---@brief Default index backend: a single JSON file. Zero dependencies.
local fs = require("issuehub.util.fs")
local repository = require("issuehub.core.repository")
local issue_mod = require("issuehub.core.issue")

local M = {}

---@class issuehub.JsonIndex : issuehub.Index
local Json = {}
Json.__index = Json

function M.new()
  return setmetatable({ name = "json", items = nil, path = nil }, Json)
end

function Json:_path()
  if not self.path then
    self.path = repository.state("index", "issues.json")
  end
  return self.path
end

function Json:_load()
  if self.items then
    return self.items
  end
  local path = self:_path()
  self.items = {}
  if path and fs.exists(path) then
    local data = fs.read_json(path)
    if type(data) == "table" and type(data.items) == "table" then
      self.items = data.items
    end
  end
  return self.items
end

function Json:_flush()
  local path = self:_path()
  if path then
    fs.write_json(path, { version = repository.layout_version(), items = self.items or {} }, { sync = false })
  end
end

---@param issue issuehub.Issue
function Json:put(issue)
  local items = self:_load()
  local previous = items[issue.uri]
  local item = issue_mod.to_item(issue, previous and previous.bookmarked)
  -- seen_at belongs to the user, not the payload: carry it across a refresh.
  item.seen_at = previous and previous.seen_at or nil
  items[issue.uri] = item
  self:_flush()
end

---Write many at once, flushing the file once rather than per issue.
---
--- The json backend rewrites the whole file on every flush, so a per-issue
--- flush makes a bulk sync O(n²).
---@param issues issuehub.Issue[]
function Json:put_many(issues)
  local items = self:_load()
  for _, issue in ipairs(issues) do
    local previous = items[issue.uri]
    local item = issue_mod.to_item(issue, previous and previous.bookmarked)
    item.seen_at = previous and previous.seen_at or nil
    items[issue.uri] = item
  end
  self:_flush()
end

---Bookmarks live in state.yaml (tracked in Git); the index mirrors them so the
---picker can show and sort by them without reading N files.
---@param uri string
---@param value boolean
function Json:set_bookmark(uri, value)
  local items = self:_load()
  if items[uri] then
    items[uri].bookmarked = value
    self:_flush()
  end
end

---Mirror the revision the user last viewed, so "changed since I last looked"
---is a field comparison rather than N reads of state.yaml.
---@param uri string
---@param updated_at string?
function Json:set_seen(uri, updated_at)
  local items = self:_load()
  if items[uri] then
    items[uri].seen_at = updated_at
    self:_flush()
  end
end

---@param uri string
function Json:delete(uri)
  local items = self:_load()
  items[uri] = nil
  self:_flush()
end

---@param filter table?
---@return issuehub.ViewItem[]
function Json:list(filter)
  filter = filter or {}
  local out = {}
  for _, item in pairs(self:_load()) do
    local keep = true
    if filter.closed ~= nil and item.closed ~= filter.closed then
      keep = false
    end
    if keep and filter.bookmarked ~= nil and (item.bookmarked == true) ~= filter.bookmarked then
      keep = false
    end
    if keep and filter.changed ~= nil then
      local changed = item.seen_at ~= nil and item.seen_at ~= item.updated_at
      if changed ~= filter.changed then
        keep = false
      end
    end
    if keep and filter.provider then
      local provider = issue_mod.parse(item.uri)
      keep = provider == filter.provider
    end
    if keep and filter.project then
      keep = item.project == filter.project
    end
    if keep then
      out[#out + 1] = item
    end
  end
  return require("issuehub.core.index").sort(out)
end

---Substring match over the fields the index actually holds. Full-text search
---across memo and analysis history is the sqlite/FTS5 backend's job (§15).
---@param query string
---@return issuehub.ViewItem[]
function Json:search(query)
  local needle = query:lower()
  local out = {}
  for _, item in pairs(self:_load()) do
    local haystack = (item.title .. " " .. item.id .. " " .. (item.status or "")):lower()
    if haystack:find(needle, 1, true) then
      out[#out + 1] = item
    end
  end
  return require("issuehub.core.index").sort(out)
end

---Distinct projects seen, most recently active first.
---@param provider string?
---@return string[]
function Json:projects(provider)
  local latest = {}
  for _, item in ipairs(self:list({ provider = provider })) do
    if item.project and item.project ~= "" then
      local seen = latest[item.project]
      if not seen or (item.updated_at or "") > seen then
        latest[item.project] = item.updated_at or ""
      end
    end
  end

  local names = vim.tbl_keys(latest)
  table.sort(names, function(a, b)
    return latest[a] > latest[b]
  end)
  return names
end

---@return integer count
function Json:rebuild()
  local cache = require("issuehub.core.cache")
  self.items = {}
  local count = 0
  for _, uri in ipairs(repository.cached_uris()) do
    local entry = cache.get(uri)
    if entry and entry.issue then
      -- Bookmarks are user data in state.yaml, so a rebuilt index must recover
      -- them rather than silently dropping them.
      local state = require("issuehub.core.workspace").state(uri)
      local item = issue_mod.to_item(entry.issue, state.bookmarked)
      item.seen_at = state.last_seen_updated_at
      self.items[uri] = item
      count = count + 1
    end
  end
  self:_flush()
  return count
end

---@return boolean ok
---@return string msg
function Json:health()
  local path = self:_path()
  if not path then
    return false, "workspace not configured"
  end
  return true, ("json index (%d entries)"):format(vim.tbl_count(self:_load()))
end

return M
