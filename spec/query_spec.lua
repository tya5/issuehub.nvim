local config = require("issuehub.config")
local overlay = require("issuehub.core.overlay")
local query = require("issuehub.core.query")

describe("query.parse", function()
  it("treats bare words as the pattern", function()
    local parsed = query.parse("cache eviction")
    assert.equals("cache eviction", parsed.pattern)
    assert.is_false(parsed.regex)
    assert.same({}, parsed.meta)
  end)

  it("pulls out --regex", function()
    local parsed = query.parse("cache.* --regex")
    assert.equals("cache.*", parsed.pattern)
    assert.is_true(parsed.regex)
  end)

  it("parses --meta key=value", function()
    local parsed = query.parse("--meta priority=high")
    assert.equals("", parsed.pattern)
    assert.same({ { key = "priority", value = "high" } }, parsed.meta)
  end)

  it("parses a bare --meta key as a presence test", function()
    assert.same({ { key = "owner", value = nil } }, query.parse("--meta owner").meta)
  end)

  it("accepts spaces around the equals sign", function()
    -- What people actually type, and what a shell-less prompt hands us.
    assert.same({ { key = "priority", value = "high" } }, query.parse("--meta priority = high").meta)
    assert.same({ { key = "priority", value = "high" } }, query.parse("--meta=priority=high").meta)
  end)

  it("combines text, regex, and several filters", function()
    local parsed = query.parse("eviction --meta priority=high --meta tags=cache --regex")
    assert.equals("eviction", parsed.pattern)
    assert.is_true(parsed.regex)
    assert.equals(2, #parsed.meta)
  end)

  it("keeps quoted runs together", function()
    assert.equals("cache warm up", query.parse('"cache warm up"').pattern)
  end)

  it("accepts an argument list as well as a string", function()
    -- The subcommand hands us fargs; the prompt hands us one string.
    assert.same(query.parse("eviction --meta priority=high"), query.parse({ "eviction", "--meta", "priority=high" }))
  end)

  it("describes itself for picker titles", function()
    assert.equals(
      "eviction priority=high owner?",
      query.describe(query.parse("eviction --meta priority=high --meta owner"))
    )
  end)
end)

describe("query.matches_meta", function()
  local URI = "jira://P-1"

  before_each(function()
    config.setup({ workspace = vim.fn.tempname(), index = "json" })
    require("issuehub.core.index").reset()
    require("issuehub.core.repository").ensure()
    overlay.write(URI, { metadata = "priority: high\nowner: tya5\ntags:\n  - timeout\n  - cache" })
  end)

  local function meta(input)
    return query.parse(input).meta
  end

  it("matches an exact value", function()
    assert.is_true(query.matches_meta(URI, meta("--meta priority=high")))
    assert.is_false(query.matches_meta(URI, meta("--meta priority=low")))
  end)

  it("ignores case", function()
    assert.is_true(query.matches_meta(URI, meta("--meta priority=HIGH")))
  end)

  it("matches membership in a list", function()
    -- `tags: [timeout, cache]` should satisfy tags=cache.
    assert.is_true(query.matches_meta(URI, meta("--meta tags=cache")))
    assert.is_false(query.matches_meta(URI, meta("--meta tags=nope")))
  end)

  it("treats a bare key as a presence test", function()
    assert.is_true(query.matches_meta(URI, meta("--meta owner")))
    assert.is_false(query.matches_meta(URI, meta("--meta assignee")))
  end)

  it("requires every filter to hold", function()
    assert.is_true(query.matches_meta(URI, meta("--meta priority=high --meta owner=tya5")))
    assert.is_false(query.matches_meta(URI, meta("--meta priority=high --meta owner=someone")))
  end)

  it("passes everything when there are no filters", function()
    assert.is_true(query.matches_meta(URI, {}))
    assert.is_true(query.matches_meta("jira://NOTHING", {}))
  end)

  it("is false for an issue with no metadata at all", function()
    assert.is_false(query.matches_meta("jira://EMPTY", meta("--meta priority=high")))
  end)
end)

describe("metadata tokens for picker filtering", function()
  local overlay = require("issuehub.core.overlay")

  before_each(function()
    config.setup({ workspace = vim.fn.tempname(), index = "json" })
    require("issuehub.core.index").reset()
    require("issuehub.core.repository").ensure()
  end)

  it("emits one token per pair, and one per list value", function()
    assert.equals(
      "owner:tya5 priority:high tags:cache tags:timeout",
      overlay.tokens({ priority = "high", owner = "tya5", tags = { "timeout", "cache" } })
    )
  end)

  it("lowercases so picker filtering is case-insensitive", function()
    assert.equals("priority:high", overlay.tokens({ Priority = "HIGH" }))
  end)

  it("skips empty values", function()
    assert.equals("a:1", overlay.tokens({ a = 1, b = "" }))
  end)

  it("puts both spellings in the searchable blob", function()
    overlay.write("jira://A", { memo = "notes", metadata = "priority: high" })
    local blob = overlay.searchable("jira://A")
    -- The raw text, so `priority: high` matches...
    assert.truthy(blob:find("priority: high", 1, true))
    -- ...and the token, so `priority:high` does too.
    assert.truthy(blob:find("priority:high", 1, true))
    assert.truthy(blob:find("notes", 1, true))
  end)

  it("is empty for an issue with no overlay", function()
    assert.equals("", overlay.searchable("jira://NOTHING"))
  end)
end)
