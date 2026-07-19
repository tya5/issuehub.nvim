---@brief Collections: named, local, cross-provider issue sets (§13).
---
--- Static lists of URIs, stored as YAML under `.issuehub/collections/` and
--- tracked in Git. Query-backed (dynamic) collections are deliberately deferred:
--- a static list is diffable and predictable, and "why is this issue in here"
--- always has a literal answer.

local fs = require("issuehub.util.fs")
local repository = require("issuehub.core.repository")
local yaml = require("issuehub.util.yaml")

local M = {}

---@class issuehub.Collection
---@field name string
---@field slug string
---@field description string?
---@field issues string[]

---@param name string
---@return string
function M.slug(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return slug ~= "" and slug or "collection"
end

---@param slug string
---@return string? path
local function path_of(slug)
  local dir = repository.meta("collections")
  return dir and vim.fs.joinpath(dir, slug .. ".yaml") or nil
end

---@return string[] slugs
function M.list()
  local dir = repository.meta("collections")
  if not dir or not fs.is_dir(dir) then
    return {}
  end
  local slugs = {}
  for _, file in ipairs(fs.list(dir)) do
    local slug = file:match("^(.+)%.yaml$")
    if slug then
      slugs[#slugs + 1] = slug
    end
  end
  table.sort(slugs)
  return slugs
end

---@param name_or_slug string
---@return issuehub.Collection?
function M.get(name_or_slug)
  local slug = M.slug(name_or_slug)
  local path = path_of(slug)
  if not path or not fs.exists(path) then
    return nil
  end

  local parsed = yaml.parse(fs.read(path))
  local issues = parsed.issues
  -- A single-entry list parses as a scalar in some hand-written files.
  if type(issues) == "string" then
    issues = issues ~= "" and { issues } or {}
  end

  return {
    name = parsed.name or name_or_slug,
    slug = slug,
    description = parsed.description ~= "" and parsed.description or nil,
    issues = issues or {},
  }
end

---@param collection issuehub.Collection
---@return boolean ok
---@return string? err
function M.save(collection)
  local slug = collection.slug or M.slug(collection.name)
  local path = path_of(slug)
  if not path then
    return false, "workspace not configured"
  end

  local payload = { name = collection.name, issues = collection.issues or {} }
  if collection.description then
    payload.description = collection.description
  end
  return fs.write(path, yaml.encode(payload))
end

---@param name string
---@param uri string
---@return boolean added  false when it was already a member.
function M.add(name, uri)
  local collection = M.get(name) or { name = name, slug = M.slug(name), issues = {} }
  if vim.tbl_contains(collection.issues, uri) then
    return false
  end
  collection.issues[#collection.issues + 1] = uri
  -- Sorted so a collection edited from two machines diffs cleanly.
  table.sort(collection.issues)
  M.save(collection)
  return true
end

---@param name string
---@param uri string
---@return boolean removed
function M.remove(name, uri)
  local collection = M.get(name)
  if not collection then
    return false
  end
  local kept = vim.tbl_filter(function(member)
    return member ~= uri
  end, collection.issues)
  if #kept == #collection.issues then
    return false
  end
  collection.issues = kept
  M.save(collection)
  return true
end

---@param name string
---@return boolean deleted
function M.delete(name)
  local path = path_of(M.slug(name))
  if not path or not fs.exists(path) then
    return false
  end
  vim.uv.fs_unlink(path)
  return true
end

---Build a View over a collection's members.
---
--- Members that are no longer cached are still listed, with what is known from
--- the URI alone: a collection is the user's list, and silently dropping entries
--- because a cache expired would be wrong.
---@param name string
---@return issuehub.View?
function M.to_view(name)
  local collection = M.get(name)
  if not collection then
    return nil
  end

  local index = require("issuehub.core.index").get()
  local known = {}
  for _, item in ipairs(index:list()) do
    known[item.uri] = item
  end

  local items = {}
  for _, uri in ipairs(collection.issues) do
    items[#items + 1] = known[uri]
      or {
        uri = uri,
        id = select(2, require("issuehub.core.issue").parse(uri)) or uri,
        title = "(not cached — run :IssueHub sync)",
        status = "",
        closed = false,
        updated_at = "",
        bookmarked = false,
      }
  end

  return require("issuehub.ui.view").new({
    source = "collection",
    label = collection.name,
    items = items,
  })
end

---Collections containing a URI. Used to show membership in the issue buffer.
---@param uri string
---@return string[] names
function M.containing(uri)
  local names = {}
  for _, slug in ipairs(M.list()) do
    local collection = M.get(slug)
    if collection and vim.tbl_contains(collection.issues, uri) then
      names[#names + 1] = collection.name
    end
  end
  return names
end

return M
