---@brief GitLab Issues provider (gitlab.com and self-managed).
---
--- Issue IDs are project-qualified: `group/project#12`, using the project path
--- and the per-project `iid` rather than GitLab's global issue id — the pair is
--- what appears in the UI and in `references.full`.

local issue_mod = require("issuehub.core.issue")
local putil = require("issuehub.provider.util")

local M = {}

---@class issuehub.GitLabProvider : issuehub.Provider
local GitLab = {}
GitLab.__index = GitLab

---@param name string?  Instance name; also the URI scheme.
function M.new(name)
  return setmetatable({
    name = name or "gitlab",
    http = require("issuehub.util.http"),
    opts = nil,
  }, GitLab)
end

---@param opts issuehub.ProviderConfig
---@return boolean ok
---@return string? err
function GitLab:setup(opts)
  self.opts = opts or {}
  local root = putil.base_url(self.opts.url or "https://gitlab.com")
  self.web = root
  self.base = root .. "/api/v4"
  self.comment_limit = self.opts.comment_limit or 20
  return true
end

---@return issuehub.ProviderCtx
function GitLab:_ctx()
  return {
    name = self.name,
    base = self.base,
    http = self.http,
    auth = function(token)
      -- PRIVATE-TOKEN accepts both personal and project access tokens; it goes
      -- into the curl config on stdin like any other credential.
      return { headers = { ["PRIVATE-TOKEN"] = token } }
    end,
  }
end

---@param id string  "group/project#12"
---@return string? project
---@return string? iid
local function split_id(id)
  local project, iid = id:match("^(.+)#(%d+)$")
  if not project then
    return nil, nil
  end
  return project, iid
end

---@param raw table
---@return issuehub.Issue
function GitLab:_to_issue(raw)
  local refs = raw.references or {}
  local project = refs.full and refs.full:match("^(.+)#%d+$")
  if not project and raw.web_url then
    -- web_url is .../group/project/-/issues/12
    project = raw.web_url:match("^https?://[^/]+/(.+)/%-/issues/%d+$")
  end
  project = project or tostring(raw.project_id or "unknown")

  local state = raw.state or "opened"
  local closed = state == "closed"

  return issue_mod.normalize({
    provider = self.name,
    project = project,
    id = ("%s#%s"):format(project, raw.iid),
    title = raw.title or "",
    description = raw.description or "", -- already Markdown
    status = {
      id = state,
      -- GitLab says "opened"; every other surface in this plugin says "Open".
      name = closed and "Closed" or "Open",
      closed = closed,
    },
    assignee = (raw.assignee or {}).name or (raw.assignees or {})[1] and raw.assignees[1].name or nil,
    reporter = (raw.author or {}).name,
    labels = raw.labels or {},
    url = raw.web_url,
    created_at = raw.created_at,
    updated_at = raw.updated_at,
    closed_at = raw.closed_at,
    raw = raw,
  })
end

---Fetch ONE page. `list` and `search` are this in a loop.
---@param query table|string|nil
---@param cursor any   Page number; nil starts at 1.
---@param cb fun(err: string?, issues: issuehub.Issue[]?, next_cursor: any)
function GitLab:page(query, cursor, cb)
  local _, per_page = putil.limits(self.opts)
  local page = cursor or 1

  local params = query or self.opts.default_query or { scope = "assigned_to_me", state = "opened" }
  if type(params) == "string" then
    params = { search = params, scope = "all" }
  end

  putil.call(self:_ctx(), "/issues", {
    query = vim.tbl_extend("force", { per_page = per_page, page = page }, params),
  }, function(err, body)
    if err then
      return cb(err)
    end
    local issues = {}
    for _, raw in ipairs(body or {}) do
      issues[#issues + 1] = self:_to_issue(raw)
    end
    cb(nil, issues, #(body or {}) >= per_page and (page + 1) or nil)
  end)
end

---@param query table|string|nil
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function GitLab:list(query, cb)
  local max, per_page = putil.limits(self.opts)
  putil.paginate({
    max = max,
    per_page = per_page,
    fetch = function(cursor, done)
      self:page(query, cursor, done)
    end,
  }, cb)
end

---Full-text search across issues the token can see.
---@param query string
---@param cb fun(err: string?, issues: issuehub.Issue[]?)
function GitLab:search(query, cb)
  self:list(query, cb)
end

---@param id string  "group/project#12"
---@param cb fun(err: string?, issue: issuehub.Issue?)
function GitLab:get(id, cb)
  local project, iid = split_id(id)
  if not project then
    return cb(("%s: id must be group/project#iid (got '%s')"):format(self.name, id))
  end

  -- The project path must be URL-encoded into a single segment: GitLab's API
  -- takes "group%2Fproject" where the slash would otherwise split the path.
  local encoded = putil.path_segment(project)

  putil.call(self:_ctx(), ("/projects/%s/issues/%s"):format(encoded, iid), nil, function(err, raw)
    if err then
      return cb(err)
    end
    local issue = self:_to_issue(raw)

    putil.call(self:_ctx(), ("/projects/%s/issues/%s/notes"):format(encoded, iid), {
      query = { per_page = self.comment_limit, sort = "desc", order_by = "created_at" },
    }, function(cerr, notes)
      if not cerr and notes then
        local out = {}
        for _, n in ipairs(notes) do
          -- System notes are GitLab's audit trail ("changed the milestone"),
          -- not comments.
          if not n.system then
            table.insert(out, 1, {
              id = tostring(n.id),
              author = (n.author or {}).name,
              body = n.body or "",
              created_at = issue_mod.timestamp(n.created_at),
            })
          end
        end
        issue.comments = out
        issue.raw.comment_total = raw.user_notes_count or #out
      end
      cb(nil, issue)
    end)
  end)
end

---@return boolean ok
---@return string msg
function GitLab:health()
  if not self.opts then
    return false, "not configured"
  end
  return putil.health(self:_ctx())
end

return M
