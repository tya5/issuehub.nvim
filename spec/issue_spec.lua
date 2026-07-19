local issue = require("issuehub.core.issue")

describe("issue.uri", function()
  it("leaves the common case untouched", function()
    assert.equals("jira://PROJ-123", issue.uri("jira", "PROJ-123"))
    assert.equals("redmine://12345", issue.uri("redmine", "12345"))
  end)

  it("percent-encodes path-unsafe characters", function()
    assert.equals("jira://PROJ%2F123", issue.uri("jira", "PROJ/123"))
    assert.equals("jira://A%23B", issue.uri("jira", "A#B"))
    assert.equals("jira://A%20B", issue.uri("jira", "A B"))
  end)

  it("round-trips", function()
    for _, id in ipairs({ "PROJ-123", "PROJ/123", "A#B", "a b%c", "12345" }) do
      local provider, decoded = issue.parse(issue.uri("jira", id))
      assert.equals("jira", provider)
      assert.equals(id, decoded)
    end
  end)

  it("rejects non-URIs", function()
    assert.is_false(issue.is_uri("PROJ-123"))
    assert.is_false(issue.is_uri(""))
    assert.is_true(issue.is_uri("jira://PROJ-123"))
  end)
end)

describe("issue.timestamp", function()
  it("passes UTC through", function()
    assert.equals("2026-07-19T10:15:00Z", issue.timestamp("2026-07-19T10:15:00Z"))
  end)

  it("converts an offset to UTC", function()
    assert.equals("2026-07-19T01:15:00Z", issue.timestamp("2026-07-19T10:15:00.000+0900"))
  end)

  it("tolerates junk", function()
    assert.equals("", issue.timestamp(nil))
    assert.equals("", issue.timestamp(""))
    assert.equals("not a date", issue.timestamp("not a date"))
  end)
end)

describe("issue.normalize", function()
  it("fills in every field so consumers need no nil checks", function()
    local normalized = issue.normalize({ provider = "jira", id = "PROJ-1" })
    assert.equals("jira://PROJ-1", normalized.uri)
    assert.equals("", normalized.title)
    assert.same({}, normalized.labels)
    assert.same({}, normalized.comments)
    assert.is_false(normalized.status.closed)
    assert.equals("Unknown", normalized.status.name)
  end)

  it("keeps closed strictly boolean", function()
    local open = issue.normalize({ provider = "jira", id = "A", status = { id = "1", name = "Open" } })
    assert.is_false(open.status.closed)
    local done = issue.normalize({ provider = "jira", id = "B", status = { id = "6", name = "Done", closed = true } })
    assert.is_true(done.status.closed)
  end)
end)

describe("issue.to_item", function()
  it("flattens status to name + closed", function()
    local item = issue.to_item(issue.normalize({
      provider = "jira",
      id = "PROJ-9",
      title = "Timeout",
      status = { id = "6", name = "Done", closed = true },
      updated_at = "2026-07-19T10:15:00Z",
    }))
    assert.equals("Done", item.status)
    assert.is_true(item.closed)
    assert.is_false(item.bookmarked)
  end)
end)
