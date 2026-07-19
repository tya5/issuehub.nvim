local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local overlay = require("issuehub.core.overlay")
local search = require("issuehub.core.search")
local repository = require("issuehub.core.repository")

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  repository.ensure()
end

describe("search.locate", function()
  before_each(fresh)

  it("maps a cache file back to its uri", function()
    local root = repository.root()
    local uri, field = search.locate(root, root .. "/.state/cache/jira/PROJ-1.json")
    assert.equals("jira://PROJ-1", uri)
    assert.equals("issue", field)
  end)

  it("maps overlay files to their field names", function()
    local root = repository.root()
    assert.same({ "jira://PROJ-1", "memo" }, { search.locate(root, root .. "/jira/PROJ-1/memo.md") })
    assert.same({ "jira://PROJ-1", "metadata" }, { search.locate(root, root .. "/jira/PROJ-1/metadata.yaml") })
    assert.same({ "jira://PROJ-1", "prompt" }, { search.locate(root, root .. "/jira/PROJ-1/prompt.md") })
  end)

  it("maps analysis history", function()
    local root = repository.root()
    local uri, field = search.locate(root, root .. "/jira/PROJ-1/analyses/2026-07-19T13-24-18Z/response.md")
    assert.equals("jira://PROJ-1", uri)
    assert.equals("analysis", field)
  end)

  it("keeps percent-encoded ids intact", function()
    local root = repository.root()
    local uri = search.locate(root, root .. "/github/o%2Fr%231/memo.md")
    assert.equals("github://o%2Fr%231", uri)
  end)

  it("ignores paths outside the known layout", function()
    local root = repository.root()
    assert.is_nil(search.locate(root, root .. "/.issuehub/version"))
  end)
end)

describe("search.grep", function()
  before_each(fresh)

  local function seed()
    cache.put(issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      title = "Timeout on warmup",
      description = "the cache is cold",
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-19T10:00:00Z",
    }))
    overlay.write("jira://PROJ-1", { memo = "suspect the eviction policy", metadata = "risk: high" })
  end

  it("is skipped cleanly when ripgrep is absent", function()
    if not search.available() then
      local _, err = search.grep("anything")
      assert.truthy(err:find("ripgrep"))
      return
    end

    seed()
    local hits = search.grep("eviction")
    assert.equals(1, #hits)
    assert.equals("memo", hits[1].field)
    assert.truthy(hits[1].line:find("eviction", 1, true))
  end)

  it("finds text in the cached issue as well as the overlay", function()
    if not search.available() then
      return
    end
    seed()
    local fields = {}
    for _, hit in ipairs(search.grep("cold")) do
      fields[#fields + 1] = hit.field
    end
    assert.truthy(vim.tbl_contains(fields, "issue"))
  end)

  it("treats the pattern as a fixed string by default", function()
    if not search.available() then
      return
    end
    seed()
    -- Without --fixed-strings this would match "the cache is cold" via `.`.
    assert.equals(0, #search.grep("cache.is"))
    assert.equals(1, #search.grep("cache.is", { regex = true }))
  end)

  it("annotates results with where they matched", function()
    if not search.available() then
      return
    end
    seed()
    local items = search.find("high")
    assert.equals(1, #items)
    assert.equals("metadata", items[1].matched_in)
    -- Known issues carry their real title, not a placeholder.
    assert.equals("Timeout on warmup", items[1].title)
  end)

  it("collapses several fields of one issue into a single row", function()
    if not search.available() then
      return
    end
    seed()
    overlay.write("jira://PROJ-1", { memo = "warmup notes", prompt = "warmup prompt" })
    local items = search.find("warmup")
    assert.equals(1, #items)
    assert.truthy(items[1].matched_in:find("memo", 1, true))
    assert.truthy(items[1].matched_in:find("prompt", 1, true))
  end)

  it("returns nothing rather than erroring when there are no matches", function()
    if not search.available() then
      return
    end
    seed()
    local hits, err = search.grep("nothing-matches-this")
    assert.is_nil(err)
    assert.equals(0, #hits)
  end)
end)
