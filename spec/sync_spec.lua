local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local sync = require("issuehub.core.sync")
local workspace = require("issuehub.core.workspace")
local providers = require("issuehub.provider")
local helpers = dofile("spec/helpers.lua")

local URI = "demo://D-1"

local function make(overrides)
  return issue_mod.normalize(vim.tbl_extend("force", {
    provider = "demo",
    id = "D-1",
    title = "Timeout",
    description = "cold cache",
    status = { id = "1", name = "Open" },
    assignee = "tetsuya",
    labels = { "cache" },
    updated_at = "2026-07-19T10:00:00Z",
  }, overrides or {}))
end

---A provider that serves whatever the spec last set, so sync sees a moving
---remote without any network.
local function fake_provider(remote)
  local P = {}
  P.__index = P
  return setmetatable({
    name = "demo",
    remote = remote,
    setup = function()
      return true
    end,
    health = function()
      return true, "fake"
    end,
    list = function(self, _, cb)
      cb(nil, { self.remote })
    end,
    search = function(self, _, cb)
      cb(nil, { self.remote })
    end,
    get = function(self, _, cb)
      cb(nil, self.remote)
    end,
  }, P)
end

local provider

local function fresh(remote)
  config.setup({
    workspace = vim.fn.tempname(),
    index = "json",
    providers = { demo = { url = "https://demo.example", token_env = "SPEC_DEMO" } },
  })
  vim.env.SPEC_DEMO = "t"
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").ensure()
  providers.reset()
  provider = fake_provider(remote or make())
  providers.register("demo", provider)
end

describe("sync.diff", function()
  it("reports nothing for an unchanged issue", function()
    assert.is_nil(sync.diff(make(), make()))
  end)

  it("treats a first sighting as not a change", function()
    -- Newly cached is not something the user needs to review.
    assert.is_nil(sync.diff(nil, make()))
  end)

  it("names the fields that moved", function()
    local change = assert(sync.diff(make(), make({ status = { id = "2", name = "In Progress" }, assignee = "alice" })))
    assert.same({ "status", "assignee" }, change.fields)
    assert.equals("Open", change.previous_status)
    assert.equals("In Progress", change.status)
  end)

  it("detects description and label edits", function()
    local change = assert(sync.diff(make(), make({ description = "warm cache", labels = { "cache", "urgent" } })))
    assert.same({ "description", "labels" }, change.fields)
  end)

  it("counts added comments from the provider total, not the fetched slice", function()
    -- The fetched list is capped, so its length would understate the change.
    local old = make({ raw = { comment_total = 10 } })
    local new = make({ raw = { comment_total = 13 } })
    local change = assert(sync.diff(old, new))
    assert.equals(3, change.comments_added)
    assert.same({}, change.fields)
  end)

  it("does not report removed comments as additions", function()
    local change = sync.diff(make({ raw = { comment_total = 5 } }), make({ raw = { comment_total = 2 } }))
    assert.is_nil(change)
  end)

  it("describes a change in one line", function()
    local change = assert(sync.diff(make(), make({ status = { id = "2", name = "Done", closed = true } })))
    assert.equals("D-1: status Open → Done", sync.describe(change))
  end)
end)

describe("sync.one", function()
  before_each(function()
    fresh()
  end)

  it("updates the cache and reports the change", function()
    cache.put(make())
    provider.remote = make({ status = { id = "2", name = "Done", closed = true }, updated_at = "2026-07-20T10:00:00Z" })

    local change = helpers.sync(function(cb)
      sync.one(URI, cb)
    end)

    assert.truthy(change)
    assert.same({ "status" }, change.fields)
    assert.equals("Done", cache.get(URI).issue.status.name)
  end)

  it("never touches the overlay", function()
    require("issuehub.core.overlay").write(URI, { memo = "my notes" })
    cache.put(make())
    provider.remote = make({ title = "renamed upstream" })

    sync.one(URI, function() end)

    -- A remote edit must not rewrite what the user wrote.
    assert.equals("my notes", require("issuehub.core.overlay").read(URI).memo)
  end)

  it("reports no change when a partial entry is filled in", function()
    -- A list result has no description; completing it is not a "change".
    cache.put_all({ make({ description = "" }) })
    local change
    sync.one(URI, function(_, value)
      change = value
    end)
    assert.is_nil(change)
  end)
end)

describe("sync.many", function()
  before_each(function()
    fresh()
  end)

  it("summarises across issues and reports progress", function()
    cache.put(make())
    provider.remote = make({ status = { id = "2", name = "Done", closed = true } })

    local seen, result = {}, nil
    sync.many({ URI }, {
      on_progress = function(done, total)
        seen[#seen + 1] = ("%d/%d"):format(done, total)
      end,
    }, function(r)
      result = r
    end)

    assert.same({ "1/1" }, seen)
    assert.equals(1, #result.changes)
    assert.equals(1, result.total)
  end)

  it("handles an empty target list", function()
    local result
    sync.many({}, nil, function(r)
      result = r
    end)
    assert.equals(0, result.total)
  end)

  it("records failures without aborting the run", function()
    local result
    sync.many({ "nosuch://X" }, nil, function(r)
      result = r
    end)
    assert.equals(1, vim.tbl_count(result.errors))
    assert.equals(0, #result.changes)
  end)
end)

describe("changed since last seen", function()
  before_each(function()
    fresh()
  end)

  it("is false before the issue has ever been opened", function()
    cache.put(make())
    assert.is_false(workspace.changed_since_seen(URI))
    assert.equals(0, #sync.changed_since_seen())
  end)

  it("becomes true when the remote moves after a view", function()
    cache.put(make())
    workspace.touch(URI)
    assert.is_false(workspace.changed_since_seen(URI))

    cache.put(make({ updated_at = "2026-07-21T10:00:00Z" }))
    assert.is_true(workspace.changed_since_seen(URI))

    local changed = sync.changed_since_seen()
    assert.equals(1, #changed)
    assert.equals("D-1", changed[1].id)
  end)

  it("clears once the issue is viewed again", function()
    cache.put(make())
    workspace.touch(URI)
    cache.put(make({ updated_at = "2026-07-21T10:00:00Z" }))
    assert.equals(1, #sync.changed_since_seen())

    workspace.touch(URI)
    assert.equals(0, #sync.changed_since_seen())
  end)

  it("survives an index rebuild, because it lives in state.yaml", function()
    cache.put(make())
    workspace.touch(URI)
    cache.put(make({ updated_at = "2026-07-21T10:00:00Z" }))

    local index = require("issuehub.core.index").get()
    index:rebuild()
    assert.equals(1, #sync.changed_since_seen())
  end)
end)

describe("sync.targets", function()
  before_each(function()
    fresh()
  end)

  it("includes issues that have notes but fell out of the cache", function()
    cache.put(make())
    require("issuehub.core.overlay").write("demo://D-2", { memo = "notes only" })

    local targets = sync.targets()
    table.sort(targets)
    assert.same({ "demo://D-1", "demo://D-2" }, targets)
  end)

  it("does not duplicate an issue that is both cached and annotated", function()
    cache.put(make())
    require("issuehub.core.overlay").write(URI, { memo = "notes" })
    assert.equals(1, #sync.targets())
  end)
end)
