local config = require("issuehub.config")
local issue_mod = require("issuehub.core.issue")
local listcache = require("issuehub.core.listcache")
local fetch = require("issuehub.core.fetch")
local providers = require("issuehub.provider")
local lock = require("issuehub.core.lock")
local fs = require("issuehub.util.fs")

---Simulate another process holding a lock, by writing the file directly.
---`lock.acquire` is re-entrant WITHIN a process (keyed by path in memory), so
---acquiring it from the spec itself would not contend with fetch's own
---in-process acquire — writing straight to disk is what actually forces the
---code under test into the EEXIST path.
local function held_by_other(kind, name)
  local path = assert(lock.path(kind, name))
  fs.mkdirp(vim.fs.dirname(path))
  fs.write(
    path,
    vim.json.encode({ pid = 999999, hostname = "some-other-host", acquired_at = "2026-07-01T00:00:00Z", operation = "spec" })
  )
  return path
end

---A provider serving `total` issues in pages of `per_page`, recording calls.
local function paged_provider(total, per_page, opts)
  opts = opts or {}
  local P = {}
  P.__index = P
  return setmetatable({
    name = "demo",
    pages_served = 0,
    setup = function()
      return true
    end,
    health = function()
      return true, "fake"
    end,
    get = function(_, _, cb)
      cb(nil, nil)
    end,
    list = function(_, _, cb)
      cb(nil, {})
    end,
    search = function(_, _, cb)
      cb(nil, {})
    end,
    page = function(self, _, cursor, cb)
      local page = cursor or 1
      self.pages_served = self.pages_served + 1

      if opts.fail_on_page == page then
        return cb("simulated failure on page " .. page)
      end

      local issues = {}
      for i = (page - 1) * per_page + 1, math.min(page * per_page, total) do
        issues[#issues + 1] = issue_mod.normalize({
          provider = "demo",
          id = "D-" .. i,
          title = "Issue " .. i,
          status = { id = "1", name = "Open" },
          updated_at = "2026-07-19T10:00:00Z",
        })
      end
      cb(nil, issues, page * per_page < total and (page + 1) or nil)
    end,
  }, P)
end

local function fresh(provider)
  config.setup({
    workspace = vim.fn.tempname(),
    index = "json",
    providers = { demo = { url = "https://demo.example", token_env = "SPEC_FETCH" } },
  })
  vim.env.SPEC_FETCH = "t"
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").forget_case_index()
  require("issuehub.core.repository").ensure()
  providers.reset()
  providers.register("demo", provider)
end

---fetch.all yields between pages via vim.schedule, so drive the loop.
local function run(opts)
  local finished, result, error_message = false, nil, nil
  fetch.all("demo", opts or {}, function(err, r)
    error_message, result, finished = err, r, true
  end)
  vim.wait(5000, function()
    return finished
  end)
  return result, error_message
end

describe("fetch.all", function()
  it("walks every page into the cache", function()
    local provider = paged_provider(250, 100)
    fresh(provider)

    local result = run()
    assert.equals(3, result.pages)
    assert.equals(250, result.issues)

    -- Every issue is individually cached, not just listed.
    assert.truthy(require("issuehub.core.cache").get("demo://D-1"))
    assert.truthy(require("issuehub.core.cache").get("demo://D-250"))
    assert.equals(250, #require("issuehub.core.index").get():list())
  end)

  it("records the list separately, with its own freshness", function()
    fresh(paged_provider(150, 100))
    run()

    local list = assert(listcache.get("demo", nil))
    assert.equals(150, #list.uris)
    assert.is_true(list.complete)
    assert.equals(2, list.pages)
    -- "when did I last ask" is a fact about the list, not about any issue.
    assert.truthy(list.fetched_at:match("^%d%d%d%d%-"))
    assert.truthy(listcache.describe(list):find("ago"))
  end)

  it("keeps what it collected when a page fails, and can resume", function()
    fresh(paged_provider(500, 100, { fail_on_page = 3 }))

    local result, err = run()
    assert.truthy(err)
    assert.equals(200, result.issues)

    local list = assert(listcache.get("demo", nil))
    assert.is_false(list.complete)
    -- The cursor is what makes the walk resumable rather than restarted.
    assert.equals(3, list.cursor)

    -- Swap in a working provider WITHOUT resetting the workspace, so the
    -- partial list survives — that is the thing being tested.
    providers.reset()
    providers.register("demo", paged_provider(500, 100))

    local resumed = run({ resume = true })
    assert.equals(500, resumed.issues)
    local finished_list = listcache.get("demo", nil)
    assert.equals(500, #finished_list.uris)
    assert.is_true(finished_list.complete)
    -- Pages 1 and 2 were not re-fetched.
    assert.equals(500, #require("issuehub.core.index").get():list())
  end)

  it("stops when cancelled, without losing the pages already fetched", function()
    fresh(paged_provider(1000, 100))

    local finished, result = false, nil
    fetch.all("demo", {
      on_progress = function()
        fetch.cancel("demo")
      end,
    }, function(_, r)
      result, finished = r, true
    end)
    vim.wait(5000, function()
      return finished
    end)

    assert.is_true(result.cancelled)
    assert.equals(1, result.pages)
    assert.equals(100, #listcache.get("demo", nil).uris)
    assert.is_false(listcache.get("demo", nil).complete)
  end)

  it("refuses a second run for the same query", function()
    fresh(paged_provider(1000, 100))
    local errors = {}
    fetch.all("demo", {}, function() end)
    fetch.all("demo", {}, function(err)
      errors[#errors + 1] = err
    end)
    vim.wait(2000, function()
      return #fetch.active() == 0
    end)
    assert.truthy(errors[1] and errors[1]:find("already running"))
  end)

  it("stops at max when given one", function()
    fresh(paged_provider(1000, 100))
    local result = run({ max = 250 })
    assert.truthy(result.issues >= 250 and result.issues < 400)
  end)

  it("reports pages fetched but not cached, rather than a silent 'complete'", function()
    -- Simulates another process holding the provider's cache lock: cache.put_all
    -- fails for every page, but the walk itself (paging + listcache) still
    -- succeeds, so a run that finishes "complete" can still be missing every
    -- issue from disk. That gap is exactly what run.cache_failures exists to
    -- surface — this pins it does not silently vanish.
    fresh(paged_provider(150, 100))
    local saved = lock.timeout
    lock.timeout = 0
    local path = held_by_other("cache", "demo")

    local result = run()
    vim.uv.fs_unlink(path)
    lock.timeout = saved

    assert.equals(150, result.issues) -- seen, via the listcache walk
    assert.equals(2, #result.cache_failures) -- ...but neither page landed on disk
    assert.is_nil(require("issuehub.core.cache").get("demo://D-1"))
  end)

  it("stops the run cleanly (not a crash) when the list cache itself is locked", function()
    -- Before this was fixed, listcache.merge returned lock.with's raw nil on
    -- contention and fetch.lua indexed it unconditionally (`list.uris`) —
    -- a contended list-cache lock during a real fetch would throw instead of
    -- degrading. This is the fetch.lua-level guard for that crash: it is held
    -- from before the run starts, so the very first page's merge fails and
    -- `run.pages` is never incremented past 0 — pages only count once their
    -- list write actually lands, which is what keeps `--resume` honest.
    fresh(paged_provider(150, 100))
    local saved = lock.timeout
    lock.timeout = 0
    local path = held_by_other("lists", listcache.key("demo", nil))

    local result, err = run()
    vim.uv.fs_unlink(path)
    lock.timeout = saved

    assert.truthy(err)
    assert.truthy(err:find("locked by another process", 1, true))
    -- Did not crash indexing a nil list, and did not count an uncached page.
    assert.equals(0, result.pages)
  end)
end)

describe("listcache.merge", function()
  before_each(function()
    fresh(paged_provider(1, 1))
  end)

  it("keeps order and drops duplicates across pages", function()
    listcache.merge("demo", nil, { "demo://A", "demo://B" }, { cursor = 2 })
    local list = listcache.merge("demo", nil, { "demo://B", "demo://C" }, { cursor = nil })
    assert.same({ "demo://A", "demo://B", "demo://C" }, list.uris)
    assert.is_true(list.complete)
  end)

  it("keys by provider and query, so two servers do not share a list", function()
    listcache.merge("demo", nil, { "demo://A" }, {})
    listcache.merge("other", nil, { "other://A" }, {})
    assert.equals(1, #listcache.get("demo", nil).uris)
    assert.equals(1, #listcache.get("other", nil).uris)
    assert.not_equal(listcache.key("demo", nil), listcache.key("demo", "is:open"))
  end)

  it("resets on a fresh walk rather than growing forever", function()
    listcache.merge("demo", nil, { "demo://A", "demo://B" }, {})
    local list = listcache.merge("demo", nil, { "demo://C" }, { reset = true })
    assert.same({ "demo://C" }, list.uris)
  end)

  it("says so when never fetched", function()
    assert.equals("never fetched", listcache.describe(nil))
    assert.is_nil(listcache.age(nil))
  end)
end)
