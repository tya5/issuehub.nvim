---@brief Redmine provider.
---
--- Auth is the `X-Redmine-API-Key` header, which travels in the curl config on
--- stdin like every other credential.

local issue_mod = require("issuehub.core.issue")
local putil = require("issuehub.provider.util")
local log = require("issuehub.util.log")

local M = {}

---@class issuehub.RedmineProvider : issuehub.Provider
local Redmine = {}
Redmine.__index = Redmine

---@param name string?  Instance name; also the URI scheme.
function M.new(name)
  return setmetatable({
    name = name or "redmine",
    http = require("issuehub.util.http"),
    opts = nil,
    ---Maps status id -> is_closed, fetched once from /issue_statuses.json.
    status_closed = nil,
  }, Redmine)
end

---@param opts issuehub.ProviderConfig
---@return boolean ok
---@return string? err
function Redmine:setup(opts)
  if type(opts.url) ~= "string" or opts.url == "" then
    return false, ("providers.%s.url is required"):format(self.name)
  end
  self.opts = opts
  self.base = putil.base_url(opts.url)
  self.comment_limit = opts.comment_limit or 20
  return true
end

---@return issuehub.ProviderCtx
function Redmine:_ctx()
  return {
    name = self.name,
    base = self.base,
    http = self.http,
    auth = function(token)
      return { headers = { ["X-Redmine-API-Key"] = token } }
    end,
  }
end

---Redmine's issue payload carries `status.is_closed` only on newer versions, so
--- /issue_statuses.json is fetched once and cached as the authoritative map.
--- Without it we would be guessing from status names, which are per-instance
--- configurable — exactly the guessing §4.1 exists to avoid.
---@param cb fun()
function Redmine:_ensure_statuses(cb)
  if self.status_closed then
    return cb()
  end
  putil.call(self:_ctx(), "/issue_statuses.json", nil, function(err, body)
    self.status_closed = {}
    if err then
      -- Non-fatal: fall back to the per-issue is_closed field when present.
      log.warn(self.name .. ": could not fetch issue statuses:", err)
    else
      for _, s in ipairs((body or {}).issue_statuses or {}) do
        self.status_closed[tostring(s.id)] = s.is_closed == true
      end
    end
    cb()
  end)
end

---@param raw table
---@return issuehub.Issue
function Redmine:_to_issue(raw)
  local status = raw.status or {}
  local id = tostring(status.id or "")

  local closed
  if status.is_closed ~= nil then
    closed = status.is_closed == true
  else
    closed = (self.status_closed or {})[id] == true
  end

  local comments = {}
  for _, journal in ipairs(raw.journals or {}) do
    -- Journals include pure field-change records with no note; those are an
    -- audit trail, not a comment.
    if journal.notes and journal.notes ~= "" then
      comments[#comments + 1] = {
        id = tostring(journal.id),
        author = (journal.user or {}).name,
        body = journal.notes,
        created_at = issue_mod.timestamp(journal.created_on),
      }
    end
  end

  local labels = {}
  if raw.tracker and raw.tracker.name then
    labels[#labels + 1] = raw.tracker.name
  end
  if raw.priority and raw.priority.name then
    labels[#labels + 1] = raw.priority.name
  end

  return issue_mod.normalize({
    provider = self.name,
    -- Redmine ids carry no project, so it has to come from the payload.
    project = (raw.project or {}).identifier or (raw.project or {}).name,
    id = tostring(raw.id),
    title = raw.subject or "",
    -- Redmine bodies are Textile or Markdown depending on an instance setting.
    -- Passed through untouched: converting Textile would be a guess, and the
    -- text is readable either way.
    description = raw.description or "",
    status = { id = id, name = status.name or "Unknown", closed = closed },
    assignee = (raw.assigned_to or {}).name,
    reporter = (raw.author or {}).name,
    labels = labels,
    url = ("%s/issues/%s"):format(self.base, raw.id),
    created_at = raw.created_on,
    updated_at = raw.updated_on,
    closed_at = raw.closed_on,
    comments = comments,
    raw = raw,
  })
end

---@param query table|string|nil
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function Redmine:list(query, cb)
  local params = query or self.opts.default_query or { assigned_to_id = "me", status_id = "open" }
  if type(params) == "string" then
    -- Accept "status_id=open&assigned_to_id=me" for symmetry with the other
    -- providers' string queries.
    local parsed = {}
    for k, v in params:gmatch("([^&=]+)=([^&]*)") do
      parsed[k] = v
    end
    params = parsed
  end

  local max, per_page = putil.limits(self.opts)

  self:_ensure_statuses(function()
    putil.paginate({
      max = max,
      per_page = per_page,
      fetch = function(cursor, done)
        -- Redmine pages by offset.
        local offset = cursor or 0
        local q = vim.tbl_extend("force", { limit = per_page, offset = offset }, params)
        putil.call(self:_ctx(), "/issues.json", { query = q }, function(err, body)
          if err then
            return done(err)
          end
          local raw_issues = (body or {}).issues or {}
          local issues = {}
          for _, raw in ipairs(raw_issues) do
            issues[#issues + 1] = self:_to_issue(raw)
          end
          done(nil, issues, offset + #raw_issues)
        end)
      end,
    }, cb)
  end)
end

---@param query string
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function Redmine:search(query, cb)
  self:_ensure_statuses(function()
    putil.call(self:_ctx(), "/search.json", {
      query = { q = query, issues = 1, limit = 100 },
    }, function(err, body)
      if err then
        return cb(err)
      end
      -- /search.json returns thin records, so each hit is re-fetched to produce
      -- a canonical Issue rather than a half-populated one.
      local results = (body or {}).results or {}
      local issues, pending = {}, #results
      if pending == 0 then
        return cb(nil, {})
      end
      for _, hit in ipairs(results) do
        self:get(tostring(hit.id), function(gerr, issue)
          if not gerr and issue then
            issues[#issues + 1] = issue
          end
          pending = pending - 1
          if pending == 0 then
            cb(nil, issues)
          end
        end)
      end
    end)
  end)
end

---@param id string
---@param cb fun(err: string?, issue: issuehub.Issue?)
function Redmine:get(id, cb)
  self:_ensure_statuses(function()
    putil.call(self:_ctx(), ("/issues/%s.json"):format(putil.path_segment(id)), {
      query = { include = "journals" },
    }, function(err, body)
      if err then
        return cb(err)
      end
      local raw = (body or {}).issue
      if not raw then
        return cb(("redmine: no issue %s in response"):format(id))
      end

      local issue = self:_to_issue(raw)
      -- Redmine returns every journal entry; cap to the newest N for parity
      -- with the other providers (§23.3).
      local total = #issue.comments
      if total > self.comment_limit then
        issue.comments = vim.list_slice(issue.comments, total - self.comment_limit + 1, total)
      end
      issue.raw.comment_total = total
      cb(nil, issue)
    end)
  end)
end

---@return boolean ok
---@return string msg
function Redmine:health()
  if not self.opts then
    return false, "not configured"
  end
  return putil.health(self:_ctx())
end

return M
