local helpers = dofile("spec/helpers.lua")
local gitlab = require("issuehub.provider.gitlab")

local ISSUE = {
  id = 99001,
  iid = 12,
  project_id = 42,
  title = "Timeout on cache warmup",
  description = "Warmup exceeds **30s** when cold.",
  state = "opened",
  references = { full = "group/proj#12" },
  web_url = "https://gitlab.com/group/proj/-/issues/12",
  author = { name = "Alice" },
  assignee = { name = "Tetsuya" },
  labels = { "bug", "cache" },
  user_notes_count = 2,
  created_at = "2026-07-01T09:00:00Z",
  updated_at = "2026-07-19T10:15:00Z",
}

local function provider(responses)
  helpers.configure("gitlab", { token_env = "SPEC_GL" })
  vim.env.SPEC_GL = "glpat-s3cret"
  local p = gitlab.new()
  p.http = helpers.fake_http(responses)
  assert(p:setup(require("issuehub.config").get().providers.gitlab))
  return p
end

local NOTES = {
  { id = 2, system = false, author = { name = "Bob" }, body = "newer", created_at = "2026-07-19T10:00:00Z" },
  { id = 1, system = false, author = { name = "Alice" }, body = "older", created_at = "2026-07-19T09:00:00Z" },
  -- GitLab's audit trail, not a comment.
  { id = 3, system = true, author = { name = "Bob" }, body = "changed milestone", created_at = "2026-07-19T10:05:00Z" },
}

describe("gitlab provider", function()
  it("qualifies ids with the project path and iid", function()
    local p = provider({ ["/projects/group%2Fproj/issues/12"] = ISSUE })
    local issue = helpers.sync(function(cb)
      p:get("group/proj#12", cb)
    end)

    -- iid (12), not the global id (99001): iid is what the UI shows.
    assert.equals("group/proj#12", issue.id)
    assert.equals("gitlab://group%2Fproj%2312", issue.uri)
  end)

  it("url-encodes the project path into one segment", function()
    local p = provider({ ["/projects/group%2Fproj/issues/12"] = ISSUE })
    p:get("group/proj#12", function() end)
    -- A raw slash here would split the path and hit the wrong endpoint.
    assert.truthy(p.http.calls[1].url:find("/projects/group%2Fproj/issues/12", 1, true))
  end)

  it("normalizes 'opened' to Open", function()
    local p = provider({ ["/projects/group%2Fproj/issues/12"] = ISSUE })
    local issue = helpers.sync(function(cb)
      p:get("group/proj#12", cb)
    end)
    assert.equals("Open", issue.status.name)
    assert.is_false(issue.status.closed)
  end)

  it("marks closed issues", function()
    local closed = vim.tbl_extend("force", vim.deepcopy(ISSUE), { state = "closed" })
    local p = provider({ ["/projects/group%2Fproj/issues/12"] = closed })
    local issue = helpers.sync(function(cb)
      p:get("group/proj#12", cb)
    end)
    assert.equals("Closed", issue.status.name)
    assert.is_true(issue.status.closed)
  end)

  it("drops system notes and restores chronological order", function()
    local p = provider({
      ["/projects/group%2Fproj/issues/12"] = ISSUE,
      ["/issues/12/notes"] = NOTES,
    })
    local issue = helpers.sync(function(cb)
      p:get("group/proj#12", cb)
    end)

    assert.equals(2, #issue.comments)
    -- Requested newest-first, rendered oldest-first.
    assert.equals("older", issue.comments[1].body)
    assert.equals("newer", issue.comments[2].body)
  end)

  it("falls back to web_url when references are absent", function()
    local bare = vim.deepcopy(ISSUE)
    bare.references = nil
    local p = provider({ ["/projects/group%2Fproj/issues/12"] = bare })
    local issue = helpers.sync(function(cb)
      p:get("group/proj#12", cb)
    end)
    assert.equals("group/proj#12", issue.id)
  end)

  it("targets /api/v4 under a self-managed host", function()
    helpers.configure("gitlab", { url = "https://gitlab.example.com/", token_env = "SPEC_GL" })
    local p = gitlab.new()
    p.http = helpers.fake_http({ ["/issues"] = { ISSUE } })
    p:setup(require("issuehub.config").get().providers.gitlab)
    p:list(nil, function() end)
    assert.truthy(p.http.calls[1].url:find("https://gitlab.example.com/api/v4/issues", 1, true))
  end)

  it("sends the token as a header, never in the url", function()
    local p = provider({ ["/projects/group%2Fproj/issues/12"] = ISSUE })
    p:get("group/proj#12", function() end)
    for _, call in ipairs(p.http.calls) do
      assert.is_nil(call.url:find("glpat-s3cret", 1, true))
    end
    assert.equals("glpat-s3cret", p.http.calls[1].headers["PRIVATE-TOKEN"])
  end)

  it("rejects an unqualified id", function()
    local p = provider({})
    local _, err = helpers.sync(function(cb)
      p:get("12", cb)
    end)
    assert.truthy(err:find("group/project#iid"))
  end)
end)
