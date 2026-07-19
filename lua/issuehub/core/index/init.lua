---@brief Index interface and backend selection (§5.2, §5.3).
---
--- The index is a derived projection of `.state/cache/` and the Workspace. It is
--- never a source of truth, so deleting `.state/` — or switching backends — is
--- always safe.

local M = {}

---@class issuehub.Index
---@field name string
---@field put fun(self, issue: issuehub.Issue)   Also indexes the issue's notes,
---                                              where the backend supports it.
---@field put_many fun(self, issues: issuehub.Issue[])  Batched; one round trip.
---@field delete fun(self, uri: string)
---@field set_bookmark fun(self, uri: string, value: boolean)
---@field set_seen fun(self, uri: string, updated_at: string?)
---@field list fun(self, filter: table?): issuehub.ViewItem[]
---@field projects fun(self, provider: string?): string[]
---@field search fun(self, query: string): issuehub.ViewItem[]
---@field rebuild fun(self): integer
---@field health fun(self): boolean, string

---@type issuehub.Index?
local instance = nil

---@return issuehub.Index
local function build()
  local choice = require("issuehub.config").get().index
  local sqlite = require("issuehub.core.index.sqlite")

  if choice == "sqlite" then
    if sqlite.available() then
      return sqlite.new()
    end
    -- Explicitly requested but unusable: say so rather than silently degrading.
    require("issuehub.util.log").warn("index=sqlite requested but sqlite3 is unavailable; using json")
    return require("issuehub.core.index.json").new()
  end

  if choice == "auto" and sqlite.available() then
    return sqlite.new()
  end

  return require("issuehub.core.index.json").new()
end

---@return issuehub.Index
function M.get()
  if not instance then
    instance = build()
    if not instance.put_many then
      -- Third-party backends need not implement batching.
      instance.put_many = function(self, issues)
        for _, issue in ipairs(issues) do
          self:put(issue)
        end
      end
    end
  end
  return instance
end

---Drop the cached instance. Called on setup() and by tests.
function M.reset()
  instance = nil
end

---Sort items the way every list surface should: open work first, newest first.
---@param items issuehub.ViewItem[]
---@return issuehub.ViewItem[]
function M.sort(items)
  table.sort(items, function(a, b)
    if a.closed ~= b.closed then
      return not a.closed -- closed last
    end
    return (a.updated_at or "") > (b.updated_at or "")
  end)
  return items
end

return M
