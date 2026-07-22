local config = require("issuehub.config")
local collection = require("issuehub.core.collection")
local fs = require("issuehub.util.fs")

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").forget_case_index()
  require("issuehub.core.repository").ensure()
end

---Stub fs.write to fail every call, restoring it however the test ends.
---`local fs = require(...)` in collection.lua holds the SAME cached module
---table Lua's require() always returns, so patching the function here reaches
---the code under test without needing to inject a fake.
local function with_failing_write(fn)
  local original = fs.write
  fs.write = function()
    return false, "simulated disk failure"
  end
  local ok, err = pcall(fn)
  fs.write = original
  if not ok then
    error(err, 0)
  end
end

describe("collection.add/remove: a disk-write failure does not report success", function()
  before_each(fresh)

  it("add: returns false and the write error, not a plausible-but-wrong 'was already a member'", function()
    -- corpus-worthy: before this fix, M._add_locked ignored M.save's return
    -- value entirely and always returned true, so a failed write to disk was
    -- indistinguishable from a successful add.
    with_failing_write(function()
      local added, err = collection.add("Sprint A", "jira://PROJ-1")
      assert.is_false(added)
      assert.truthy(err)
      assert.truthy(err:find("simulated disk failure", 1, true))
    end)

    -- And nothing was actually persisted: with a working fs.write, the
    -- membership is still absent.
    local saved = collection.get("Sprint A")
    assert.is_true(saved == nil or not vim.tbl_contains(saved.issues, "jira://PROJ-1"))
  end)

  it("remove: returns false and the write error, not 'was not a member'", function()
    collection.save({ name = "Sprint A", issues = { "jira://PROJ-1" } })

    with_failing_write(function()
      local removed, err = collection.remove("Sprint A", "jira://PROJ-1")
      assert.is_false(removed)
      assert.truthy(err)
      assert.truthy(err:find("simulated disk failure", 1, true))
    end)

    -- The membership from before the failed write survives untouched.
    local saved = assert(collection.get("Sprint A"))
    assert.is_true(vim.tbl_contains(saved.issues, "jira://PROJ-1"))
  end)

  it("add: a genuine no-op (already a member) still returns false with no error", function()
    collection.save({ name = "Sprint A", issues = { "jira://PROJ-1" } })
    -- fs.write is never even reached in this path — save() only runs for an
    -- actual change — so this must stay a clean, error-free false.
    with_failing_write(function()
      local added, err = collection.add("Sprint A", "jira://PROJ-1")
      assert.is_false(added)
      assert.is_nil(err)
    end)
  end)
end)
