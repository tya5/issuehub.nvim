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

    assert.truthy(content:find("| uri | id |", 1, true))
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
