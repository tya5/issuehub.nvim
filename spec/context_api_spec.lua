local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local overlay = require("issuehub.core.overlay")
local attachment = require("issuehub.core.attachment")
local fs = require("issuehub.util.fs")
local issuehub = require("issuehub")

local URI = "jira://PROJ-1"

local function make(attachments)
  return issue_mod.normalize({
    provider = "jira",
    id = "PROJ-1",
    title = "Timeout on cache warmup",
    description = "warmup slow",
    status = { id = "1", name = "Open" },
    updated_at = "2026-07-19T10:00:00Z",
    attachments = attachments,
  })
end

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").forget_case_index()
  require("issuehub.core.repository").ensure()
end

describe("public context API", function()
  before_each(fresh)

  it("assembles the issue, the overlay, and attachment paths", function()
    cache.put(make({ { id = "1", filename = "trace.log", url = "https://x/1" } }))
    overlay.write(URI, { memo = "root cause was the cold cache" })

    local ctx = assert(issuehub.context(URI))
    assert.equals(URI, ctx.uri)
    assert.is_true(ctx.cached)
    assert.equals("Timeout on cache warmup", ctx.issue.title)
    assert.equals("root cause was the cold cache", ctx.overlay.memo)
    assert.equals(1, #ctx.attachments)
    assert.equals("trace.log", ctx.attachments[1].filename)
  end)

  it("gives attachments as paths, never as content — that is the token saving", function()
    cache.put(make({ { id = "1", filename = "big.log", url = "https://x/1" } }))
    local att = assert(issuehub.context(URI)).attachments[1]
    -- A path into .state, and no `text`/`content` field anywhere on the entry.
    assert.truthy(att.path:find("/.state/attachments/", 1, true))
    assert.is_nil(att.text)
    assert.is_nil(att.content)
  end)

  it("reports what is not yet downloaded rather than fetching it", function()
    cache.put(make({
      { id = "1", filename = "a.log", url = "https://x/1" },
      { id = "2", filename = "b.log", url = "https://x/2" },
    }))
    -- One is on disk, one is not.
    local path = attachment.list(URI)[1].path
    fs.mkdirp(vim.fs.dirname(path))
    fs.write(path, "bytes")

    local ctx = assert(issuehub.context(URI))
    -- The undownloaded one is named so the caller can fetch it first; nothing
    -- was fetched as a side effect of asking for context.
    assert.equals(1, #ctx.undownloaded)
    assert.equals("2", ctx.undownloaded[1])
    for _, a in ipairs(ctx.attachments) do
      assert.equals(a.id ~= "2", a.downloaded)
    end
  end)

  it("still returns context for an issue that is not cached", function()
    overlay.write(URI, { memo = "notes exist before any fetch" })
    local ctx = assert(issuehub.context(URI))
    assert.is_false(ctx.cached)
    assert.is_nil(ctx.issue)
    assert.equals("notes exist before any fetch", ctx.overlay.memo)
  end)

  it("includes analyses and translations only when asked", function()
    cache.put(make())
    issuehub.record_analysis(URI, { response = "prior finding" })

    assert.is_nil(issuehub.context(URI).analyses)
    local ctx = assert(issuehub.context(URI, { include_analyses = true }))
    assert.equals(1, #ctx.analyses)
  end)

  it("rejects a bad URI", function()
    local ctx, err = issuehub.context("nonsense")
    assert.is_nil(ctx)
    assert.truthy(err)
  end)
end)

describe("fetch_attachments (programmatic)", function()
  before_each(fresh)

  it("returns already-downloaded paths immediately, keyed by id", function()
    cache.put(make({ { id = "1", filename = "a.log", url = "https://x/1" } }))
    local path = attachment.list(URI)[1].path
    fs.mkdirp(vim.fs.dirname(path))
    fs.write(path, "bytes")

    local got
    issuehub.fetch_attachments(URI, { "1" }, function(res, err)
      got = { res = res, err = err }
    end)
    assert.is_nil(got.err)
    assert.equals(path, got.res.paths["1"])
    assert.same({}, got.res.failed)
  end)

  it("fetches all of them when no ids are given", function()
    cache.put(make({
      { id = "1", filename = "a.log", url = "https://x/1" },
      { id = "2", filename = "b.log", url = "https://x/2" },
    }))
    for _, att in ipairs(attachment.list(URI)) do
      fs.mkdirp(vim.fs.dirname(att.path))
      fs.write(att.path, "bytes")
    end
    local got
    issuehub.fetch_attachments(URI, nil, function(res)
      got = res
    end)
    assert.equals(2, vim.tbl_count(got.paths))
  end)

  it("reports an unknown id in failed rather than hanging the count", function()
    cache.put(make({ { id = "1", filename = "a.log", url = "https://x/1" } }))
    local path = attachment.list(URI)[1].path
    fs.mkdirp(vim.fs.dirname(path))
    fs.write(path, "b")

    local got
    issuehub.fetch_attachments(URI, { "1", "99" }, function(res)
      got = res
    end)
    assert.truthy(got.paths["1"])
    assert.equals("no such attachment", got.failed["99"])
  end)

  it("puts a download failure in failed, not the precondition error", function()
    -- No provider configured for this URI, so the fetch cannot succeed — that is
    -- a per-file failure, not a reason to fail the whole call.
    cache.put(make({ { id = "1", filename = "a.log", url = "https://x/1" } }))
    local got
    issuehub.fetch_attachments(URI, { "1" }, function(res, err)
      got = { res = res, err = err }
    end)
    assert.is_nil(got.err)
    assert.is_nil(got.res.paths["1"])
    assert.truthy(got.res.failed["1"])
  end)

  it("does nothing gracefully when there are no attachments", function()
    cache.put(make())
    local got = "unset"
    issuehub.fetch_attachments(URI, nil, function(res)
      got = res
    end)
    assert.same({ paths = {}, failed = {} }, got)
  end)

  it("rejects a bad URI through the error argument", function()
    local got
    issuehub.fetch_attachments("nonsense", nil, function(res, err)
      got = { res = res, err = err }
    end)
    assert.is_nil(got.res)
    assert.truthy(got.err)
  end)
end)

describe("recording an analysis from an external client", function()
  before_each(fresh)

  it("saves it into the issue's history, derived-staleness and all", function()
    cache.put(make())
    local stamp = assert(issuehub.record_analysis(URI, {
      response = "the agent's conclusion",
      backend = "reyn",
      model = "gpt-5.6",
    }))
    assert.truthy(stamp:match("^%d%d%d%d%-"))

    local analyses = require("issuehub.core.analysis").list(URI)
    assert.equals(1, #analyses)
    -- Recorded against the current revision, so staleness derives like any other.
    assert.equals("current", require("issuehub.core.analysis").latest(URI).status)
  end)

  it("refuses an empty response rather than writing a hollow entry", function()
    cache.put(make())
    local stamp, err = issuehub.record_analysis(URI, { response = "" })
    assert.is_nil(stamp)
    assert.truthy(err:find("non%-empty"))
  end)

  it("rejects a bad URI", function()
    local stamp, err = issuehub.record_analysis("nonsense", { response = "x" })
    assert.is_nil(stamp)
    assert.truthy(err)
  end)
end)
