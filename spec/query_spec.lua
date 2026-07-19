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

describe("built-in fields as filters", function()
  local URI = "jira://P-1"

  before_each(function()
    config.setup({ workspace = vim.fn.tempname(), index = "json" })
    require("issuehub.core.index").reset()
    require("issuehub.core.repository").ensure()
    require("issuehub.core.cache").put(require("issuehub.core.issue").normalize({
      provider = "jira",
      id = "P-1",
      title = "Timeout",
      status = { id = "1", name = "In Progress" },
      assignee = "tya5",
      labels = { "cache", "perf" },
      updated_at = "2026-07-19T10:00:00Z",
    }))
  end)

  local function meta(input)
    return query.parse(input).meta
  end

  it("filters on status, state, assignee, and provider", function()
    -- Both spellings: hyphenated survives being typed without quotes, quoted
    -- is the tracker's own wording.
    assert.is_true(query.matches_meta(URI, meta("--meta status=in-progress")))
    assert.is_true(query.matches_meta(URI, meta('--meta "status=In Progress"')))
    assert.is_true(query.matches_meta(URI, meta("--meta state=open")))
    assert.is_false(query.matches_meta(URI, meta("--meta state=closed")))
    assert.is_true(query.matches_meta(URI, meta("--meta assignee=tya5")))
    assert.is_true(query.matches_meta(URI, meta("--meta provider=jira")))
  end)

  it("matches a label like a list value", function()
    assert.is_true(query.matches_meta(URI, meta("--meta labels=cache")))
    assert.is_false(query.matches_meta(URI, meta("--meta labels=nope")))
  end)

  it("tracks bookmarks", function()
    assert.is_false(query.matches_meta(URI, meta("--meta bookmarked=true")))
    require("issuehub.core.workspace").toggle_bookmark(URI)
    assert.is_true(query.matches_meta(URI, meta("--meta bookmarked=true")))
  end)

  it("lets metadata you wrote win over the tracker's field", function()
    -- The workspace is yours; a status you set deliberately should not be
    -- shadowed by the provider's.
    require("issuehub.core.overlay").write(URI, { metadata = "status: waiting-on-me" })
    assert.is_true(query.matches_meta(URI, meta("--meta status=waiting-on-me")))
    assert.is_false(query.matches_meta(URI, meta("--meta status=in-progress")))
  end)

  it("combines a built-in field with one you wrote", function()
    require("issuehub.core.overlay").write(URI, { metadata = "priority: high" })
    assert.is_true(query.matches_meta(URI, meta("--meta state=open --meta priority=high")))
    assert.is_false(query.matches_meta(URI, meta("--meta state=closed --meta priority=high")))
  end)
end)

describe("project scoping", function()
  local index_mod = require("issuehub.core.index")
  local cache = require("issuehub.core.cache")
  local issue_mod = require("issuehub.core.issue")

  local function seed(provider, project, id, updated)
    cache.put(issue_mod.normalize({
      provider = provider,
      project = project,
      id = id,
      title = id,
      status = { id = "1", name = "Open" },
      updated_at = updated,
    }))
  end

  before_each(function()
    config.setup({
      workspace = vim.fn.tempname(),
      index = "json",
      providers = { jira = { url = "https://x", token_env = "T" } },
    })
    index_mod.reset()
    require("issuehub.core.repository").forget_case_index()
    require("issuehub.core.repository").ensure()

    seed("jira", "PROJ", "PROJ-1", "2026-07-19T10:00:00Z")
    seed("jira", "PROJ", "PROJ-2", "2026-07-18T10:00:00Z")
    seed("jira", "OPS", "OPS-1", "2026-07-20T10:00:00Z")
  end)

  it("filters the index by project", function()
    local index = index_mod.get()
    assert.equals(3, #index:list({ provider = "jira" }))
    assert.equals(2, #index:list({ provider = "jira", project = "PROJ" }))
    assert.equals(1, #index:list({ provider = "jira", project = "OPS" }))
  end)

  it("lists the projects it has seen, most recently active first", function()
    -- OPS moved most recently, so it leads.
    assert.same({ "OPS", "PROJ" }, index_mod.get():projects("jira"))
  end)

  it("filters with --meta project=", function()
    assert.is_true(query.matches_meta("jira://PROJ-1", query.parse("--meta project=PROJ").meta))
    assert.is_false(query.matches_meta("jira://OPS-1", query.parse("--meta project=PROJ").meta))
  end)

  it("puts a project token on picker rows", function()
    local items = require("issuehub.ui.view").with_notes(index_mod.get():list({ provider = "jira" }))
    for _, item in ipairs(items) do
      assert.truthy(item.notes:find("project:" .. item.project:lower(), 1, true))
    end
  end)

  it("survives a rebuild", function()
    local index = index_mod.get()
    index:rebuild()
    assert.equals(2, #index:list({ provider = "jira", project = "PROJ" }))
  end)
end)

describe("provider project extraction", function()
  it("takes the Jira project key from the payload", function()
    local jira = require("issuehub.provider.jira").new("jira")
    jira:setup({ url = "https://example.atlassian.net" })
    local issue = jira:_to_issue({ key = "PROJ-123", fields = { project = { key = "PROJ" }, status = {} } })
    assert.equals("PROJ", issue.project)
  end)

  it("falls back to the key prefix when the field is absent", function()
    local jira = require("issuehub.provider.jira").new("jira")
    jira:setup({ url = "https://example.atlassian.net" })
    local issue = jira:_to_issue({ key = "PROJ-123", fields = { status = {} } })
    assert.equals("PROJ", issue.project)
  end)

  it("uses the repository for GitHub", function()
    local github = require("issuehub.provider.github").new("github")
    github:setup({})
    local issue = github:_to_issue({
      number = 7,
      state = "open",
      repository_url = "https://api.github.com/repos/tya5/issuehub.nvim",
    })
    assert.equals("tya5/issuehub.nvim", issue.project)
    assert.equals("tya5/issuehub.nvim#7", issue.id)
  end)

  it("uses the project path for GitLab", function()
    local gitlab = require("issuehub.provider.gitlab").new("gitlab")
    gitlab:setup({})
    local issue = gitlab:_to_issue({ iid = 12, references = { full = "group/proj#12" }, state = "opened" })
    assert.equals("group/proj", issue.project)
  end)

  it("takes the identifier from the Redmine payload, since ids carry none", function()
    local redmine = require("issuehub.provider.redmine").new("redmine")
    redmine:setup({ url = "https://redmine.example.com" })
    local issue = redmine:_to_issue({ id = 12345, subject = "x", status = {}, project = { identifier = "ops" } })
    assert.equals("ops", issue.project)
  end)
end)

describe("scope resolution", function()
  local issuehub = require("issuehub")

  local function seed(provider, project, id)
    require("issuehub.core.cache").put(require("issuehub.core.issue").normalize({
      provider = provider,
      project = project,
      id = id,
      title = id,
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-19T10:00:00Z",
    }))
  end

  before_each(function()
    config.setup({
      workspace = vim.fn.tempname(),
      index = "json",
      providers = { jira = { url = "https://x", token_env = "T" } },
    })
    require("issuehub.core.index").reset()
    require("issuehub.core.repository").forget_case_index()
    require("issuehub.core.repository").ensure()
  end)

  it("does not ask when there is only one project", function()
    seed("jira", "PROJ", "PROJ-1")
    local asked = false
    local original = vim.ui.select
    vim.ui.select = function()
      asked = true
    end

    local got
    issuehub.with_scope({}, function(provider, project)
      got = { provider, project }
    end)
    vim.ui.select = original

    assert.is_false(asked)
    assert.same({ "jira", "PROJ" }, got)
  end)

  it("asks once several projects exist, offering all", function()
    seed("jira", "PROJ", "PROJ-1")
    seed("jira", "OPS", "OPS-1")

    local offered
    local original = vim.ui.select
    vim.ui.select = function(items)
      offered = items
    end
    issuehub.with_scope({}, function() end)
    vim.ui.select = original

    assert.equals("(all projects)", offered[1])
    assert.equals(3, #offered)
  end)

  it("honours a configured project list without touching the index", function()
    config.setup({
      workspace = config.get().workspace,
      index = "json",
      providers = { jira = { url = "https://x", token_env = "T", projects = { "A", "B" } } },
    })
    local offered
    local original = vim.ui.select
    vim.ui.select = function(items)
      offered = items
    end
    issuehub.with_scope({}, function() end)
    vim.ui.select = original

    assert.same({ "(all projects)", "A", "B" }, offered)
  end)

  it("skips the prompt entirely with default_project", function()
    seed("jira", "PROJ", "PROJ-1")
    seed("jira", "OPS", "OPS-1")
    config.setup({
      workspace = config.get().workspace,
      index = "json",
      providers = { jira = { url = "https://x", token_env = "T", default_project = "OPS" } },
    })

    local got
    issuehub.with_scope({}, function(_, project)
      got = project
    end)
    assert.equals("OPS", got)
  end)

  it("with_provider never asks about projects", function()
    seed("jira", "PROJ", "PROJ-1")
    seed("jira", "OPS", "OPS-1")

    local asked = false
    local original = vim.ui.select
    vim.ui.select = function()
      asked = true
    end
    local got
    issuehub.with_provider(nil, "x", function(provider)
      got = provider
    end)
    vim.ui.select = original

    -- Fetching a whole server is inherently whole-server.
    assert.is_false(asked)
    assert.equals("jira", got)
  end)
end)
