---@brief Workspace: the logical model (§0.1).
---
--- Issue (from cache) + Overlay (local knowledge) + State (bookmarks and
--- last-seen markers), assembled in memory. Knows nothing about paths — that is
--- repository.lua's job — and nothing about buffers.

local cache = require("issuehub.core.cache")
local overlay = require("issuehub.core.overlay")
local repository = require("issuehub.core.repository")
local fs = require("issuehub.util.fs")
local yaml = require("issuehub.util.yaml")
local lock = require("issuehub.core.lock")

local M = {}

---@class issuehub.State
---@field bookmarked boolean
---@field last_opened_at string?
---@field last_seen_updated_at string?  The issue's updated_at when last viewed.

---@class issuehub.Workspace
---@field uri string
---@field issue issuehub.Issue?
---@field entry issuehub.CacheEntry?
---@field overlay issuehub.Overlay
---@field state issuehub.State

---@param uri string
---@return string? path
local function state_path(uri)
  local dir = repository.subject_dir(uri)
  return dir and vim.fs.joinpath(dir, "state.yaml") or nil
end

---@param uri string
---@return issuehub.State
function M.state(uri)
  local path = state_path(uri)
  local parsed = path and fs.exists(path) and yaml.parse(fs.read(path)) or {}
  return {
    bookmarked = parsed.bookmarked == true,
    last_opened_at = parsed.last_opened_at,
    last_seen_updated_at = parsed.last_seen_updated_at,
  }
end

---state.yaml is tracked in Git: it records user-meaningful facts (this issue is
---bookmarked, I last looked at it at this revision), not derived data.
---@param uri string
---@param state issuehub.State
---@return boolean ok
---@return string? err
function M.set_state(uri, state)
  local path = state_path(uri)
  if not path then
    return false, ("cannot resolve a path for %s"):format(uri)
  end

  -- Read-modify-write: without the lock, two processes each merging their own
  -- field into the same file means the later write drops the earlier one, and
  -- nothing anywhere reports it.
  local ok, err = lock.with("subject", uri, "workspace.set_state", function()
    return M._set_state_locked(path, uri, state)
  end)
  return ok == true, err
end

---@param path string
---@param uri string
---@param state issuehub.State
---@return boolean ok
---@return string? err
function M._set_state_locked(path, uri, state)
  local merged = vim.tbl_extend("force", M.state(uri), state)

  -- Don't create a file just to record `bookmarked: false` with nothing else in
  -- it; an absent file already means that.
  if not merged.bookmarked and not merged.last_opened_at and not merged.last_seen_updated_at then
    if fs.exists(path) then
      vim.uv.fs_unlink(path)
    end
    return true
  end

  return fs.write(path, yaml.encode(merged))
end

---@param uri string
---@return issuehub.Workspace
function M.get(uri)
  local entry = cache.get(uri)
  return {
    uri = uri,
    entry = entry,
    issue = entry and entry.issue or nil,
    overlay = overlay.read(uri),
    state = M.state(uri),
  }
end

---Record that the user opened this issue, and at which revision.
---
--- `last_seen_updated_at` is what makes "changed since I last looked" possible
--- in 0.3 without diffing the whole payload.
---@param uri string
function M.touch(uri)
  local entry = cache.get(uri)
  local seen = entry and entry.issue and entry.issue.updated_at or nil
  M.set_state(uri, {
    last_opened_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    last_seen_updated_at = seen,
  })
  require("issuehub.core.index").get():set_seen(uri, seen)
end

---@param uri string
---@return boolean bookmarked  The new value.
function M.toggle_bookmark(uri)
  -- The read and the write are one operation: read-then-set without holding
  -- the lock across both is a toggle that can lose a concurrent one. The lock
  -- is re-entrant, so set_state taking it again inside is free.
  local value
  lock.with("subject", uri, "workspace.toggle_bookmark", function()
    value = not M.state(uri).bookmarked
    M.set_state(uri, { bookmarked = value })
  end)
  if value == nil then
    return M.state(uri).bookmarked
  end
  require("issuehub.core.index").get():set_bookmark(uri, value)
  return value
end

---Whether the issue changed on the remote since the user last opened it.
---@param uri string
---@return boolean
function M.changed_since_seen(uri)
  local state = M.state(uri)
  if not state.last_seen_updated_at then
    return false
  end
  local entry = cache.get(uri)
  if not entry or not entry.issue then
    return false
  end
  return entry.issue.updated_at ~= state.last_seen_updated_at
end

---Every URI that has local content, whether or not it is still cached.
---
--- Walks the Repository rather than the index, because the overlay is the part
--- the user authored: it must remain findable even if `.state/` was deleted.
---@return string[]
function M.with_overlay()
  local root = repository.root()
  if not root or not fs.is_dir(root) then
    return {}
  end

  local uris = {}
  for _, provider in ipairs(fs.list(root)) do
    -- Skip dotted entries: .issuehub, .state, .git.
    if not provider:match("^%.") and fs.is_dir(vim.fs.joinpath(root, provider)) then
      for _, encoded in ipairs(fs.list(vim.fs.joinpath(root, provider))) do
        local dir = vim.fs.joinpath(root, provider, encoded)
        if fs.is_dir(dir) then
          uris[#uris + 1] = ("%s://%s"):format(provider, encoded)
        end
      end
    end
  end
  return uris
end

return M
