---@brief The ONLY module that knows about on-disk paths (§0.1, §5).
---
--- Everything else speaks in URIs. Keeping path knowledge here is what lets the
--- Repository layout change in a future minor version without breaking the
--- Workspace API.

local fs = require("issuehub.util.fs")
local issue = require("issuehub.core.issue")

local M = {}

local LAYOUT_VERSION = "2"

local GITIGNORE = [[
# Derived state: cache, index, locks. Safe to delete at any time.
/.state/
]]

---@return string? root
---@return string? err
function M.root()
  local workspace = require("issuehub.config").get().workspace
  if not workspace or workspace == "" then
    return nil, "issuehub: `workspace` is not configured — set it in setup()"
  end
  return workspace
end

---@param ... string
---@return string? path
---@return string? err
local function under(...)
  local root, err = M.root()
  if not root then
    return nil, err
  end
  return vim.fs.joinpath(root, ...)
end

---Everything derived lives here and is git-ignored (§5).
---@return string? path
---@return string? err
function M.state(...)
  return under(".state", ...)
end

---@return string? path
---@return string? err
function M.meta(...)
  return under(".issuehub", ...)
end

---Directory holding the Workspace overlay for a URI.
---
--- The percent-encoded id is used verbatim as the directory name so the tree
--- stays readable in oil.nvim, git diffs, and grep (§5.4).
---@param uri string
---@return string? path
---@return string? err
function M.issue_dir(uri)
  local provider, id = issue.parse(uri)
  if not provider then
    return nil, ("not a valid issue URI: %s"):format(tostring(uri))
  end
  return under(provider, issue.encode_id(id))
end

---A subject is anything that can carry notes and analyses: an issue URI, or
---`collection:<slug>`.
---
--- Introduced so a collection can hold a prompt and an analysis history exactly
--- like an issue does. Everything downstream — overlay, analysis, the
--- conversation window — works on subjects rather than only on issues.
---@param subject string
---@return string? path
---@return string? err
function M.subject_dir(subject)
  local slug = subject:match("^collection:(.+)$")
  if slug then
    return M.meta("collections", slug)
  end
  return M.issue_dir(subject)
end

---@param subject string
---@return boolean
function M.is_collection(subject)
  return subject:match("^collection:") ~= nil
end

---@param uri string
---@return string? path
---@return string? err
function M.cache_file(uri)
  local provider, id = issue.parse(uri)
  if not provider then
    return nil, ("not a valid issue URI: %s"):format(tostring(uri))
  end
  return M.state("cache", provider, issue.encode_id(id) .. ".json")
end

---Cached lowercase -> encoded name maps, one per provider cache directory.
---
--- Without this, every cache write scanned the whole directory, which is O(n)
--- per write and therefore O(n²) for a bulk sync. At twenty thousand issues
--- that is the difference between a pause and a hang.
---@type table<string, table<string, string>>
local case_index = {}

---Drop the memo. Called when the Repository root changes.
function M.forget_case_index()
  case_index = {}
end

---@param provider string
---@param dir string
---@return table<string, string>
local function names_of(provider, dir)
  if case_index[dir] then
    return case_index[dir]
  end
  local names = {}
  if fs.is_dir(dir) then
    for _, name in ipairs(fs.list(dir)) do
      local encoded = name:match("^(.+)%.json$")
      if encoded then
        names[encoded:lower()] = encoded
      end
    end
  end
  case_index[dir] = names
  return names
end

---Detect two issue IDs that differ only by case.
---
--- On case-insensitive filesystems (macOS by default) `jira://PROJ-1` and
--- `jira://proj-1` would otherwise silently share one cache file and one issue
--- directory, merging two different issues' notes. Reported as an error rather
--- than merged.
---@param uri string
---@return boolean ok
---@return string? err
function M.check_case_collision(uri)
  local provider, id = issue.parse(uri)
  if not provider then
    return false, ("not a valid issue URI: %s"):format(tostring(uri))
  end

  local dir = M.state("cache", provider)
  if not dir then
    return true
  end

  local encoded = issue.encode_id(id)
  local names = names_of(provider, dir)
  local existing = names[encoded:lower()]

  if existing and existing ~= encoded then
    return false,
      ("issue id case collision: '%s' and '%s' map to the same path on a case-insensitive filesystem"):format(
        issue.decode_id(existing),
        id
      )
  end

  -- Remember it, so the next write in this batch does not rescan.
  names[encoded:lower()] = encoded
  return true
end

---Create the Repository skeleton if absent. Idempotent.
---@return boolean ok
---@return string? err
function M.ensure()
  local root, err = M.root()
  if not root then
    return false, err
  end

  local ok, merr = fs.mkdirp(root)
  if not ok then
    return false, ("cannot create workspace %s: %s"):format(root, tostring(merr))
  end

  fs.mkdirp(M.meta("collections"))
  fs.mkdirp(M.state("cache"))
  fs.mkdirp(M.state("index"))
  fs.mkdirp(M.state("lock"))

  local version_file = M.meta("version")
  if not fs.exists(version_file) then
    fs.write(version_file, LAYOUT_VERSION .. "\n")
  end

  -- Without this, `.state/` would be committed on the first `git add -A`.
  local gitignore = vim.fs.joinpath(root, ".gitignore")
  if not fs.exists(gitignore) then
    fs.write(gitignore, GITIGNORE)
  end

  return true
end

---@return string? version
function M.version()
  local content = fs.read(M.meta("version") or "")
  return content and vim.trim(content) or nil
end

---@return string
function M.layout_version()
  return LAYOUT_VERSION
end

---URIs that have a Workspace directory, as a set.
---
--- Two readdirs instead of three failed file opens per issue. At twenty
--- thousand issues, of which a handful have notes, that is the difference
--- between sixty thousand syscalls and two.
---@return table<string, boolean>
function M.workspace_uris()
  local root = M.root()
  local set = {}
  if not root or not fs.is_dir(root) then
    return set
  end

  for _, provider in ipairs(fs.list(root)) do
    if not provider:match("^%.") and fs.is_dir(vim.fs.joinpath(root, provider)) then
      for _, encoded in ipairs(fs.list(vim.fs.joinpath(root, provider))) do
        set[("%s://%s"):format(provider, encoded)] = true
      end
    end
  end
  return set
end

---List every URI that has a cache entry. Used to rebuild the index.
---@return string[]
function M.cached_uris()
  local uris = {}
  local cache_root = M.state("cache")
  if not cache_root or not fs.is_dir(cache_root) then
    return uris
  end
  for _, provider in ipairs(fs.list(cache_root)) do
    local dir = vim.fs.joinpath(cache_root, provider)
    if fs.is_dir(dir) then
      for _, name in ipairs(fs.list(dir)) do
        local encoded = name:match("^(.+)%.json$")
        if encoded then
          uris[#uris + 1] = ("%s://%s"):format(provider, encoded)
        end
      end
    end
  end
  return uris
end

return M
