local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue = require("issuehub.core.issue")

local function full(id)
  return issue.normalize({
    provider = "jira",
    id = id,
    title = "Timeout",
    description = "the full description",
    status = { id = "1", name = "Open" },
    comments = { { id = "1", author = "Alice", body = "hi", created_at = "2026-07-19T09:00:00Z" } },
    updated_at = "2026-07-19T10:15:00Z",
  })
end

local function partial(id)
  -- What list()/search() returns: no description, no comments (§7).
  return issue.normalize({
    provider = "jira",
    id = id,
    title = "Timeout",
    status = { id = "1", name = "Open" },
    updated_at = "2026-07-19T10:15:00Z",
  })
end

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").ensure()
end

describe("cache", function()
  before_each(fresh)

  it("round-trips an issue", function()
    cache.put(full("A"))
    local entry = cache.get("jira://A")
    assert.equals("the full description", entry.issue.description)
    assert.is_false(entry.partial)
  end)

  it("returns nil for an unknown uri", function()
    assert.is_nil(cache.get("jira://NOPE"))
  end)

  it("marks list results partial", function()
    cache.put_all({ partial("A") })
    assert.is_true(cache.get("jira://A").partial)
  end)

  it("treats a partial entry as stale no matter how recent", function()
    -- Otherwise opening from the picker shows a permanently empty description:
    -- fetched_at is seconds old, so an age-only check would decline to refresh.
    cache.put_all({ partial("A") })
    assert.is_true(cache.is_stale("jira://A", 3600))
  end)

  it("treats a fresh complete entry as current", function()
    cache.put(full("A"))
    assert.is_false(cache.is_stale("jira://A", 3600))
  end)

  it("never lets a partial result blank out a complete one", function()
    cache.put(full("A"))
    cache.put_all({ partial("A") }) -- e.g. the user re-runs a list query
    local entry = cache.get("jira://A")
    assert.equals("the full description", entry.issue.description)
    assert.equals(1, #entry.issue.comments)
    assert.is_false(entry.partial)
  end)

  it("deletes", function()
    cache.put(full("A"))
    cache.delete("jira://A")
    assert.is_nil(cache.get("jira://A"))
  end)
end)

describe("cache case collisions", function()
  before_each(fresh)

  it("refuses to merge ids differing only by case", function()
    -- On macOS these would otherwise share one file, silently merging two
    -- different issues.
    assert.is_true(cache.put(full("PROJ-1")))
    local ok, err = cache.put(full("proj-1"))
    assert.is_false(ok)
    assert.truthy(err:find("case collision"))
  end)

  it("allows re-writing the same id", function()
    assert.is_true(cache.put(full("PROJ-1")))
    assert.is_true(cache.put(full("PROJ-1")))
  end)
end)
