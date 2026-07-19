local config = require("issuehub.config")
local issue_mod = require("issuehub.core.issue")
local listcache = require("issuehub.core.listcache")
local fetch = require("issuehub.core.fetch")
local providers = require("issuehub.provider")

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
