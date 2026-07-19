-- Providers are tested against recorded fixtures, never a live API. `http` is
-- injectable precisely so this substitution is possible (§20).

local config = require("issuehub.config")
local jira = require("issuehub.provider.jira")

---Fake transport. Records requests, replays canned responses.
local function fake_http(responses)
  local calls = {}
  return {
    calls = calls,
    request = function(req, cb)
      calls[#calls + 1] = req
      local key = req.url:match("/rest/api/%d(.*)$") or req.url
      local body = responses[key] or responses[1] or {}
      cb(nil, {
        status = 200,
        body = vim.json.encode(body),
        headers = {},
        json = function()
          return body
        end,
      })
    end,
  }
end

local CLOUD_ISSUE = {
  key = "PROJ-123",
  fields = {
    summary = "Timeout on cache warmup",
    description = {
      type = "doc",
      content = {
        { type = "paragraph", content = { { type = "text", text = "Fails after " }, { type = "text", text = "30s", marks = { { type = "code" } } } } },
      },
    },
    status = { id = "3", name = "In Progress", statusCategory = { key = "indeterminate" } },
    assignee = { displayName = "Tetsuya" },
    labels = { "timeout", "cache" },
    created = "2026-07-01T09:00:00.000+0900",
    updated = "2026-07-19T10:15:00.000+0900",
  },
}

local function provider_with(responses)
  config.setup({
    workspace = vim.fn.tempname(),
    providers = { jira = { url = "https://example.atlassian.net", user = "me@example.com", token_env = "SPEC_TOKEN" } },
  })
  vim.env.SPEC_TOKEN = "s3cret"
  local p = jira.new()
  p.http = fake_http(responses)
  assert(p:setup(config.get().providers.jira))
  return p
end

describe("jira provider", function()
  it("maps a cloud issue onto the canonical model", function()
    local p = provider_with({ ["/issue/PROJ-123"] = CLOUD_ISSUE, ["/issue/PROJ-123/comment"] = { comments = {}, total = 0 } })
    local result
    p:get("PROJ-123", function(_, issue)
      result = issue
    end)

    assert.equals("jira://PROJ-123", result.uri)
    assert.equals("Timeout on cache warmup", result.title)
    assert.equals("In Progress", result.status.name)
    assert.same({ "timeout", "cache" }, result.labels)
    assert.equals("https://example.atlassian.net/browse/PROJ-123", result.url)
  end)

  it("derives closed from statusCategory, not from the label", function()
    local done = vim.deepcopy(CLOUD_ISSUE)
    done.fields.status = { id = "6", name = "Rejected", statusCategory = { key = "done" } }
    local p = provider_with({ ["/issue/PROJ-123"] = done, ["/issue/PROJ-123/comment"] = { comments = {} } })

    local result
    p:get("PROJ-123", function(_, issue)
      result = issue
    end)
    -- "Rejected" is in no built-in label table; the API states it is terminal.
    assert.is_true(result.status.closed)
  end)

  it("normalizes timestamps to UTC", function()
    local p = provider_with({ ["/issue/PROJ-123"] = CLOUD_ISSUE, ["/issue/PROJ-123/comment"] = { comments = {} } })
    local result
    p:get("PROJ-123", function(_, issue)
      result = issue
    end)
    assert.equals("2026-07-19T01:15:00Z", result.updated_at)
  end)

  it("converts ADF descriptions to markdown", function()
    local p = provider_with({ ["/issue/PROJ-123"] = CLOUD_ISSUE, ["/issue/PROJ-123/comment"] = { comments = {} } })
    local result
    p:get("PROJ-123", function(_, issue)
      result = issue
    end)
    assert.equals("Fails after `30s`", result.description)
  end)

  it("caps comment fetching rather than only capping rendering", function()
    local p = provider_with({ ["/issue/PROJ-123"] = CLOUD_ISSUE, ["/issue/PROJ-123/comment"] = { comments = {}, total = 250 } })
    p:get("PROJ-123", function() end)

    local comment_call
    for _, call in ipairs(p.http.calls) do
      if call.url:find("/comment") then
        comment_call = call
      end
    end
    assert.equals(20, comment_call.query.maxResults)
  end)

  it("never puts credentials in the url", function()
    local p = provider_with({ ["/issue/PROJ-123"] = CLOUD_ISSUE, ["/issue/PROJ-123/comment"] = { comments = {} } })
    p:get("PROJ-123", function() end)
    for _, call in ipairs(p.http.calls) do
      assert.is_nil(call.url:find("s3cret", 1, true))
      assert.truthy(call.auth)
    end
  end)

  it("uses /search/jql on cloud", function()
    local p = provider_with({ ["/search/jql"] = { issues = { CLOUD_ISSUE } } })
    local got
    p:list(nil, function(_, issues)
      got = issues
    end)
    assert.equals(1, #got)
    assert.truthy(p.http.calls[1].url:find("/rest/api/3/search/jql", 1, true))
  end)
end)
