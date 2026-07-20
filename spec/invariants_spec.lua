-- Invariants that must hold for EVERY provider, present and future.
--
-- Parameterised deliberately: the closed_at contradiction was found in one
-- provider (GitHub, against live data) but the shape is not GitHub-specific —
-- Jira's `resolutiondate` and Redmine's `closed_on` are not reliably cleared
-- when an issue is reopened, so the same payload can arrive from any of them.
-- A per-provider test would have to be remembered four times; this one cannot
-- be forgotten when a fifth provider is added.

local issue_mod = require("issuehub.core.issue")

local CASES = {
  {
    provider = "github",
    open_with_stale_close = {
      provider = "github",
      id = "o/r#1",
      status = { id = "open", name = "Open", closed = false },
      closed_at = "2026-07-01T10:00:00Z",
    },
  },
  {
    provider = "jira",
    -- A reopened Jira issue whose resolutiondate was not cleared.
    open_with_stale_close = {
      provider = "jira",
      id = "PROJ-1",
      status = { id = "1", name = "Reopened", closed = false },
      closed_at = "2026-07-01T10:00:00Z",
    },
  },
  {
    provider = "redmine",
    -- Same shape from Redmine's closed_on.
    open_with_stale_close = {
      provider = "redmine",
      id = "123",
      status = { id = "1", name = "New", closed = false },
      closed_at = "2026-07-01T10:00:00Z",
    },
  },
  {
    provider = "gitlab",
    open_with_stale_close = {
      provider = "gitlab",
      id = "g/p#1",
      status = { id = "opened", name = "Open", closed = false },
      closed_at = "2026-07-01T10:00:00Z",
    },
  },
}

describe("cross-provider invariants", function()
  for _, case in ipairs(CASES) do
    it(("%s: never carries closed_at while open"):format(case.provider), function()
      local issue = issue_mod.normalize(case.open_with_stale_close)
      assert.is_false(issue.status.closed)
      -- An open issue with a resolution timestamp is self-contradictory, and it
      -- silently corrupts any duration analysis built on those two columns.
      assert.is_nil(issue.closed_at)
    end)

    it(("%s: keeps closed_at when genuinely closed"):format(case.provider), function()
      local payload = vim.deepcopy(case.open_with_stale_close)
      payload.status.closed = true
      local issue = issue_mod.normalize(payload)
      assert.is_true(issue.status.closed)
      assert.equals("2026-07-01T10:00:00Z", issue.closed_at)
    end)
  end

  it("normalises closed_at to UTC like the other timestamps", function()
    local issue = issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      status = { id = "6", name = "Done", closed = true },
      closed_at = "2026-07-19T10:15:00.000+0900",
    })
    assert.equals("2026-07-19T01:15:00Z", issue.closed_at)
  end)

  it("leaves closed_at absent when the provider reports none", function()
    local issue = issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      status = { id = "6", name = "Done", closed = true },
    })
    assert.is_nil(issue.closed_at)
  end)

  it("keeps export's days_to_close empty for anything still open", function()
    -- The column that the contradiction would have corrupted.
    local config = require("issuehub.config")
    config.setup({ workspace = vim.fn.tempname(), index = "json" })
    require("issuehub.core.index").reset()
    require("issuehub.core.repository").forget_case_index()
    require("issuehub.core.repository").ensure()

    local open_issue = issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      title = "still open",
      status = { id = "1", name = "Open", closed = false },
      created_at = "2026-06-01T10:00:00Z",
      closed_at = "2026-06-11T10:00:00Z", -- stale, must be dropped
      updated_at = "2026-07-19T10:00:00Z",
    })
    require("issuehub.core.cache").put(open_issue)

    local rows = require("issuehub.core.export").rows(require("issuehub.ui.view").new({
      label = "x",
      items = { issue_mod.to_item(open_issue) },
    }))
    assert.equals("", rows[1].closed_at)
    assert.is_nil(rows[1].days_to_close)
    assert.truthy(rows[1].age_days and rows[1].age_days > 0)
  end)
end)
