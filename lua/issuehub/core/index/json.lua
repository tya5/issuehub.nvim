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
    fs.write_json(path, { version = repository.layout_version(), items = self.items or {} })
  end
end

---@param issue issuehub.Issue
function Json:put(issue)
  local items = self:_load()
  items[issue.uri] = issue_mod.to_item(issue, items[issue.uri] and items[issue.uri].bookmarked)
  self:_flush()
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
    if keep and filter.provider then
      local provider = issue_mod.parse(item.uri)
      keep = provider == filter.provider
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

---@return integer count
function Json:rebuild()
  local cache = require("issuehub.core.cache")
  self.items = {}
  local count = 0
  for _, uri in ipairs(repository.cached_uris()) do
    local entry = cache.get(uri)
    if entry and entry.issue then
      self.items[uri] = issue_mod.to_item(entry.issue)
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
