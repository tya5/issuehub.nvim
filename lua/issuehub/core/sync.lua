---@brief Synchronization and change detection (§10).
---
--- Sync refreshes the cache and reports what moved. It NEVER mutates the
--- Workspace: your notes are yours, and a remote edit must not rewrite them.
--- The only state it touches is the housekeeping in `state.yaml`.

local cache = require("issuehub.core.cache")
local providers = require("issuehub.provider")
local workspace = require("issuehub.core.workspace")
local log = require("issuehub.util.log")

local M = {}

---@class issuehub.Change
---@field uri string
---@field id string
---@field title string
---@field fields string[]          Names of the fields that differ.
---@field comments_added integer
---@field previous_status string?
---@field status string?

---Fields compared field-by-field. Ordered for display.
local WATCHED = { "status", "assignee", "title", "description", "labels" }

---Fields a `partial` cache entry cannot hold, because list/search do not return
---them (§7). Comparing these against a partial baseline reports the *filling in*
---of the entry as a change — every issue at once, on the first sync after a
---fetch.
local ABSENT_FROM_PARTIAL = { description = true }

---Change detection compares the watched fields directly rather than hashing.
---
--- An earlier design used `updated_at` with a content hash as a fallback. Direct
--- comparison is both cheaper to reason about and strictly more informative: it
--- says *what* moved, which is what the report needs anyway. `updated_at` is
--- still used, but for "have I looked at this revision" (state.yaml), not for
--- detecting change.
---@param a any
---@param b any
---@return boolean
local function differs(a, b)
  if type(a) == "table" and type(b) == "table" then
    return not vim.deep_equal(a, b)
  end
  return a ~= b
end

---Compare two revisions of the same issue.
---@param old issuehub.Issue?
---@param new issuehub.Issue
---@return issuehub.Change? change  nil when nothing we report on moved.
---@param old issuehub.Issue?
---@param new issuehub.Issue
---@param opts { partial_baseline: boolean? }?  Baseline came from list/search.
---@return issuehub.Change?
function M.diff(old, new, opts)
  if not old then
    return nil -- Newly cached; not a "change" the user needs to review.
  end
  opts = opts or {}

  local fields = {}
  for _, field in ipairs(WATCHED) do
    -- A partial baseline is a real baseline for everything it actually holds.
    -- Discarding it wholesale (the previous behaviour) avoided the false
    -- positives but also silently missed a genuine status change between the
    -- list and the sync; skipping only the fields it cannot hold keeps both.
    if not (opts.partial_baseline and ABSENT_FROM_PARTIAL[field]) then
      local before = field == "status" and old.status.name or old[field]
      local after = field == "status" and new.status.name or new[field]
      if differs(before, after) then
        fields[#fields + 1] = field
      end
    end
  end

  -- Comment counts come from the provider's total where available, since the
  -- fetched list is capped (§23.3) and its length would understate the change.
  -- A partial baseline has no comment information at all, so any delta computed
  -- from it would be the whole count reported as "added".
  local added = 0
  if not opts.partial_baseline then
    local before_total = (old.raw or {}).comment_total or #(old.comments or {})
    local after_total = (new.raw or {}).comment_total or #(new.comments or {})
    added = math.max(0, (after_total or 0) - (before_total or 0))
  end

  if #fields == 0 and added == 0 then
    return nil
  end

  return {
    uri = new.uri,
    id = new.id,
    title = new.title,
    fields = fields,
    comments_added = added,
    previous_status = old.status.name,
    status = new.status.name,
  }
end

---@param change issuehub.Change
---@return string
function M.describe(change)
  local parts = {}
  for _, field in ipairs(change.fields) do
    if field == "status" then
      parts[#parts + 1] = ("status %s → %s"):format(change.previous_status, change.status)
    else
      parts[#parts + 1] = field
    end
  end
  if change.comments_added > 0 then
    parts[#parts + 1] = ("+%d comment%s"):format(change.comments_added, change.comments_added == 1 and "" or "s")
  end
  return ("%s: %s"):format(change.id, table.concat(parts, ", "))
end

---Sync one issue.
---@param uri string
---@param cb fun(err: string?, change: issuehub.Change?)
function M.one(uri, cb)
  local provider, id = providers.resolve(uri)
  if not provider then
    return cb(tostring(id))
  end

  local before = cache.get(uri)
  local old = before and before.issue or nil
  local partial_baseline = before ~= nil and before.partial == true

  provider:get(id, function(err, issue)
    if err then
      return cb(err)
    end

    local change = M.diff(old, issue, { partial_baseline = partial_baseline })
    local ok, werr = cache.put(issue)
    if not ok then
      return cb(werr)
    end

    cb(nil, change)
  end)
end

---Sync many issues, reporting progress as they land.
---
--- Requests are issued together and throttled by the HTTP layer's concurrency
--- cap, so a large sync does not need its own scheduler.
---@param uris string[]
---@param opts { on_progress: fun(done: integer, total: integer)? }?
---@param cb fun(result: { changes: issuehub.Change[], errors: table<string,string>, total: integer })
function M.many(uris, opts, cb)
  opts = opts or {}
  local total = #uris
  local changes, errors, done = {}, {}, 0

  if total == 0 then
    return cb({ changes = {}, errors = {}, total = 0 })
  end

  for _, uri in ipairs(uris) do
    M.one(uri, function(err, change)
      done = done + 1
      if err then
        errors[uri] = err
        log.warn("sync failed", uri, err)
      elseif change then
        changes[#changes + 1] = change
      end

      if opts.on_progress then
        opts.on_progress(done, total)
      end
      if done == total then
        table.sort(changes, function(a, b)
          return a.id < b.id
        end)
        cb({ changes = changes, errors = errors, total = total })
      end
    end)
  end
end

---Every URI worth syncing: everything cached, plus anything with local notes
---(which may have fallen out of the cache).
---@return string[]
function M.targets()
  local seen, uris = {}, {}
  local repository = require("issuehub.core.repository")

  for _, uri in ipairs(repository.cached_uris()) do
    if not seen[uri] then
      seen[uri], uris[#uris + 1] = true, uri
    end
  end
  for _, uri in ipairs(workspace.with_overlay()) do
    if not seen[uri] then
      seen[uri], uris[#uris + 1] = true, uri
    end
  end

  return uris
end

---Issues whose remote revision moved since the user last opened them.
---
--- Distinct from a sync report: this survives restarts and accumulates, because
--- it is derived from `state.yaml` rather than from one sync run.
---@return issuehub.ViewItem[]
function M.changed_since_seen()
  -- The index mirrors state.yaml's last-seen revision, so this is a filter
  -- rather than N reads of the Repository.
  return require("issuehub.core.index").get():list({ changed = true })
end

return M
