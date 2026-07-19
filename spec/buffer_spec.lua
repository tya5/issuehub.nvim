local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local overlay = require("issuehub.core.overlay")
local render = require("issuehub.ui.render")
local buffer = require("issuehub.ui.buffer")

local URI = "jira://PROJ-1"

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json", sync = { on_open = "never" } })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").ensure()
  cache.put(issue_mod.normalize({
    provider = "jira",
    id = "PROJ-1",
    title = "Timeout on cache warmup",
    description = "Fails after 30s.",
    status = { id = "1", name = "Open" },
    updated_at = "2026-07-19T10:00:00Z",
  }))
end

local function open()
  buffer.open(URI)
  return vim.api.nvim_get_current_buf()
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function index_of(buf, text)
  for i, line in ipairs(lines(buf)) do
    if line == text then
      return i
    end
  end
end

describe("render sections", function()
  it("locates the three editable regions", function()
    local result = render.issue(
      issue_mod.normalize({ provider = "jira", id = "P-1", status = { id = "1", name = "Open" } }),
      nil,
      { memo = "m", metadata = "k: v", prompt = "p" }
    )
    local ranges = assert(render.parse_sections(result.lines))
    assert.truthy(ranges.memo and ranges.metadata and ranges.prompt)
    assert.truthy(result.readonly_until < ranges.memo.first)
  end)

  it("extracts what was rendered", function()
    local result = render.issue(
      issue_mod.normalize({ provider = "jira", id = "P-1", status = { id = "1", name = "Open" } }),
      nil,
      { memo = "line one\nline two", metadata = "priority: high", prompt = "" }
    )
    local content = assert(render.extract(result.lines))
    assert.equals("line one\nline two", content.memo)
    assert.equals("priority: high", content.metadata)
    assert.equals("", content.prompt)
  end)

  it("refuses to extract when a heading was destroyed", function()
    local result = render.issue(
      issue_mod.normalize({ provider = "jira", id = "P-1", status = { id = "1", name = "Open" } }),
      nil,
      nil
    )
    local without = vim.tbl_filter(function(line)
      return line ~= "## Metadata"
    end, result.lines)
    local content, err = render.extract(without)
    assert.is_nil(content)
    assert.truthy(err:find("Metadata"))
  end)
end)

describe("issue buffer", function()
  before_each(fresh)

  it("opens read-write with the issuehub filetype", function()
    local buf = open()
    assert.equals("issuehub", vim.bo[buf].filetype)
    assert.equals("acwrite", vim.bo[buf].buftype)
    -- Unlike 0.1, the buffer is modifiable: three regions are editable.
    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].modified)
  end)

  it("shows existing overlay content", function()
    overlay.write(URI, { memo = "earlier note" })
    local buf = open()
    assert.truthy(index_of(buf, "earlier note"))
  end)

  it("writes edited memo text on save", function()
    local buf = open()
    local memo_at = assert(index_of(buf, "## Memo"))
    vim.api.nvim_buf_set_lines(buf, memo_at + 1, memo_at + 1, false, { "typed by the user" })

    assert.is_true(buffer.save(buf))
    assert.equals("typed by the user", overlay.read(URI).memo)
    assert.is_false(vim.bo[buf].modified)
  end)

  it("writes metadata verbatim, preserving comments", function()
    local buf = open()
    local at = assert(index_of(buf, "## Metadata"))
    vim.api.nvim_buf_set_lines(buf, at + 1, at + 1, false, { "# why", "priority: high" })

    buffer.save(buf)
    assert.equals("# why\npriority: high", overlay.read(URI).metadata)
  end)

  it("writes nothing when nothing changed", function()
    overlay.write(URI, { memo = "unchanged" })
    local buf = open()
    assert.is_true(buffer.save(buf))
    assert.equals("unchanged", overlay.read(URI).memo)
  end)

  it("reverts an edit to the read-only issue section", function()
    local buf = open()
    local title = lines(buf)[1]

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# VANDALISED" })
    buffer._enforce(buf)

    -- Advisory by design (§6): Neovim has no per-region lock, so the edit is
    -- reverted rather than prevented.
    assert.equals(title, lines(buf)[1])
  end)

  it("keeps editable content while reverting a read-only edit", function()
    local buf = open()
    local memo_at = assert(index_of(buf, "## Memo"))
    vim.api.nvim_buf_set_lines(buf, memo_at + 1, memo_at + 1, false, { "keep me" })
    buffer._enforce(buf)

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# VANDALISED" })
    buffer._enforce(buf)

    assert.is_nil(index_of(buf, "# VANDALISED"))
    assert.truthy(index_of(buf, "keep me"))
  end)

  it("reverts wholesale when a section heading is deleted", function()
    local buf = open()
    local at = assert(index_of(buf, "## Metadata"))
    vim.api.nvim_buf_set_lines(buf, at - 1, at, false, {})
    buffer._enforce(buf)

    -- Without the heading the buffer cannot be mapped back onto files, so
    -- guessing is worse than restoring.
    assert.truthy(index_of(buf, "## Metadata"))
  end)

  it("removes the file when the user empties a section", function()
    overlay.write(URI, { memo = "to be deleted" })
    local buf = open()
    local at = assert(index_of(buf, "to be deleted"))
    vim.api.nvim_buf_set_lines(buf, at - 1, at, false, {})

    buffer.save(buf)
    assert.equals("", overlay.read(URI).memo)
  end)

  it("records the seen revision on open", function()
    open()
    assert.equals("2026-07-19T10:00:00Z", require("issuehub.core.workspace").state(URI).last_seen_updated_at)
  end)
end)

describe("issue header indicators", function()
  before_each(fresh)

  it("shows the changed marker on open, not only after a refresh", function()
    -- Regression: M.open once skipped render_opts, so the primary path — just
    -- opening an issue — showed neither indicator.
    open()
    cache.put(issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      title = "Timeout on cache warmup",
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-25T10:00:00Z",
    }))

    local buf = open()
    local header = table.concat(vim.api.nvim_buf_get_lines(buf, 0, 12, false), "\n")
    assert.truthy(header:find("Changed:", 1, true))
  end)

  it("shows the newest analysis and its staleness", function()
    open()
    require("issuehub.core.analysis").save(URI, { prompt = "p", response = "r", backend = "fake" })

    local header = table.concat(vim.api.nvim_buf_get_lines(open(), 0, 12, false), "\n")
    assert.truthy(header:find("Analysis:", 1, true))
    assert.truthy(header:find("(current)", 1, true))

    cache.put(issue_mod.normalize({
      provider = "jira",
      id = "PROJ-1",
      title = "Timeout on cache warmup",
      status = { id = "1", name = "Open" },
      updated_at = "2026-07-25T10:00:00Z",
    }))
    local moved = table.concat(vim.api.nvim_buf_get_lines(open(), 0, 12, false), "\n")
    assert.truthy(moved:find("(outdated)", 1, true))
  end)
end)
