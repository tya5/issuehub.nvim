---@brief GitHub Issues provider (github.com and GitHub Enterprise Server).
---
--- Issue IDs are repository-qualified: `owner/repo#123`. GitHub numbers issues
--- and pull requests in one shared sequence per repository, so that reference is
--- unambiguous even though pull requests are included.

local issue_mod = require("issuehub.core.issue")
local putil = require("issuehub.provider.util")

local M = {}

---@class issuehub.GitHubProvider : issuehub.Provider
local GitHub = {}
GitHub.__index = GitHub

---@param name string?  Instance name; also the URI scheme.
function M.new(name)
  return setmetatable({
    name = name or "github",
    http = require("issuehub.util.http"),
    opts = nil,
  }, GitHub)
end

---@param opts issuehub.ProviderConfig
---@return boolean ok
---@return string? err
function GitHub:setup(opts)
  self.opts = opts or {}
  -- Enterprise Server lives at https://ghe.example.com/api/v3; github.com's API
  -- is on a separate host from the web UI, hence the two URLs.
  self.base = putil.base_url(self.opts.url or "https://api.github.com")
  self.web = putil.base_url(
    self.opts.web_url
      or (self.base:match("^https://api%.github%.com$") and "https://github.com" or self.base:gsub("/api/v3$", ""))
  )
  self.comment_limit = self.opts.comment_limit or 20
  return true
end

---@return issuehub.ProviderCtx
function GitHub:_ctx()
  return {
    name = self.name,
    base = self.base,
    http = self.http,
    auth = function(token)
      return {
        auth = { bearer = token },
        headers = { Accept = "application/vnd.github+json", ["X-GitHub-Api-Version"] = "2022-11-28" },
      }
    end,
  }
end

---@param id string  "owner/repo#123"
---@return string? owner_repo
---@return string? number
local function split_id(id)
  local repo, number = id:match("^(.+)#(%d+)$")
  if not repo then
    return nil, nil
  end
  return repo, number
end

---GitHub reports issue state as open/closed, and pull requests additionally as
---merged or draft. `closed` follows state; the display name carries the nuance.
---@param raw table
---@return issuehub.Status
local function status_of(raw)
  local is_pr = raw.pull_request ~= nil or raw.merged_at ~= nil
  local state = raw.state or "open"

  if is_pr then
    if raw.merged_at then
      return { id = "merged", name = "Merged", closed = true }
    end
    if raw.draft then
      return { id = "draft", name = "Draft", closed = false }
    end
    return { id = state, name = state == "closed" and "Closed" or "Open", closed = state == "closed" }
  end

  if state == "closed" then
    -- "not planned" is materially different from "done" when reading a list.
    local name = raw.state_reason == "not_planned" and "Closed (not planned)" or "Closed"
    return { id = raw.state_reason or "closed", name = name, closed = true }
  end
  return { id = "open", name = "Open", closed = false }
end

---@param raw table
---@return issuehub.Issue
function GitHub:_to_issue(raw)
  -- On /issues the repository is only identifiable from repository_url.
  local repo = raw.repository and raw.repository.full_name
    or (raw.repository_url and raw.repository_url:match("/repos/(.+)$"))
    or (raw.html_url and raw.html_url:match("^https?://[^/]+/([^/]+/[^/]+)/"))
    or "unknown/unknown"

  local labels = {}
  for _, label in ipairs(raw.labels or {}) do
    labels[#labels + 1] = type(label) == "table" and label.name or tostring(label)
  end

  local assignee
  if raw.assignee then
    assignee = raw.assignee.login
  elseif raw.assignees and raw.assignees[1] then
    assignee = raw.assignees[1].login
  end

  return issue_mod.normalize({
    provider = self.name,
    id = ("%s#%s"):format(repo, raw.number),
    title = raw.title or "",
    description = raw.body or "", -- already Markdown
    status = status_of(raw),
    assignee = assignee,
    reporter = (raw.user or {}).login,
    labels = labels,
    url = raw.html_url,
    created_at = raw.created_at,
    updated_at = raw.updated_at,
    raw = raw,
  })
end

---@param query string?
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function GitHub:list(query, cb)
  if query or self.opts.default_query then
    return self:search(query or self.opts.default_query, cb)
  end

  -- /issues spans every repository the user can see, which is the closest
  -- equivalent to Jira's "assigned to me" default.
  putil.call(self:_ctx(), "/issues", {
    query = { filter = "assigned", state = "open", per_page = 100 },
  }, function(err, body)
    if err then
      return cb(err)
    end
    local issues = {}
    for _, raw in ipairs(body or {}) do
      issues[#issues + 1] = self:_to_issue(raw)
    end
    cb(nil, issues)
  end)
end

---Passed through as a GitHub search qualifier string, not translated (§7).
---@param query string
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function GitHub:search(query, cb)
  putil.call(self:_ctx(), "/search/issues", {
    query = { q = query, per_page = 100 },
    headers = { Accept = "application/vnd.github.text-match+json" },
  }, function(err, body)
    if err then
      return cb(err)
    end
    local issues = {}
    for _, raw in ipairs((body or {}).items or {}) do
      issues[#issues + 1] = self:_to_issue(raw)
    end
    cb(nil, issues)
  end)
end

---@param id string  "owner/repo#123"
---@param cb fun(err: string?, issue: issuehub.Issue?)
function GitHub:get(id, cb)
  local repo, number = split_id(id)
  if not repo then
    return cb(("%s: id must be owner/repo#number (got '%s')"):format(self.name, id))
  end

  putil.call(self:_ctx(), ("/repos/%s/issues/%s"):format(repo, number), nil, function(err, raw)
    if err then
      return cb(err)
    end
    local issue = self:_to_issue(raw)

    if (raw.comments or 0) == 0 then
      issue.raw.comment_total = 0
      return cb(nil, issue)
    end

    -- Newest N: ask for the last page rather than the first (§23.3).
    local total = raw.comments
    local page = math.max(1, math.ceil(total / self.comment_limit))
    putil.call(self:_ctx(), ("/repos/%s/issues/%s/comments"):format(repo, number), {
      query = { per_page = self.comment_limit, page = page },
    }, function(cerr, comments)
      if not cerr and comments then
        local out = {}
        for _, c in ipairs(comments) do
          out[#out + 1] = {
            id = tostring(c.id),
            author = (c.user or {}).login,
            body = c.body or "",
            created_at = issue_mod.timestamp(c.created_at),
          }
        end
        issue.comments = out
      end
      issue.raw.comment_total = total
      cb(nil, issue)
    end)
  end)
end

---@return boolean ok
---@return string msg
function GitHub:health()
  if not self.opts then
    return false, "not configured"
  end
  return putil.health(self:_ctx())
end

return M
