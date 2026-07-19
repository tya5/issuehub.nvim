local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local overlay = require("issuehub.core.overlay")
local analysis = require("issuehub.core.analysis")
local backend = require("issuehub.backend")
local helpers = dofile("spec/helpers.lua")

local URI = "jira://PROJ-1"

local function make(overrides)
  return issue_mod.normalize(vim.tbl_extend("force", {
    provider = "jira",
    id = "PROJ-1",
    title = "Timeout on warmup",
    description = "the cache is cold",
    status = { id = "1", name = "Open" },
    updated_at = "2026-07-19T10:00:00Z",
  }, overrides or {}))
end

local function fresh(opts)
  config.setup(vim.tbl_extend("force", { workspace = vim.fn.tempname(), index = "json" }, opts or {}))
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").ensure()
  backend.reset()
  cache.put(make())
end

---A backend that records what it was asked and replies with canned text.
local function fake_backend(kinds)
  return {
    name = "fake",
    sent = {},
    setup = function()
      return true
    end,
    capabilities = function()
      return { kinds = kinds or { "analyze", "complete" }, streaming = false }
    end,
    discover = function(self, cb)
      cb(nil, self:capabilities())
    end,
    health = function()
      return true, "fake"
    end,
    send = function(self, req, opts, cb)
      self.sent[#self.sent + 1] = req
      if opts.on_chunk then
        opts.on_chunk("chunk")
      end
      cb(nil, { text = "the likely root cause is eviction", model = "fake-1" })
    end,
  }
end

describe("backend: none", function()
  before_each(function()
    fresh()
  end)

  it("is the default, and sends nothing anywhere", function()
    local active = assert(backend.get())
    assert.equals("none", active.name)
    assert.same({}, active:capabilities().kinds)
  end)

  it("refuses with an actionable message", function()
    local _, err = helpers.sync(function(cb)
      backend.send({ kind = "analyze", prompt = "x" }, {}, function(e, r)
        cb(e, r)
      end)
    end)
    assert.truthy(err:find("no backend configured"))
    assert.truthy(err:find("backends.a2a.url"))
  end)
end)

describe("backend registry", function()
  before_each(function()
    fresh()
  end)

  it("refuses a kind the backend does not advertise", function()
    backend.register("fake", fake_backend({ "analyze" }))
    config.setup({ workspace = config.get().workspace, backend = "fake" })
    backend.reset()
    backend.register("fake", fake_backend({ "analyze" }))

    local _, err = helpers.sync(function(cb)
      backend.complete("write me a haiku", {}, cb)
    end)
    -- Anticipating LLM completion means refusing it clearly, not sending a
    -- request the backend will not understand.
    assert.truthy(err:find("does not handle 'complete'"))
    assert.truthy(err:find("analyze"))
  end)

  it("routes a supported kind through", function()
    local fake = fake_backend()
    config.setup({ workspace = config.get().workspace, backend = "fake" })
    backend.reset()
    backend.register("fake", fake)

    local res = helpers.sync(function(cb)
      backend.complete("write me a haiku", {}, cb)
    end)
    assert.equals("the likely root cause is eviction", res.text)
    assert.equals("complete", fake.sent[1].kind)
  end)

  it("reports an unknown backend by name", function()
    config.setup({ workspace = config.get().workspace, backend = "nope" })
    backend.reset()
    local _, err = backend.get()
    assert.truthy(err:find("unknown backend 'nope'"))
  end)
end)

describe("analysis", function()
  before_each(function()
    fresh()
  end)

  it("saves prompt, response, and the revision it describes", function()
    local stamp = assert(analysis.save(URI, { prompt = "why?", response = "because", backend = "fake" }))
    local entry = assert(analysis.get(URI, stamp))

    assert.equals("why?", entry.prompt)
    assert.equals("because", entry.response)
    assert.equals("2026-07-19T10:00:00Z", entry.issue_updated_at)
  end)

  it("derives staleness rather than storing a flag", function()
    local stamp = assert(analysis.save(URI, { prompt = "p", response = "r" }))
    assert.equals("current", analysis.get(URI, stamp).status)

    -- The issue moves; nothing rewrites the analysis, yet it becomes outdated.
    cache.put(make({ updated_at = "2026-07-25T10:00:00Z" }))
    assert.equals("outdated", analysis.get(URI, stamp).status)

    -- And a revert makes it current again, which a stored flag could not do.
    cache.put(make())
    assert.equals("current", analysis.get(URI, stamp).status)
  end)

  it("lists newest first", function()
    -- Stamps are second-resolution, so write them directly to control order.
    local fs = require("issuehub.util.fs")
    local dir = analysis.dir(URI)
    for _, stamp in ipairs({ "2026-07-19T10-00-00Z", "2026-07-20T10-00-00Z" }) do
      fs.write(vim.fs.joinpath(dir, stamp, "response.md"), "r\n")
      fs.write(vim.fs.joinpath(dir, stamp, "prompt.md"), "p\n")
      fs.write(vim.fs.joinpath(dir, stamp, "metadata.yaml"), "created_at: " .. stamp .. "\n")
    end

    local entries = analysis.list(URI)
    assert.equals(2, #entries)
    assert.equals("2026-07-20T10-00-00Z", entries[1].stamp)
    assert.equals("2026-07-20T10-00-00Z", analysis.latest(URI).stamp)
  end)

  it("uses a stamp that is filesystem-safe and sorts", function()
    -- ':' is illegal on Windows and awkward in shells.
    assert.truthy(analysis.stamp():match("^%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%dZ$"))
  end)

  it("prefers the workspace prompt over the default", function()
    local prompt, source = analysis.prompt_for(URI)
    assert.equals("default", source)
    assert.truthy(prompt:find("root cause", 1, true))

    overlay.write(URI, { prompt = "focus on the retry path" })
    prompt, source = analysis.prompt_for(URI)
    assert.equals("focus on the retry path", prompt)
    assert.equals("workspace", source)
  end)

  it("builds context from the issue and the overlay", function()
    overlay.write(URI, { memo = "my notes", metadata = "risk: high" })
    local context = analysis.context(URI)
    assert.equals("Timeout on warmup", context.issue.title)
    assert.equals("my notes", context.overlay.memo)
  end)

  it("does not feed an outdated analysis back in", function()
    analysis.save(URI, { prompt = "p", response = "earlier finding" })
    assert.equals(1, #analysis.context(URI, { include_history = true }).documents)

    cache.put(make({ updated_at = "2026-07-25T10:00:00Z" }))
    -- Including it would propagate its staleness into the new answer.
    assert.equals(0, #analysis.context(URI, { include_history = true }).documents)
  end)
end)

describe("a2a request rendering", function()
  it("renders the workspace as labelled prose, not serialized tables", function()
    local a2a = require("issuehub.backend.a2a")
    local text = a2a.render({
      kind = "analyze",
      prompt = "What is the root cause?",
      context = {
        issue = { id = "PROJ-1", title = "Timeout", status = { name = "Open" }, description = "cold cache" },
        overlay = { memo = "suspect eviction", metadata = "risk: high" },
        selection = "line 42",
      },
    })

    assert.truthy(text:find("# PROJ-1  Timeout", 1, true))
    assert.truthy(text:find("## Description", 1, true))
    assert.truthy(text:find("suspect eviction", 1, true))
    assert.truthy(text:find("risk: high", 1, true))
    assert.truthy(text:find("## Selection", 1, true))
    -- The task goes last so the instruction is what the model reads most
    -- recently.
    assert.truthy(text:find("## Task\n\nWhat is the root cause?", 1, true))
  end)

  it("omits sections that are empty", function()
    local text = require("issuehub.backend.a2a").render({ kind = "analyze", prompt = "go", context = {} })
    assert.is_nil(text:find("## Memo", 1, true))
    assert.truthy(text:find("## Task", 1, true))
  end)
end)
