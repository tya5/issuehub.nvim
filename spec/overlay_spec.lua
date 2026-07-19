local config = require("issuehub.config")
local overlay = require("issuehub.core.overlay")
local workspace = require("issuehub.core.workspace")
local fs = require("issuehub.util.fs")
local yaml = require("issuehub.util.yaml")

local URI = "jira://PROJ-1"

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").ensure()
end

describe("overlay", function()
  before_each(fresh)

  it("reads empty strings for an issue with no notes", function()
    local o = overlay.read(URI)
    assert.equals("", o.memo)
    assert.equals("", o.metadata)
    assert.equals("", o.prompt)
    assert.is_false(overlay.exists(URI))
  end)

  it("creates no directory until something is written", function()
    overlay.read(URI)
    assert.is_false(fs.exists(require("issuehub.core.repository").issue_dir(URI)))
  end)

  it("round-trips memo text", function()
    overlay.write(URI, { memo = "line one\nline two" })
    assert.equals("line one\nline two", overlay.read(URI).memo)
    assert.is_true(overlay.exists(URI))
  end)

  it("writes only the fields that changed", function()
    overlay.write(URI, { memo = "a", prompt = "p" })
    local written = overlay.write(URI, { memo = "a", prompt = "changed" })
    -- Rewriting unchanged files would touch mtimes and produce empty git diffs.
    assert.same({ "prompt" }, written)
  end)

  it("preserves metadata verbatim, comments and ordering included", function()
    local text = table.concat({
      "# ops notes",
      "priority: high",
      "risk:     medium   # deliberate spacing",
      "tags:",
      "  - timeout",
      "  - cache",
      "unknown_key: kept",
    }, "\n")
    overlay.write(URI, { metadata = text })

    -- Writeback is verbatim buffer text, so nothing is normalized away.
    assert.equals(text, overlay.read(URI).metadata)
  end)

  it("parses metadata for reading", function()
    overlay.write(URI, { metadata = "priority: high\ncount: 3\nflag: true\ntags:\n  - a\n  - b" })
    local parsed = overlay.metadata(URI)
    assert.equals("high", parsed.priority)
    assert.equals(3, parsed.count)
    assert.is_true(parsed.flag)
    assert.same({ "a", "b" }, parsed.tags)
  end)

  it("removes the file when a section is emptied", function()
    overlay.write(URI, { memo = "something" })
    assert.is_true(fs.exists(overlay.path(URI, "memo")))
    overlay.write(URI, { memo = "" })
    assert.is_false(fs.exists(overlay.path(URI, "memo")))
  end)

  it("does not accumulate trailing newlines across round trips", function()
    overlay.write(URI, { memo = "text" })
    for _ = 1, 3 do
      overlay.write(URI, { memo = overlay.read(URI).memo })
    end
    assert.equals("text\n", fs.read(overlay.path(URI, "memo")))
  end)
end)

describe("workspace state", function()
  before_each(fresh)

  it("defaults to not bookmarked", function()
    assert.is_false(workspace.state(URI).bookmarked)
  end)

  it("toggles a bookmark and persists it", function()
    assert.is_true(workspace.toggle_bookmark(URI))
    assert.is_true(workspace.state(URI).bookmarked)
    assert.is_false(workspace.toggle_bookmark(URI))
    assert.is_false(workspace.state(URI).bookmarked)
  end)

  it("writes no state file when there is nothing to record", function()
    workspace.toggle_bookmark(URI)
    workspace.toggle_bookmark(URI)
    -- An absent file already means "not bookmarked, never opened".
    local path = vim.fs.joinpath(require("issuehub.core.repository").issue_dir(URI), "state.yaml")
    assert.is_false(fs.exists(path))
  end)

  it("records the revision seen at open time", function()
    local cache = require("issuehub.core.cache")
    local issue_mod = require("issuehub.core.issue")
    cache.put(issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-19T10:00:00Z",
    }))

    workspace.touch(URI)
    assert.equals("2026-07-19T10:00:00Z", workspace.state(URI).last_seen_updated_at)
    assert.is_false(workspace.changed_since_seen(URI))

    cache.put(issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-20T10:00:00Z",
    }))
    assert.is_true(workspace.changed_since_seen(URI))
  end)

  it("finds issues with local content by walking the repository", function()
    overlay.write(URI, { memo = "note" })
    overlay.write("github://o%2Fr%231", { memo = "note" })
    local found = workspace.with_overlay()
    table.sort(found)
    -- Walks the tree, not the index: the overlay is user-authored and must stay
    -- findable even if .state/ was deleted.
    assert.same({ "github://o%2Fr%231", "jira://PROJ-1" }, found)
  end)
end)

describe("yaml", function()
  it("parses scalars with types", function()
    local parsed = yaml.parse('s: text\nn: 42\nf: 1.5\nb: true\nq: "123"')
    assert.equals("text", parsed.s)
    assert.equals(42, parsed.n)
    assert.equals(1.5, parsed.f)
    assert.is_true(parsed.b)
    -- Quoted digits stay a string.
    assert.equals("123", parsed.q)
  end)

  it("ignores comments and document markers", function()
    local parsed = yaml.parse("---\n# a comment\nkey: value  # trailing\n")
    assert.equals("value", parsed.key)
  end)

  it("parses lists and one level of nesting", function()
    local parsed = yaml.parse("tags:\n  - a\n  - b\nowner:\n  name: tetsuya\n  team: ops")
    assert.same({ "a", "b" }, parsed.tags)
    assert.equals("tetsuya", parsed.owner.name)
  end)

  it("encodes with sorted keys for stable git diffs", function()
    local out = yaml.encode({ b = 2, a = 1, c = { "x", "y" } })
    assert.equals("a: 1\nb: 2\nc:\n  - x\n  - y\n", out)
  end)

  it("quotes values that would parse back as another type", function()
    assert.equals('a: "123"\n', yaml.encode({ a = "123" }))
    assert.equals('a: "true"\n', yaml.encode({ a = "true" }))
  end)

  it("round-trips what it encodes", function()
    local original = { priority = "high", count = 3, flag = true, tags = { "a", "b" } }
    local parsed = yaml.parse(yaml.encode(original))
    assert.same(original, parsed)
  end)
end)
