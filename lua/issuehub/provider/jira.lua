---@brief Jira provider. Cloud and Server/DC differences stay entirely inside
--- this file — no `flavor` concept leaks above the provider boundary (§23.1).

local adf = require("issuehub.provider.adf")
local issue_mod = require("issuehub.core.issue")
local config = require("issuehub.config")

local M = {}

---@class issuehub.JiraProvider : issuehub.Provider
local Jira = {}
Jira.__index = Jira

local FIELDS = "summary,description,status,assignee,reporter,labels,created,updated,resolutiondate"

---@param name string?  Instance name; also the URI scheme. Defaults to "jira".
function M.new(name)
  -- `http` is injectable so specs can substitute a fake transport (§20).
  return setmetatable({
    name = name or "jira",
    http = require("issuehub.util.http"),
    opts = nil,
    flavor = nil,
  }, Jira)
end

---@param opts issuehub.ProviderConfig
---@return boolean ok
---@return string? err
function Jira:setup(opts)
  if type(opts.url) ~= "string" or opts.url == "" then
    return false, ("providers.%s.url is required"):format(self.name or "jira")
  end
  self.opts = opts
  self.base = opts.url:gsub("/+$", "")
  self.flavor = opts.flavor -- nil means "detect on first use"
  self.comment_limit = opts.comment_limit or 20
  return true
end

---Cloud uses Basic auth with an email + API token; Server/DC uses a bearer PAT.
---@return issuehub.HttpAuth? auth
---@return string? err
function Jira:_auth()
  local token, err = config.token(self.name)
  if not token then
    return nil, err
  end
  if self:_is_cloud() and self.opts.user then
    return { basic = ("%s:%s"):format(self.opts.user, token) }
  end
  return { bearer = token }
end

---@return boolean
---Flavor detection is a hostname heuristic, NOT a /serverInfo probe: auth style
---and REST version must be known before the first request can be built, and a
---probe would itself need them. `*.atlassian.net` is Cloud, everything else is
---assumed Server/DC.
---
---This misclassifies Cloud instances on a vanity domain, so
---`providers.jira.flavor = "cloud"|"server"` overrides it explicitly.
---@return boolean
function Jira:_is_cloud()
  if self.flavor == nil then
    self.flavor = self.base:match("%.atlassian%.net") and "cloud" or "server"
  end
  return self.flavor == "cloud"
end

---@return string
function Jira:_api()
  return self:_is_cloud() and "/rest/api/3" or "/rest/api/2"
end

---@param path string
---@param opts table?
---@param cb fun(err: string?, body: table?)
function Jira:_call(path, opts, cb)
  opts = opts or {}
  local auth, err = self:_auth()
  if not auth then
    return cb(err)
  end

  self.http.request({
    method = opts.method or "GET",
    url = self.base .. path,
    query = opts.query,
    body = opts.body,
    auth = auth,
    headers = { Accept = "application/json" },
    -- Per-instance proxy/TLS overrides, same as the providers built on
    -- provider/util.lua.
    net = config.net(self.name),
  }, function(rerr, res)
    if rerr then
      return cb(rerr)
    end
    local body, jerr = res:json()
    if not body then
      return cb(jerr)
    end
    cb(nil, body)
  end)
end

---@param raw table
---@return issuehub.Issue
function Jira:_to_issue(raw)
  local f = raw.fields or {}
  local status = f.status or {}

  return issue_mod.normalize({
    uri = issue_mod.uri(self.name, raw.key),
    provider = self.name,
    id = raw.key,
    title = f.summary or "",
    -- Cloud returns ADF, Server returns wiki-markup text. adf.to_markdown
    -- passes strings through untouched, so one call covers both.
    description = adf.to_markdown(f.description),
    status = {
      id = status.id and tostring(status.id) or (status.name or "unknown"),
      name = status.name or "Unknown",
      -- The API states this directly; no label table to maintain (§4.1).
      closed = (status.statusCategory or {}).key == "done",
    },
    assignee = (f.assignee or {}).displayName,
    reporter = (f.reporter or {}).displayName,
    labels = f.labels or {},
    url = ("%s/browse/%s"):format(self.base, raw.key),
    created_at = f.created,
    updated_at = f.updated,
    closed_at = f.resolutiondate,
    raw = raw,
  })
end

---Fetch ONE page.
---
---Exposed so the list cache can resume where it left off; `list` and `search`
---are this in a loop.
---@param query string?   JQL; nil means the configured default.
---@param cursor any      Opaque; nil starts from the beginning.
---@param cb fun(err: string?, issues: issuehub.Issue[]?, next_cursor: any)
function Jira:page(query, cursor, cb)
  local putil = require("issuehub.provider.util")
  local _, per_page = putil.limits(self.opts)
  local jql = query or self.opts.default_query or "assignee = currentUser() AND resolution = Unresolved"

  -- Cloud pages with an opaque nextPageToken; Server/DC with startAt.
  local cloud = self:_is_cloud()
  local path = cloud and (self:_api() .. "/search/jql") or (self:_api() .. "/search")

  local params = { jql = jql, maxResults = per_page, fields = FIELDS }
  if cloud then
    params.nextPageToken = cursor
  else
    params.startAt = cursor or 0
  end

  self:_call(path, { query = params }, function(err, body)
    if err then
      return cb(err)
    end
    local raw_issues = (body or {}).issues or {}
    local issues = {}
    for _, raw in ipairs(raw_issues) do
      issues[#issues + 1] = self:_to_issue(raw)
    end

    local next_cursor
    if #raw_issues >= per_page then
      -- An absent token means this was the last page, whatever the count says.
      next_cursor = cloud and (body and body.nextPageToken or nil) or ((cursor or 0) + #raw_issues)
    end
    cb(nil, issues, next_cursor)
  end)
end

---@param jql string
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function Jira:_search_jql(jql, cb)
  local putil = require("issuehub.provider.util")
  local max, per_page = putil.limits(self.opts)
  putil.paginate({
    max = max,
    per_page = per_page,
    fetch = function(cursor, done)
      self:page(jql, cursor, done)
    end,
  }, cb)
end

---@param query string?
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function Jira:list(query, cb)
  local jql = query or self.opts.default_query or "assignee = currentUser() AND resolution = Unresolved"
  self:_search_jql(jql, cb)
end

---Passed through as JQL rather than translated from a cross-provider DSL (§7).
---@param query string
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function Jira:search(query, cb)
  self:_search_jql(query, cb)
end

---@param id string
---@param cb fun(err: string?, issue: issuehub.Issue?)
function Jira:get(id, cb)
  self:_call(self:_api() .. "/issue/" .. id, { query = { fields = FIELDS } }, function(err, body)
    if err then
      return cb(err)
    end
    local issue = self:_to_issue(body)

    -- Comments are fetched separately and capped: pulling hundreds is slow on
    -- the wire and bloats the cache (§23.3).
    self:_call(self:_api() .. "/issue/" .. id .. "/comment", {
      query = { maxResults = self.comment_limit, orderBy = "-created" },
    }, function(cerr, cbody)
      if not cerr and cbody then
        local comments = {}
        for _, c in ipairs(cbody.comments or {}) do
          comments[#comments + 1] = {
            id = tostring(c.id),
            author = (c.author or {}).displayName,
            body = adf.to_markdown(c.body),
            created_at = issue_mod.timestamp(c.created),
          }
        end
        issue.comments = comments
        issue.raw.comment_total = cbody.total
      end
      cb(nil, issue)
    end)
  end)
end

---@return boolean ok
---@return string msg
function Jira:health()
  if not self.opts then
    return false, "not configured"
  end
  local ok, msg = config.token_status(self.name)
  if not ok then
    return false, msg
  end
  return true, ("%s (%s), credential %s"):format(self.base, self.flavor or "auto", msg)
end

return M
