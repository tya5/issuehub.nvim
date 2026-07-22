local config = require("issuehub.config")
local lock = require("issuehub.core.lock")
local overlay = require("issuehub.core.overlay")
local workspace = require("issuehub.core.workspace")
local repository = require("issuehub.core.repository")
local fs = require("issuehub.util.fs")

local URI = "jira://PROJ-1"

local function fresh()
  lock.reset()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  repository.forget_case_index()
  repository.ensure()
end

---Pretend another process holds a lock, by writing the file it would write.
local function held_by_other(kind, name, operation)
  local path = assert(lock.path(kind, name))
  fs.mkdirp(vim.fs.dirname(path))
  fs.write(
    path,
    vim.json.encode({
      pid = 999999,
      hostname = "some-other-host",
      acquired_at = "2026-07-01T00:00:00Z",
      operation = operation or "cache.put",
    })
  )
  return path
end

describe("lock files", function()
  before_each(fresh)

  it("names each kind where the CLI expects it", function()
    -- A shared on-disk contract: the other implementation looks for these
    -- exact paths, so a rename here is a protocol break, not a refactor.
    assert.truthy(lock.path("subject", URI):find("/.state/lock/subject/jira_PROJ%-1%.lock$"))
    assert.truthy(lock.path("subject", "collection:sprint-a"):find("/subject/%.issuehub_collections_sprint%-a%.lock$"))
    assert.truthy(lock.path("cache", "jira"):find("/.state/lock/cache/jira%.lock$"))
    assert.truthy(lock.path("lists", "jira-abc123"):find("/.state/lock/lists/jira%-abc123%.lock$"))
  end)

  it("records who holds it, and removes the file on release", function()
    local handle = assert(lock.acquire("subject", URI, "spec.acquire"))
    local owner = vim.json.decode(assert(fs.read(handle.path)))
    assert.equals(vim.uv.os_getpid(), owner.pid)
    assert.equals("spec.acquire", owner.operation)
    assert.truthy(owner.acquired_at:match("^%d%d%d%d%-.*Z$"))

    lock.release(handle)
    assert.is_false(fs.exists(handle.path))
  end)

  it("refuses a lock another process holds, and says who", function()
    local path = held_by_other("subject", URI, "importer.apply")
    local handle, err = lock.acquire("subject", URI, "spec.contend", { timeout = 0 })

    assert.is_nil(handle)
    assert.truthy(err:find("importer.apply", 1, true))
    assert.truthy(err:find("some-other-host", 1, true))
    -- Never broken automatically, however old or dead it looks: every liveness
    -- check is unreliable exactly where breaking would do the most damage.
    assert.is_true(fs.exists(path))
    assert.truthy(err:find("remove", 1, true))
  end)

  it("is re-entrant, because acquisition nests", function()
    -- import takes a subject lock and calls overlay.write, which takes the
    -- same one. Without this that is not contention, it is a process waiting
    -- for itself.
    local outer = assert(lock.acquire("subject", URI, "outer"))
    local inner = assert(lock.acquire("subject", URI, "inner", { timeout = 0 }))
    lock.release(inner)
    -- Still held: the inner release must not free the outer one.
    assert.is_true(fs.exists(outer.path))
    lock.release(outer)
    assert.is_false(fs.exists(outer.path))
  end)

  it("releases even when the protected operation fails", function()
    local _, err = lock.with("subject", URI, "spec.raise", function()
      error("boom")
    end)
    assert.truthy(err:find("boom", 1, true))
    -- A leaked lock file would block every later write until a human deleted
    -- it, turning one failed write into a stuck workspace.
    assert.is_false(fs.exists(assert(lock.path("subject", URI))))
  end)

  it("recreates .state/lock when it is missing, because .state is disposable", function()
    vim.fn.delete(assert(repository.state("lock")), "rf")
    local handle = assert(lock.acquire("subject", URI, "spec.recreate"))
    assert.is_true(fs.exists(handle.path))
    lock.release(handle)
  end)
end)

describe("writes take their lock", function()
  before_each(fresh)

  it("blocks an overlay write while another process holds the subject", function()
    held_by_other("subject", URI, "cli.overlay.write")
    lock.timeout = 0

    local written, err = overlay.write(URI, { memo = "mine" })
    assert.same({}, written)
    assert.truthy(err:find("locked by another process", 1, true))
    -- Refused, not merged and not overwritten.
    assert.equals("", overlay.read(URI).memo)

    lock.timeout = 10000
  end)

  it("blocks a state write the same way", function()
    held_by_other("subject", URI, "cli.workspace.set_state")
    lock.timeout = 0

    local ok, err = workspace.set_state(URI, { bookmarked = true })
    assert.is_false(ok)
    assert.truthy(err:find("locked by another process", 1, true))
    assert.is_false(workspace.state(URI).bookmarked)

    lock.timeout = 10000
  end)

  it("takes the provider directory lock for a cache write, not a per-issue one", function()
    -- The case-collision guard compares two DIFFERENT ids that collide on a
    -- case-insensitive filesystem, so a per-issue lock would leave the two
    -- racing writers locking two different names and serialising nothing.
    held_by_other("cache", "jira", "cli.cache.put")
    lock.timeout = 0

    local ok, err = require("issuehub.core.cache").put(require("issuehub.core.issue").normalize({
      provider = "jira",
      id = "PROJ-9",
      title = "x",
      status = { id = "1", name = "Open" },
    }))
    assert.is_false(ok)
    assert.truthy(err:find("locked by another process", 1, true))

    lock.timeout = 10000
  end)
end)

describe("the optimistic check", function()
  before_each(fresh)

  it("refuses when the file moved since the caller read it", function()
    overlay.write(URI, { memo = "as opened" })
    local baseline = overlay.read(URI)

    -- Somebody else — a text editor, say — edits the file. No lock was
    -- involved, and none could have been.
    overlay.write(URI, { memo = "edited in vim by hand" })

    local written, err = overlay.write(URI, { memo = "stale buffer contents" }, { baseline = baseline })
    assert.same({}, written)
    assert.truthy(err:find("changed on disk", 1, true))
    -- The hand-edit survives; nothing was merged and nothing overwritten.
    assert.equals("edited in vim by hand", overlay.read(URI).memo)
  end)

  it("allows the write when nothing moved", function()
    overlay.write(URI, { memo = "as opened" })
    local baseline = overlay.read(URI)
    local written = overlay.write(URI, { memo = "my edit" }, { baseline = baseline })
    assert.same({ "memo" }, written)
    assert.equals("my edit", overlay.read(URI).memo)
  end)

  it("does not mistake a trailing newline for someone else's edit", function()
    overlay.write(URI, { memo = "text" })
    local unchanged = lock.unchanged(assert(overlay.path(URI, "memo")), "text")
    assert.is_true(unchanged)
  end)

  it("reports a deletion distinctly from an edit", function()
    overlay.write(URI, { memo = "text" })
    local path = assert(overlay.path(URI, "memo"))
    vim.uv.fs_unlink(path)
    local ok, err = lock.unchanged(path, "text")
    assert.is_false(ok)
    assert.truthy(err:find("deleted", 1, true))
  end)
end)

-- Self-review regression coverage: every one of these failed silently before
-- being fixed, because the caller either ignored lock.with's second return
-- value or (worse, for listcache.merge) trusted a nil first value outright.
describe("lock contention does not masquerade as a normal no-op", function()
  before_each(fresh)

  it("workspace.toggle_bookmark: returns the error, not just the unchanged state", function()
    held_by_other("subject", URI, "cli.workspace.set_state")
    lock.timeout = 0

    local before = workspace.state(URI).bookmarked
    local value, err = workspace.toggle_bookmark(URI)
    assert.equals(before, value) -- unchanged
    assert.truthy(err) -- ...but the caller can tell it did not actually toggle

    lock.timeout = 10000
  end)

  it("cache.put_all: reports which provider's batch was skipped", function()
    held_by_other("cache", "jira", "cli.cache.put_all")
    lock.timeout = 0

    local cache = require("issuehub.core.cache")
    local issue_mod = require("issuehub.core.issue")
    local written, failed = cache.put_all({
      issue_mod.normalize({ provider = "jira", id = "PROJ-9", title = "x", status = { id = "1", name = "Open" } }),
    })
    assert.equals(0, written)
    assert.truthy(failed)
    assert.truthy(failed:find("jira", 1, true))

    lock.timeout = 10000
  end)

  it("listcache.merge: returns nil + err instead of crashing a caller that indexes the result", function()
    held_by_other("lists", require("issuehub.core.listcache").key("jira", nil), "cli.listcache.merge")
    lock.timeout = 0

    local list, err = require("issuehub.core.listcache").merge("jira", nil, { "jira://PROJ-1" }, { complete = true })
    -- The old code returned lock.with's raw result: a bare `nil`, which a
    -- caller doing `list.uris` would crash on. This is the contract that
    -- fetch.lua's step() now checks before touching `list`.
    assert.is_nil(list)
    assert.truthy(err)

    lock.timeout = 10000
  end)

  it("collection.add/remove/delete: distinguish contention from a genuine no-op", function()
    local collection = require("issuehub.core.collection")
    collection.save({ name = "Sprint A", issues = {} })

    held_by_other("subject", "collection:sprint-a", "cli.collection.add")
    lock.timeout = 0

    local added, add_err = collection.add("Sprint A", "jira://PROJ-1")
    assert.is_false(added)
    assert.truthy(add_err) -- not "was already a member" — the lock was held

    local removed, remove_err = collection.remove("Sprint A", "jira://PROJ-1")
    assert.is_false(removed)
    assert.truthy(remove_err) -- not "was not a member"

    local deleted, delete_err = collection.delete("Sprint A")
    assert.is_false(deleted)
    assert.truthy(delete_err) -- not "did not exist"

    lock.timeout = 10000
  end)
end)
