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

describe("multibyte search", function()
  before_each(fresh)

  it("finds Japanese text in a memo via ripgrep", function()
    if not search.available() then
      return
    end
    cache.put(issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      title = "Timeout",
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-19T10:00:00Z",
    }))
    overlay.write("jira://PROJ-1", { memo = "認証まわりの調査メモ" })

    -- Two characters is the most common Japanese word length, and the length
    -- neither unicode61 nor trigram can match.
    local items = search.find("認証")
    assert.equals(1, #items)
    assert.equals("memo", items[1].matched_in)

    assert.equals(1, #search.find("調査"))
    assert.equals(0, #search.find("存在しない語"))
  end)
end)

describe("find engine routing", function()
  local issuehub = require("issuehub")

  it("sends non-ASCII queries to ripgrep even when FTS5 is available", function()
    config.setup({ workspace = vim.fn.tempname(), index = "sqlite" })
    require("issuehub.core.index").reset()
    repository.ensure()

    local index = require("issuehub.core.index").get()
    if index.name ~= "sqlite" or not index:has_fts() then
      return -- without FTS5 everything routes to ripgrep anyway
    end

    -- ASCII gets the ranked engine...
    assert.equals("index", issuehub.search_engine("eviction"))
    -- ...but FTS5 makes a whole Japanese run one token, so this must not.
    assert.equals("ripgrep", issuehub.search_engine("認証"))
    assert.equals("ripgrep", issuehub.search_engine("調査メモ"))
    -- and --regex always bypasses the index.
    assert.equals("ripgrep", issuehub.search_engine("cache.*", { regex = true }))
  end)

  it("uses ripgrep for everything when there is no FTS5", function()
    config.setup({ workspace = vim.fn.tempname(), index = "json" })
    require("issuehub.core.index").reset()
    repository.ensure()
    assert.equals("ripgrep", issuehub.search_engine("eviction"))
  end)
end)

describe("empty search", function()
  it("browses everything instead of erroring", function()
    -- "find nothing in particular" is a request to see the corpus and filter
    -- it, which is the same shape as :IssueHub open.
    config.setup({ workspace = vim.fn.tempname(), index = "json", ui = { picker = "select" } })
    require("issuehub.core.index").reset()
    repository.ensure()

    local browsed = false
    local issuehub = require("issuehub")
    local original = issuehub.browse
    issuehub.browse = function()
      browsed = true
    end
    issuehub.find("")
    issuehub.find("   ")
    issuehub.browse = original

    assert.is_true(browsed)
  end)

  it("says so when there is nothing cached for that server", function()
    config.setup({
      workspace = vim.fn.tempname(),
      index = "json",
      providers = { jira = { url = "https://example.atlassian.net", token_env = "X" } },
    })
    require("issuehub.core.index").reset()
    repository.ensure()

    local notified
    local original = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    -- One provider configured, so no prompt: it goes straight through.
    require("issuehub").browse()
    vim.notify = original

    assert.truthy(notified and notified:find("nothing cached for jira"))
  end)

  it("reports when no provider is configured at all", function()
    config.setup({ workspace = vim.fn.tempname(), index = "json" })
    require("issuehub.core.index").reset()
    repository.ensure()

    local notified
    local original = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    require("issuehub").browse()
    vim.notify = original

    assert.truthy(notified and notified:find("no providers configured"))
  end)
end)

describe("per-server scoping", function()
  local issuehub = require("issuehub")

  before_each(function()
    config.setup({
      workspace = vim.fn.tempname(),
      index = "json",
      providers = {
        jira = { url = "https://example.atlassian.net", token_env = "X" },
        github = { token_env = "Y" },
      },
    })
    require("issuehub.core.index").reset()
    repository.ensure()

    for _, spec in ipairs({ { "jira", "PROJ-1" }, { "jira", "PROJ-2" }, { "github", "o%2Fr%231" } }) do
      cache.put(issue_mod.normalize({
        provider = spec[1],
        id = spec[2],
        title = "issue " .. spec[2],
        status = { id = "1", name = "Open" },
        updated_at = "2026-07-19T10:00:00Z",
      }))
    end
  end)

  it("asks which server when several are configured", function()
    local asked
    local original = vim.ui.select
    vim.ui.select = function(items, opts)
      asked = { items = items, prompt = opts.prompt }
    end
    issuehub.browse()
    vim.ui.select = original

    assert.truthy(asked)
    table.sort(asked.items)
    assert.same({ "github", "jira" }, asked.items)
  end)

  it("shows only that server's issues", function()
    local shown
    local picker = require("issuehub.ui.picker")
    local original = picker.pick
    picker.pick = function(view)
      shown = view
    end
    issuehub.browse("jira")
    picker.pick = original

    -- Mixing trackers in one list makes ids ambiguous and filter terms mean
    -- different things per server, so each entry point is scoped.
    assert.equals(2, shown:count())
    for _, item in ipairs(shown:get_items()) do
      assert.truthy(item.uri:find("^jira://"))
    end
  end)

  it("does not prompt when only one server is configured", function()
    config.setup({
      workspace = config.get().workspace,
      index = "json",
      providers = { jira = { url = "https://example.atlassian.net", token_env = "X" } },
    })
    require("issuehub.core.index").reset()

    local prompted = false
    local original = vim.ui.select
    vim.ui.select = function()
      prompted = true
    end
    local picker = require("issuehub.ui.picker")
    local pick = picker.pick
    picker.pick = function() end
    issuehub.browse()
    picker.pick = pick
    vim.ui.select = original

    assert.is_false(prompted)
  end)
end)
