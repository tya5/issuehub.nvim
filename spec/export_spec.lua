local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local overlay = require("issuehub.core.overlay")
local collection = require("issuehub.core.collection")
local export = require("issuehub.core.export")
local view_mod = require("issuehub.ui.view")
local fs = require("issuehub.util.fs")

local function make(id, overrides)
  return issue_mod.normalize(vim.tbl_extend("force", {
    provider = "jira",
    id = id,
    title = "Timeout on warmup",
    status = { id = "1", name = "Open" },
    assignee = "tetsuya",
    labels = { "cache", "timeout" },
    url = "https://example.atlassian.net/browse/" .. id,
    updated_at = "2026-07-19T10:00:00Z",
  }, overrides or {}))
end

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").ensure()
end

local function view_of(...)
  local items = {}
  for _, issue in ipairs({ ... }) do
    cache.put(issue)
    items[#items + 1] = issue_mod.to_item(issue)
  end
  return view_mod.new({ source = "query", label = "Sprint A", items = items })
end

describe("export rows", function()
  before_each(fresh)

  it("combines the cached issue with the workspace overlay", function()
    local view = view_of(make("PROJ-1"))
    overlay.write("jira://PROJ-1", { memo = "my notes", metadata = "priority: high\nrisk: medium" })

    local rows, columns = export.rows(view)
    assert.equals(1, #rows)
    assert.equals("Timeout on warmup", rows[1].title)
    assert.equals("my notes", rows[1].memo)
    -- Free-form metadata is flattened rather than requiring a schema.
    assert.equals("high", rows[1]["meta.priority"])
    assert.truthy(vim.tbl_contains(columns, "meta.risk"))
  end)

  it("records fetched_at so staleness travels with the data", function()
    local rows = export.rows(view_of(make("PROJ-1")))
    -- An export is a snapshot of the cache, not of the tracker.
    assert.truthy(rows[1].fetched_at:match("^%d%d%d%d%-%d%d%-%d%d"))
  end)

  it("unions metadata columns across rows", function()
    local view = view_of(make("PROJ-1"), make("PROJ-2"))
    overlay.write("jira://PROJ-1", { metadata = "a: 1" })
    overlay.write("jira://PROJ-2", { metadata = "b: 2" })

    local _, columns = export.rows(view)
    assert.truthy(vim.tbl_contains(columns, "meta.a"))
    assert.truthy(vim.tbl_contains(columns, "meta.b"))
  end)

  it("exports the selection when there is one", function()
    local view = view_of(make("PROJ-1"), make("PROJ-2"))
    view:set_selected({ view:get_items()[1] })
    assert.equals(1, #export.rows(view))
  end)
end)

describe("csv export", function()
  before_each(fresh)

  it("quotes cells containing commas, quotes, and newlines", function()
    local view = view_of(make("PROJ-1", { title = 'a, b "quoted"' }))
    overlay.write("jira://PROJ-1", { memo = "line one\nline two" })

    local path = assert(export.write("csv", view, { path = vim.fn.tempname() .. ".csv" }))
    local content = fs.read(path)

    assert.truthy(content:find('"a, b ""quoted"""', 1, true))
    assert.truthy(content:find('"line one\nline two"', 1, true))
  end)

  it("joins multi-value fields with a separator that survives CSV", function()
    local path = assert(export.write("csv", view_of(make("PROJ-1")), { path = vim.fn.tempname() .. ".csv" }))
    assert.truthy(fs.read(path):find("cache; timeout", 1, true))
  end)
end)

describe("other formats", function()
  before_each(fresh)

  it("writes a markdown table and keeps memos as prose", function()
    local view = view_of(make("PROJ-1"))
    overlay.write("jira://PROJ-1", { memo = "multi\nline note" })

    local path = assert(export.write("markdown", view, { path = vim.fn.tempname() .. ".md" }))
    local content = fs.read(path)

    assert.truthy(content:find("| uri | provider | id |", 1, true))
    -- A table cell is the wrong shape for multi-line prose.
    assert.is_nil(content:match("|[^\n]*multi\nline"))
    assert.truthy(content:find("## Notes", 1, true))
    assert.truthy(content:find("multi\nline note", 1, true))
  end)

  it("writes valid json", function()
    local path = assert(export.write("json", view_of(make("PROJ-1")), { path = vim.fn.tempname() .. ".json" }))
    local decoded = vim.json.decode(fs.read(path))
    assert.equals("PROJ-1", decoded[1].id)
  end)

  it("writes yaml that parses back", function()
    local path = assert(export.write("yaml", view_of(make("PROJ-1")), { path = vim.fn.tempname() .. ".yaml" }))
    assert.truthy(fs.read(path):find("id: PROJ-1", 1, true))
  end)

  it("names the file after the view", function()
    local dir = vim.fn.tempname()
    fs.mkdirp(dir)
    local path = assert(export.write("csv", view_of(make("PROJ-1")), { path = dir .. "/sprint-a.csv" }))
    assert.truthy(path:find("sprint-a.csv", 1, true))
  end)

  it("rejects an unknown format by name", function()
    local _, err = export.write("xlsx", view_of(make("PROJ-1")))
    assert.truthy(err:find("unknown export format"))
  end)

  it("refuses to write an empty view", function()
    local _, err = export.write("csv", view_mod.new({ label = "empty", items = {} }))
    assert.equals("nothing to export", err)
  end)

  it("accepts a third-party exporter", function()
    export.register("txt", {
      ext = "txt",
      write = function(rows)
        return "count=" .. #rows
      end,
    })
    local path = assert(export.write("txt", view_of(make("PROJ-1")), { path = vim.fn.tempname() .. ".txt" }))
    assert.equals("count=1", fs.read(path))
  end)
end)

describe("collections", function()
  before_each(fresh)

  it("creates on first add and is idempotent", function()
    assert.is_true(collection.add("Sprint A", "jira://PROJ-1"))
    assert.is_false(collection.add("Sprint A", "jira://PROJ-1"))
    assert.same({ "jira://PROJ-1" }, collection.get("Sprint A").issues)
  end)

  it("slugifies the filename but keeps the display name", function()
    collection.add("Release 3.2!", "jira://PROJ-1")
    local loaded = assert(collection.get("release-3-2"))
    assert.equals("Release 3.2!", loaded.name)
    assert.same({ "release-3-2" }, collection.list())
  end)

  it("spans providers", function()
    collection.add("Mixed", "jira://PROJ-1")
    collection.add("Mixed", "github://o%2Fr%231")
    assert.equals(2, #collection.get("Mixed").issues)
  end)

  it("keeps members sorted so two machines diff cleanly", function()
    collection.add("S", "jira://B")
    collection.add("S", "jira://A")
    assert.same({ "jira://A", "jira://B" }, collection.get("S").issues)
  end)

  it("removes and deletes", function()
    collection.add("S", "jira://PROJ-1")
    assert.is_true(collection.remove("S", "jira://PROJ-1"))
    assert.is_false(collection.remove("S", "jira://PROJ-1"))
    assert.is_true(collection.delete("S"))
    assert.is_nil(collection.get("S"))
  end)

  it("reports which collections contain an issue", function()
    collection.add("A", "jira://PROJ-1")
    collection.add("B", "jira://PROJ-1")
    local names = collection.containing("jira://PROJ-1")
    table.sort(names)
    assert.same({ "A", "B" }, names)
  end)

  it("builds a view, keeping members that fell out of the cache", function()
    cache.put(make("PROJ-1"))
    collection.add("S", "jira://PROJ-1")
    collection.add("S", "jira://GONE-9")

    local view = assert(collection.to_view("S"))
    assert.equals(2, view:count())
    -- A collection is the user's list; dropping entries because a cache expired
    -- would be wrong.
    local titles = vim.tbl_map(function(item)
      return item.title
    end, view:get_items())
    assert.truthy(vim.tbl_contains(titles, "Timeout on warmup"))
  end)

  it("exports a collection view", function()
    cache.put(make("PROJ-1"))
    collection.add("Sprint A", "jira://PROJ-1")
    local path = assert(export.write("csv", collection.to_view("Sprint A"), { path = vim.fn.tempname() .. ".csv" }))
    assert.truthy(fs.read(path):find("PROJ-1", 1, true))
  end)
end)

describe("merged export source", function()
  local issuehub = require("issuehub")
  local workspace = require("issuehub.core.workspace")

  before_each(function()
    fresh()
    -- Cached and annotated.
    cache.put(make("PROJ-1"))
    overlay.write("jira://PROJ-1", { memo = "notes for one", metadata = "priority: high" })
    -- Cached, never annotated.
    cache.put(make("PROJ-2"))
    -- Annotated but never cached: months-old work whose payload expired.
    overlay.write("jira://PROJ-3", { memo = "notes only, no payload" })
  end)

  it("includes issues that have notes but no cache entry", function()
    local view = assert(issuehub.resolve_view("all"))
    local ids = vim.tbl_map(function(item)
      return item.id
    end, view:get_items())
    table.sort(ids)
    -- Exporting the index alone would silently drop PROJ-3.
    assert.same({ "PROJ-1", "PROJ-2", "PROJ-3" }, ids)
  end)

  it("leaves the issue columns blank rather than dropping the row", function()
    local rows = export.rows(assert(issuehub.resolve_view("all")))
    local by_id = {}
    for _, row in ipairs(rows) do
      by_id[row.id] = row
    end

    assert.equals("notes only, no payload", by_id["PROJ-3"].memo)
    assert.equals("", by_id["PROJ-3"].title)
    assert.equals("", by_id["PROJ-3"].fetched_at)

    -- And the other direction: cached with nothing written locally.
    assert.equals("Timeout on warmup", by_id["PROJ-2"].title)
    assert.equals("", by_id["PROJ-2"].memo)
    assert.is_nil(by_id["PROJ-2"]["meta.priority"])

    -- Both sides present where both exist.
    assert.equals("notes for one", by_id["PROJ-1"].memo)
    assert.equals("high", by_id["PROJ-1"]["meta.priority"])
  end)

  it("writes every row to csv", function()
    local path = assert(export.write("csv", assert(issuehub.resolve_view("all")), {
      path = vim.fn.tempname() .. ".csv",
    }))
    local content = fs.read(path)
    for _, id in ipairs({ "PROJ-1", "PROJ-2", "PROJ-3" }) do
      assert.truthy(content:find(id, 1, true))
    end
  end)

  it("scopes to one server when given a provider name", function()
    cache.put(issue_mod.normalize({
      provider = "github",
      id = "o/r#1",
      title = "elsewhere",
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-19T10:00:00Z",
    }))
    config.setup({
      workspace = config.get().workspace,
      index = "json",
      providers = { jira = { url = "https://x", token_env = "T" }, github = { token_env = "T" } },
    })

    local view = assert(issuehub.resolve_view("jira"))
    for _, item in ipairs(view:get_items()) do
      assert.truthy(item.uri:find("^jira://"))
    end
  end)

  it("prefers a collection over a provider of the same name", function()
    config.setup({
      workspace = config.get().workspace,
      index = "json",
      providers = { jira = { url = "https://x", token_env = "T" } },
    })
    collection.add("jira", "jira://PROJ-1")

    local view = assert(issuehub.resolve_view("jira"))
    -- You named the collection deliberately; that wins.
    assert.equals(1, view:count())
  end)

  it("names the unknown source in the error", function()
    local _, err = issuehub.resolve_view("nope")
    assert.truthy(err:find("nope", 1, true))
    assert.truthy(err:find("local|all|bookmarks|changed", 1, true))
  end)

  it("still carries bookmarks from the workspace", function()
    workspace.toggle_bookmark("jira://PROJ-3")
    local rows = export.rows(assert(issuehub.resolve_view("all")))
    for _, row in ipairs(rows) do
      if row.id == "PROJ-3" then
        assert.is_true(row.bookmarked)
      end
    end
  end)
end)

describe("columns for analysis", function()
  before_each(fresh)

  it("carries the dates a defect curve is built from", function()
    cache.put(make("PROJ-1", {
      created_at = "2026-06-01T10:00:00Z",
      closed_at = "2026-06-11T10:00:00Z",
      status = { id = "6", name = "Done", closed = true },
    }))
    local rows = export.rows(view_mod.new({
      label = "x",
      items = { issue_mod.to_item(cache.get("jira://PROJ-1").issue) },
    }))

    assert.equals("2026-06-01T10:00:00Z", rows[1].created_at)
    assert.equals("2026-06-11T10:00:00Z", rows[1].closed_at)
    -- Precomputed: date arithmetic in a spreadsheet is where these analyses
    -- usually go wrong.
    assert.equals(10, rows[1].days_to_close)
    assert.equals(10, rows[1].age_days)
  end)

  it("ages an open issue to now, and leaves days_to_close empty", function()
    cache.put(make("PROJ-2", { created_at = "2026-07-09T10:00:00Z" }))
    local rows = export.rows(view_mod.new({
      label = "x",
      items = { issue_mod.to_item(cache.get("jira://PROJ-2").issue) },
    }))

    assert.equals("", rows[1].closed_at)
    assert.is_nil(rows[1].days_to_close)
    -- Open issues still have an age, which is what a backlog curve plots.
    assert.truthy(rows[1].age_days and rows[1].age_days > 0)
  end)

  it("includes provider, reporter, and comment count", function()
    cache.put(make("PROJ-3", { reporter = "alice", raw = { comment_total = 7 } }))
    local rows = export.rows(view_mod.new({
      label = "x",
      items = { issue_mod.to_item(cache.get("jira://PROJ-3").issue) },
    }))

    assert.equals("jira", rows[1].provider)
    assert.equals("alice", rows[1].reporter)
    assert.equals(7, rows[1].comments)
  end)

  it("puts the analysis columns in a stable, useful order", function()
    local _, columns = export.rows(view_of(make("PROJ-1")))
    local position = {}
    for i, name in ipairs(columns) do
      position[name] = i
    end
    -- Identity, then the dates, then the rest.
    assert.truthy(position.id < position.created_at)
    assert.truthy(position.created_at < position.closed_at)
    assert.truthy(position.closed_at < position.assignee)
  end)

  it("leaves every date column blank for an issue with no payload", function()
    overlay.write("jira://GONE-1", { memo = "notes only" })
    local rows = export.rows(assert(require("issuehub").resolve_view("all")))
    for _, row in ipairs(rows) do
      if row.id == "GONE-1" then
        assert.equals("", row.created_at)
        assert.equals("", row.closed_at)
        assert.is_nil(row.age_days)
        assert.equals("notes only", row.memo)
      end
    end
  end)
end)
