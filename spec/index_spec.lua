local config = require("issuehub.config")
local index_mod = require("issuehub.core.index")
local cache = require("issuehub.core.cache")
local issue = require("issuehub.core.issue")

local function make(id, closed, updated)
  return issue.normalize({
    provider = "jira",
    id = id,
    title = id .. " something",
    status = { id = "1", name = closed and "Done" or "Open", closed = closed },
    updated_at = updated,
  })
end

local function fresh(backend)
  config.setup({ workspace = vim.fn.tempname(), index = backend })
  index_mod.reset()
  require("issuehub.core.repository").forget_case_index()
  require("issuehub.core.repository").ensure()
  return index_mod.get()
end

describe("json index", function()
  it("stores and lists", function()
    local index = fresh("json")
    index:put(make("A", false, "2026-07-19T00:00:00Z"))
    index:put(make("B", true, "2026-07-18T00:00:00Z"))

    assert.equals(2, #index:list())
    assert.equals(1, #index:list({ closed = false }))
    assert.equals("A", index:list({ closed = false })[1].id)
  end)

  it("upserts rather than duplicating", function()
    local index = fresh("json")
    index:put(make("A", false, "2026-07-19T00:00:00Z"))
    index:put(make("A", true, "2026-07-20T00:00:00Z"))
    assert.equals(1, #index:list())
    assert.is_true(index:list()[1].closed)
  end)

  it("deletes", function()
    local index = fresh("json")
    index:put(make("A", false, "2026-07-19T00:00:00Z"))
    index:delete("jira://A")
    assert.equals(0, #index:list())
  end)

  it("searches by substring", function()
    local index = fresh("json")
    index:put(make("A", false, "2026-07-19T00:00:00Z"))
    assert.equals(1, #index:search("something"))
    assert.equals(0, #index:search("nothing"))
  end)

  it("rebuilds from cache alone, holding no truth of its own", function()
    local index = fresh("json")
    cache.put(make("A", false, "2026-07-19T00:00:00Z"))
    cache.put(make("B", false, "2026-07-18T00:00:00Z"))

    -- Simulate `rm -rf .state/index`
    index.items = {}
    assert.equals(0, #index:list())
    assert.equals(2, index:rebuild())
    assert.equals(2, #index:list())
  end)
end)

describe("sqlite index", function()
  local sqlite = require("issuehub.core.index.sqlite")

  it("is skipped cleanly when sqlite3 is absent", function()
    if not sqlite.available() then
      -- The point of the probe: an absent binary degrades, never errors.
      local index = fresh("sqlite")
      assert.equals("json", index.name)
      return
    end

    local index = fresh("sqlite")
    assert.equals("sqlite", index.name)

    index:put(make("A", false, "2026-07-19T00:00:00Z"))
    index:put(make("B", true, "2026-07-18T00:00:00Z"))

    assert.equals(2, #index:list())
    assert.equals(1, #index:list({ closed = false }))
    assert.equals("A", index:list({ closed = false })[1].id)

    index:put(make("A", true, "2026-07-20T00:00:00Z"))
    assert.equals(2, #index:list())

    index:delete("jira://A")
    assert.equals(1, #index:list())
  end)

  it("escapes quotes in titles", function()
    if not sqlite.available() then
      return
    end
    local index = fresh("sqlite")
    local tricky = make("C", false, "2026-07-19T00:00:00Z")
    tricky.title = "it's a 'quoted' title"
    index:put(tricky)
    assert.equals("it's a 'quoted' title", index:list()[1].title)
  end)
end)

describe("sqlite full-text search over notes", function()
  local function seed(index)
    local overlay = require("issuehub.core.overlay")
    local seeded = make("A", false, "2026-07-19T00:00:00Z")
    seeded.title = "Timeout on warmup"
    seeded.description = "the request path is slow"
    require("issuehub.core.cache").put(seeded)

    overlay.write("jira://A", {
      memo = "suspect the eviction policy under load",
      metadata = "risk: high\nowner: tetsuya",
    })
    require("issuehub.core.analysis").save("jira://A", {
      prompt = "why does warmup stall",
      response = "the connection pool saturates before the cache fills",
    })
    index:put(require("issuehub.core.cache").get("jira://A").issue)
  end

  it("finds text in memo, metadata, and analyses, not just the payload", function()
    local index = fresh("sqlite")
    if index.name ~= "sqlite" or not index:has_fts() then
      return -- probed at runtime; the json fallback has no full-text search
    end
    seed(index)

    -- The whole point of FTS5 over the json index: prose the user accumulated.
    assert.equals(1, #index:search("eviction"))
    assert.equals(1, #index:search("tetsuya"))
    assert.equals(1, #index:search("saturates"))
    assert.equals(0, #index:search("nothingmatchesthis"))
  end)

  it("reports which column matched", function()
    local index = fresh("sqlite")
    if index.name ~= "sqlite" or not index:has_fts() then
      return
    end
    seed(index)

    assert.equals("memo", index:search("eviction")[1].matched_in)
    assert.equals("metadata", index:search("tetsuya")[1].matched_in)
    assert.equals("analyses", index:search("saturates")[1].matched_in)
    assert.equals("title", index:search("warmup")[1].matched_in:match("^title"))
  end)

  it("keeps the index in step when notes change", function()
    local index = fresh("sqlite")
    if index.name ~= "sqlite" or not index:has_fts() then
      return
    end
    seed(index)

    require("issuehub.core.overlay").write("jira://A", { memo = "completely different wording" })
    index:put(require("issuehub.core.cache").get("jira://A").issue)

    assert.equals(0, #index:search("eviction"))
    assert.equals(1, #index:search("wording"))
  end)

  it("restores note text on a rebuild", function()
    local index = fresh("sqlite")
    if index.name ~= "sqlite" or not index:has_fts() then
      return
    end
    seed(index)

    index:rebuild()
    -- The index holds no truth of its own, so a rebuild must recover the prose
    -- from the Repository.
    assert.equals(1, #index:search("eviction"))
  end)
end)

describe("bulk writes", function()
  local function many(n)
    local issues = {}
    for i = 1, n do
      issues[i] = make("B-" .. i, false, "2026-07-19T00:00:00Z")
    end
    return issues
  end

  it("indexes a batch in one round trip, not one per issue", function()
    local index = fresh("json")
    local calls = 0
    local original = index.put
    index.put = function(self, entry)
      calls = calls + 1
      return original(self, entry)
    end

    require("issuehub.core.cache").put_all(many(50))
    -- put_all must go through put_many; per-issue put would mean 50 sqlite3
    -- process spawns on the other backend.
    assert.equals(0, calls)
    assert.equals(50, #index:list())
  end)

  it("preserves bookmarks and last-seen markers across a batch", function()
    local index = fresh("json")
    require("issuehub.core.cache").put_all(many(3))
    index:set_bookmark("jira://B-1", true)
    index:set_seen("jira://B-1", "2026-07-19T00:00:00Z")

    require("issuehub.core.cache").put_all(many(3))

    local found
    for _, item in ipairs(index:list()) do
      if item.uri == "jira://B-1" then
        found = item
      end
    end
    -- User data must survive a re-sync; only payload fields are overwritten.
    assert.is_true(found.bookmarked)
    assert.equals("2026-07-19T00:00:00Z", found.seen_at)
  end)

  it("scans a provider's cache directory once per batch, not once per issue", function()
    fresh("json")
    local fs = require("issuehub.util.fs")
    local scans = 0
    local original = fs.list
    fs.list = function(dir)
      scans = scans + 1
      return original(dir)
    end

    require("issuehub.core.cache").put_all(many(100))
    fs.list = original

    -- The case-collision check used to list the whole directory per write,
    -- which is O(n²) for a bulk sync.
    assert.truthy(scans < 10, "directory scanned " .. scans .. " times for 100 writes")
  end)
end)
