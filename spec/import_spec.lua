local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local overlay = require("issuehub.core.overlay")
local importer = require("issuehub.core.import")
local export = require("issuehub.core.export")
local workspace = require("issuehub.core.workspace")
local fs = require("issuehub.util.fs")

local URI = "jira://PROJ-1"

local function make(id, overrides)
  return issue_mod.normalize(vim.tbl_extend("force", {
    provider = "jira",
    id = id,
    title = "Timeout on warmup",
    status = { id = "1", name = "Open" },
    labels = { "cache", "timeout" },
    updated_at = "2026-07-19T10:00:00Z",
  }, overrides or {}))
end

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").forget_case_index()
  require("issuehub.core.repository").ensure()
end

local function write(name, text)
  local path = vim.fn.tempname() .. name
  fs.write(path, text)
  return path
end

describe("csv parsing", function()
  it("handles the quoting export emits", function()
    local rows = importer.parse_csv('a,b,c\n1,"has, comma","says ""hi"""\n')
    assert.same({ "a", "b", "c" }, rows[1])
    assert.same({ "1", "has, comma", 'says "hi"' }, rows[2])
  end)

  it("handles a newline inside a quoted field", function()
    -- Multi-line memos are the reason this matters.
    local rows = importer.parse_csv('uri,memo\njira://A,"line one\nline two"\n')
    assert.equals(2, #rows)
    assert.equals("line one\nline two", rows[2][2])
  end)

  it("does not invent a trailing empty record", function()
    assert.equals(2, #importer.parse_csv("a\n1\n"))
  end)
end)

describe("import: what it merges", function()
  before_each(fresh)

  it("brings back memo, metadata, and bookmark", function()
    local path = write(".csv", table.concat({
      "uri,title,status,memo,bookmarked,meta.priority",
      'jira://PROJ-1,"ignored title",Closed,"my notes",true,high',
    }, "\n"))

    local result = assert(importer.run(path))
    assert.same({ URI }, result.imported)
    assert.equals("my notes", overlay.read(URI).memo)
    assert.equals("high", overlay.metadata(URI).priority)
    assert.is_true(workspace.state(URI).bookmarked)
  end)

  it("reads and discards the issue columns", function()
    cache.put(make("PROJ-1"))
    local path = write(".csv", table.concat({
      "uri,title,status,closed,updated_at,memo",
      "jira://PROJ-1,VANDALISED,Closed,true,1999-01-01T00:00:00Z,notes",
    }, "\n"))
    importer.run(path)

    -- The tracker owns these; a stale spreadsheet must not rewrite the cache.
    local issue = cache.get(URI).issue
    assert.equals("Timeout on warmup", issue.title)
    assert.equals("Open", issue.status.name)
    assert.is_false(issue.status.closed)
    assert.equals("2026-07-19T10:00:00Z", issue.updated_at)
  end)

  it("creates entries for issues with no local content yet", function()
    local path = write(".csv", "uri,memo\njira://NEW-9,fresh notes\n")
    assert.same({ "jira://NEW-9" }, importer.run(path).imported)
    assert.equals("fresh notes", overlay.read("jira://NEW-9").memo)
  end)

  it("skips and reports a row whose uri is not an issue URI", function()
    local path = write(".csv", "uri,memo\nnot-a-uri,x\njira://OK-1,y\n")
    local result = assert(importer.run(path))
    assert.same({ "jira://OK-1" }, result.imported)
  end)

  it("refuses a file with no importable rows", function()
    local result, err = importer.run(write(".csv", "title,status\nx,y\n"))
    assert.is_nil(result)
    assert.truthy(err:find("no importable rows"))
  end)
end)

describe("import: conflicts", function()
  before_each(fresh)

  it("lets the file win, and says what it replaced", function()
    overlay.write(URI, { memo = "written in nvim" })
    local path = write(".csv", "uri,memo\njira://PROJ-1,edited in a spreadsheet\n")

    local result = assert(importer.run(path))
    assert.equals("edited in a spreadsheet", overlay.read(URI).memo)
    assert.equals(1, #result.overwritten)
    assert.equals(URI, result.overwritten[1].uri)
    assert.equals("memo", result.overwritten[1].field)
  end)

  it("counts an identical row as unchanged rather than overwritten", function()
    overlay.write(URI, { memo = "same" })
    local result = assert(importer.run(write(".csv", "uri,memo\njira://PROJ-1,same\n")))
    assert.equals(0, #result.imported)
    assert.equals(1, result.unchanged)
    assert.equals(0, #result.overwritten)
  end)

  it("writes nothing under --dry-run but reports the same thing", function()
    overlay.write(URI, { memo = "original" })
    local path = write(".csv", "uri,memo\njira://PROJ-1,replacement\n")

    local result = assert(importer.run(path, { dry_run = true }))
    assert.same({ URI }, result.imported)
    assert.equals(1, #result.overwritten)
    -- ...and the file on disk is untouched.
    assert.equals("original", overlay.read(URI).memo)
  end)

  it("preserves metadata keys the import does not mention", function()
    overlay.write(URI, { metadata = "priority: low\nowner: tya5" })
    importer.run(write(".csv", "uri,meta.priority\njira://PROJ-1,high\n"))

    local meta = overlay.metadata(URI)
    assert.equals("high", meta.priority)
    assert.equals("tya5", meta.owner)
  end)

  it("reports that metadata comments were lost, because they are", function()
    -- metadata.yaml is normally written back verbatim; an import regenerates it.
    overlay.write(URI, { metadata = "# why this matters\npriority: low" })
    local result = assert(importer.run(write(".csv", "uri,meta.priority\njira://PROJ-1,high\n")))

    assert.same({ URI }, result.metadata_comments)
    assert.is_nil(overlay.read(URI).metadata:find("why this matters", 1, true))
  end)

  it("leaves a field alone when its column is absent", function()
    overlay.write(URI, { memo = "keep me", metadata = "priority: high" })
    importer.run(write(".csv", "uri,meta.risk\njira://PROJ-1,medium\n"))

    -- Absent column means "not in this file", not "clear it".
    assert.equals("keep me", overlay.read(URI).memo)
    assert.equals("high", overlay.metadata(URI).priority)
  end)
end)

describe("import: json and round-trip", function()
  before_each(fresh)

  it("accepts the json export shape", function()
    local path = write(".json", vim.json.encode({
      { uri = URI, title = "ignored", memo = "from json", ["meta.priority"] = "high" },
    }))
    assert.same({ URI }, importer.run(path).imported)
    assert.equals("from json", overlay.read(URI).memo)
    assert.equals("high", overlay.metadata(URI).priority)
  end)

  it("round-trips export → import with no changes", function()
    cache.put(make("PROJ-1"))
    overlay.write(URI, { memo = "line one\nline two, with a comma", metadata = "priority: high" })
    workspace.toggle_bookmark(URI)

    local view = require("issuehub.ui.view").new({
      label = "rt",
      items = { issue_mod.to_item(cache.get(URI).issue, true) },
    })
    local csv = assert(export.write("csv", view, { path = vim.fn.tempname() .. ".csv" }))

    -- Importing an untouched export must be a no-op, or the two are not inverse.
    local result = assert(importer.run(csv))
    assert.equals(0, #result.imported)
    assert.equals(1, result.unchanged)
    assert.equals("line one\nline two, with a comma", overlay.read(URI).memo)
  end)

  it("survives a multi-line memo through the csv round-trip", function()
    local memo = "調査メモ\n\n- 認証まわり\n- 次: staging"
    overlay.write(URI, { memo = memo })
    cache.put(make("PROJ-1"))

    local view = require("issuehub.ui.view").new({
      label = "rt",
      items = { issue_mod.to_item(cache.get(URI).issue) },
    })
    local csv = assert(export.write("csv", view, { path = vim.fn.tempname() .. ".csv" }))

    overlay.write(URI, { memo = "" })
    importer.run(csv)
    assert.equals(memo, overlay.read(URI).memo)
  end)
end)
