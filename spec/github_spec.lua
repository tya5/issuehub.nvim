local helpers = dofile("spec/helpers.lua")
local github = require("issuehub.provider.github")

local ISSUE = {
  number = 123,
  title = "Timeout on cache warmup",
  body = "Warmup exceeds **30s** when cold.",
  state = "open",
  repository_url = "https://api.github.com/repos/tya5/issuehub.nvim",
  html_url = "https://github.com/tya5/issuehub.nvim/issues/123",
  user = { login = "alice" },
  assignee = { login = "tya5" },
  labels = { { name = "bug" }, { name = "cache" } },
  comments = 0,
  created_at = "2026-07-01T09:00:00Z",
  updated_at = "2026-07-19T10:15:00Z",
}

local function with(overrides)
  return vim.tbl_deep_extend("force", vim.deepcopy(ISSUE), overrides)
end

local function provider(responses)
  helpers.configure("github", { token_env = "SPEC_GH" })
  vim.env.SPEC_GH = "ghp_s3cret"
  local p = github.new()
  p.http = helpers.fake_http(responses)
  assert(p:setup(require("issuehub.config").get().providers.github))
  return p
end

local function fetch(p, id)
  return helpers.sync(function(cb)
    p:get(id, cb)
  end)
end

describe("github provider", function()
  it("qualifies ids with the repository", function()
    local p = provider({ ["/repos/tya5/issuehub.nvim/issues/123"] = ISSUE })
    local issue = fetch(p, "tya5/issuehub.nvim#123")

    assert.equals("tya5/issuehub.nvim#123", issue.id)
    -- The slash and hash are exactly why URIs are percent-encoded (§4.2).
    assert.equals("github://tya5%2Fissuehub.nvim%23123", issue.uri)
  end)

  it("round-trips a repo-qualified uri back to the original id", function()
    local issue_mod = require("issuehub.core.issue")
    local provider_name, id = issue_mod.parse("github://tya5%2Fissuehub.nvim%23123")
    assert.equals("github", provider_name)
    assert.equals("tya5/issuehub.nvim#123", id)
  end)

  it("defaults to api.github.com without configuration", function()
    local p = provider({ ["/repos/tya5/issuehub.nvim/issues/123"] = ISSUE })
    p:get("tya5/issuehub.nvim#123", function() end)
    assert.truthy(p.http.calls[1].url:find("https://api.github.com/repos/", 1, true))
  end)

  it("distinguishes merged and draft pull requests", function()
    local merged = provider({
      ["/repos/tya5/issuehub.nvim/issues/123"] = with({
        pull_request = {},
        state = "closed",
        merged_at = "2026-07-19T11:00:00Z",
      }),
    })
    local issue = fetch(merged, "tya5/issuehub.nvim#123")
    assert.equals("Merged", issue.status.name)
    assert.is_true(issue.status.closed)

    local draft = provider({
      ["/repos/tya5/issuehub.nvim/issues/123"] = with({ pull_request = {}, draft = true }),
    })
    local other = fetch(draft, "tya5/issuehub.nvim#123")
    assert.equals("Draft", other.status.name)
    assert.is_false(other.status.closed)
  end)

  it("separates 'closed' from 'closed as not planned'", function()
    local p = provider({
      ["/repos/tya5/issuehub.nvim/issues/123"] = with({ state = "closed", state_reason = "not_planned" }),
    })
    local issue = fetch(p, "tya5/issuehub.nvim#123")
    assert.equals("Closed (not planned)", issue.status.name)
    assert.is_true(issue.status.closed)
  end)

  it("fetches the newest comments by asking for the last page", function()
    local p = provider({
      ["/repos/tya5/issuehub.nvim/issues/123"] = with({ comments = 55 }),
      ["/issues/123/comments"] = {
        { id = 1, user = { login = "bob" }, body = "latest", created_at = "2026-07-19T09:00:00Z" },
      },
    })
    local issue = fetch(p, "tya5/issuehub.nvim#123")

    local call = p.http.find_call("/comments")
    assert.equals(20, call.query.per_page)
    assert.equals(3, call.query.page) -- ceil(55/20)
    assert.equals(55, issue.raw.comment_total)
    assert.equals(1, #issue.comments)
  end)

  it("skips the comment request when there are none", function()
    local p = provider({ ["/repos/tya5/issuehub.nvim/issues/123"] = ISSUE })
    fetch(p, "tya5/issuehub.nvim#123")
    assert.is_nil(p.http.find_call("/comments"))
  end)

  it("derives the repo from repository_url on list results", function()
    local p = provider({ ["/issues"] = { ISSUE } })
    local issues = helpers.sync(function(cb)
      p:list(nil, cb)
    end)
    assert.equals("tya5/issuehub.nvim#123", issues[1].id)
  end)

  it("rejects an unqualified id with a useful message", function()
    local p = provider({})
    local _, err = helpers.sync(function(cb)
      p:get("123", function(e, v)
        cb(e, v)
      end)
    end)
    assert.truthy(err:find("owner/repo#number"))
  end)

  it("never puts the token in the url", function()
    local p = provider({ ["/repos/tya5/issuehub.nvim/issues/123"] = ISSUE })
    p:get("tya5/issuehub.nvim#123", function() end)
    for _, call in ipairs(p.http.calls) do
      assert.is_nil(call.url:find("ghp_s3cret", 1, true))
    end
    assert.equals("ghp_s3cret", p.http.calls[1].auth.bearer)
  end)
end)

describe("pagination", function()
  local function paged(total, per_page)
    -- A fake that serves `total` issues across pages of `per_page`.
    local calls = {}
    return {
      calls = calls,
      request = function(req, cb)
        calls[#calls + 1] = req
        local page = req.query and req.query.page or 1
        local size = req.query and req.query.per_page or 100
        local items = {}
        for i = (page - 1) * size + 1, math.min(page * size, total) do
          items[#items + 1] = vim.tbl_deep_extend("force", vim.deepcopy(ISSUE), { number = i })
        end
        local body = req.url:find("/search/") and { items = items } or items
        cb(nil, {
          status = 200,
          body = "",
          headers = {},
          json = function()
            return body
          end,
        })
      end,
    }
  end

  local function provider_with(http, opts)
    helpers.configure("github", vim.tbl_extend("force", { token_env = "SPEC_GH" }, opts or {}))
    vim.env.SPEC_GH = "t"
    local p = github.new()
    p.http = http
    p:setup(require("issuehub.config").get().providers.github)
    return p
  end

  it("fetches one page by default", function()
    local http = paged(250, 100)
    local p = provider_with(http)
    local issues = helpers.sync(function(cb)
      p:list(nil, cb)
    end)
    -- Without max_results, one request: an old backlog must not be pulled by
    -- accident.
    assert.equals(100, #issues)
    assert.equals(1, #http.calls)
  end)

  it("follows pages up to max_results", function()
    local http = paged(250, 100)
    local p = provider_with(http, { max_results = 250 })
    local issues = helpers.sync(function(cb)
      p:list(nil, cb)
    end)
    assert.equals(250, #issues)
    assert.equals(3, #http.calls)
    assert.equals(1, http.calls[1].query.page)
    assert.equals(3, http.calls[3].query.page)
  end)

  it("stops at a short page rather than asking for one more", function()
    local http = paged(150, 100)
    local p = provider_with(http, { max_results = 1000 })
    local issues = helpers.sync(function(cb)
      p:list(nil, cb)
    end)
    assert.equals(150, #issues)
    assert.equals(2, #http.calls)
  end)

  it("stops at exactly max_results even mid-page", function()
    local http = paged(500, 100)
    local p = provider_with(http, { max_results = 120 })
    local issues = helpers.sync(function(cb)
      p:list(nil, cb)
    end)
    assert.equals(120, #issues)
    assert.equals(2, #http.calls)
  end)

  it("honours a smaller page size", function()
    local http = paged(100, 25)
    local p = provider_with(http, { max_results = 100, per_page = 25 })
    local issues = helpers.sync(function(cb)
      p:list(nil, cb)
    end)
    assert.equals(100, #issues)
    assert.equals(25, http.calls[1].query.per_page)
  end)

  it("stops before GitHub's 1000-result search ceiling", function()
    local http = paged(5000, 100)
    local p = provider_with(http, { max_results = 5000 })
    local issues = helpers.sync(function(cb)
      p:search("is:issue", cb)
    end)
    -- The API returns 422 past 1000; stopping first keeps it a result rather
    -- than an error.
    assert.equals(1000, #issues)
  end)
end)
