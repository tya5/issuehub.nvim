local helpers = dofile("spec/helpers.lua")
local redmine = require("issuehub.provider.redmine")

local STATUSES = {
  issue_statuses = {
    { id = 1, name = "New", is_closed = false },
    { id = 3, name = "Resolved", is_closed = false },
    { id = 5, name = "Closed", is_closed = true },
    { id = 6, name = "Rejected", is_closed = true },
  },
}

local function issue_payload(status_id, status_name)
  return {
    issue = {
      id = 12345,
      subject = "Timeout on cache warmup",
      description = "Warmup exceeds 30s when cold.",
      status = { id = status_id, name = status_name },
      tracker = { name = "Bug" },
      priority = { name = "High" },
      assigned_to = { name = "Tetsuya" },
      author = { name = "Alice" },
      created_on = "2026-07-01T09:00:00Z",
      updated_on = "2026-07-19T10:15:00Z",
      journals = {
        { id = 1, user = { name = "Alice" }, notes = "Reproduced on staging.", created_on = "2026-07-19T09:00:00Z" },
        -- A field-change record with no note: an audit trail entry, not a comment.
        { id = 2, user = { name = "Bob" }, notes = "", created_on = "2026-07-19T09:30:00Z" },
      },
    },
  }
end

local function provider(responses)
  helpers.configure("redmine", { url = "https://redmine.example.com/", token_env = "SPEC_REDMINE" })
  vim.env.SPEC_REDMINE = "s3cret"
  local p = redmine.new()
  p.http = helpers.fake_http(vim.tbl_extend("force", { ["/issue_statuses.json"] = STATUSES }, responses))
  assert(p:setup(require("issuehub.config").get().providers.redmine))
  return p
end

describe("redmine provider", function()
  it("maps an issue onto the canonical model", function()
    local p = provider({ ["/issues/12345.json"] = issue_payload(1, "New") })
    local issue = helpers.sync(function(cb)
      p:get("12345", cb)
    end)

    assert.equals("redmine://12345", issue.uri)
    assert.equals("Timeout on cache warmup", issue.title)
    assert.equals("New", issue.status.name)
    assert.equals("Tetsuya", issue.assignee)
    assert.equals("https://redmine.example.com/issues/12345", issue.url)
  end)

  it("derives closed from /issue_statuses.json, not from the status name", function()
    -- "Rejected" is terminal here but is in no built-in table; only the
    -- instance's own status list knows that (§4.1).
    local p = provider({ ["/issues/12345.json"] = issue_payload(6, "Rejected") })
    local issue = helpers.sync(function(cb)
      p:get("12345", cb)
    end)
    assert.is_true(issue.status.closed)

    local open = provider({ ["/issues/12345.json"] = issue_payload(3, "Resolved") })
    local other = helpers.sync(function(cb)
      open:get("12345", cb)
    end)
    -- "Resolved" sounds terminal but this instance says it is not.
    assert.is_false(other.status.closed)
  end)

  it("prefers a per-issue is_closed when the version supplies one", function()
    local payload = issue_payload(99, "Custom")
    payload.issue.status.is_closed = true
    local p = provider({ ["/issues/12345.json"] = payload })
    local issue = helpers.sync(function(cb)
      p:get("12345", cb)
    end)
    assert.is_true(issue.status.closed)
  end)

  it("fetches the status map only once", function()
    local p = provider({ ["/issues/12345.json"] = issue_payload(1, "New") })
    p:get("12345", function() end)
    p:get("12345", function() end)

    local count = 0
    for _, call in ipairs(p.http.calls) do
      if call.url:find("issue_statuses", 1, true) then
        count = count + 1
      end
    end
    assert.equals(1, count)
  end)

  it("skips journal entries that carry no note", function()
    local p = provider({ ["/issues/12345.json"] = issue_payload(1, "New") })
    local issue = helpers.sync(function(cb)
      p:get("12345", cb)
    end)
    assert.equals(1, #issue.comments)
    assert.equals("Reproduced on staging.", issue.comments[1].body)
  end)

  it("sends the api key as a header, never in the url", function()
    local p = provider({ ["/issues/12345.json"] = issue_payload(1, "New") })
    p:get("12345", function() end)
    for _, call in ipairs(p.http.calls) do
      assert.is_nil(call.url:find("s3cret", 1, true))
    end
    assert.equals("s3cret", p.http.find_call("/issues/12345.json").headers["X-Redmine-API-Key"])
  end)
end)
