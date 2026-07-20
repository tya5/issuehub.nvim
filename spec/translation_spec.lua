local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local translation = require("issuehub.core.translation")
local fs = require("issuehub.util.fs")

local URI = "jira://PROJ-1"

local function make(overrides)
  return issue_mod.normalize(vim.tbl_extend("force", {
    provider = "jira",
    id = "PROJ-1",
    title = "Timeout on cache warmup",
    description = "Warmup exceeds 30s when the cache is cold.",
    status = { id = "1", name = "Open" },
    updated_at = "2026-07-19T10:00:00Z",
  }, overrides or {}))
end

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  require("issuehub.core.repository").forget_case_index()
  require("issuehub.core.repository").ensure()
  cache.put(make())
end

describe("language tags", function()
  it("accepts BCP-47 shapes", function()
    for _, lang in ipairs({ "ja", "en", "pt-BR", "zh-Hans" }) do
      assert.equals(lang, (translation.normalize_lang(lang)))
    end
    assert.equals("ja", (translation.normalize_lang("  ja  ")))
  end)

  it("rejects anything that could escape the directory", function()
    -- The tag becomes a filename, so this is a path-traversal guard, not
    -- tidiness.
    for _, bad in ipairs({ "../etc/passwd", "ja/../..", "a/b", ".", "..", "ja.md", "", "j", ("x"):rep(40) }) do
      local ok, err = translation.normalize_lang(bad)
      assert.is_nil(ok, "should have rejected " .. vim.inspect(bad))
      assert.truthy(err)
    end
    assert.is_nil((translation.normalize_lang(nil)))
    assert.is_nil((translation.normalize_lang(123)))
  end)

  it("refuses to build a path for a bad tag", function()
    local path, err = translation.path(URI, "../evil")
    assert.is_nil(path)
    assert.truthy(err)
  end)
end)

describe("translation storage", function()
  before_each(fresh)

  it("stores one file per language, beside the notes", function()
    assert.is_true(
      translation.save(URI, "ja", { title = "キャッシュ暖機のタイムアウト", body = "本文" })
    )
    assert.is_true(translation.save(URI, "en", { title = "Timeout", body = "body" }))

    local dir = translation.dir(URI)
    assert.is_true(fs.exists(vim.fs.joinpath(dir, "ja.md")))
    assert.is_true(fs.exists(vim.fs.joinpath(dir, "en.md")))
    assert.same({ "en", "ja" }, translation.languages(URI))
  end)

  it("round-trips title and multi-line body", function()
    local body = "一行目\n\n- 箇条書き\n- もうひとつ\n\n```lua\nlocal x = 1\n```"
    translation.save(URI, "ja", { title = "題名", body = body })

    local got = assert(translation.get(URI, "ja"))
    assert.equals("題名", got.title)
    assert.equals(body, got.body)
    assert.equals("ja", got.lang)
  end)

  it("records the backend and model that produced it", function()
    translation.save(URI, "ja", { title = "t", body = "b", backend = "a2a", model = "some-model" })
    local got = assert(translation.get(URI, "ja"))
    assert.equals("a2a", got.backend)
    assert.equals("some-model", got.model)
    assert.truthy(got.created_at:match("^%d%d%d%d%-"))
  end)

  it("derives staleness from the issue revision, never stores it", function()
    translation.save(URI, "ja", { title = "t", body = "b" })
    assert.equals("current", translation.get(URI, "ja").status)

    -- The issue moves; nothing rewrites the translation, yet it goes stale.
    cache.put(make({ updated_at = "2026-07-25T10:00:00Z" }))
    assert.equals("outdated", translation.get(URI, "ja").status)

    -- And a revert makes it current again, which a stored flag could not do.
    cache.put(make())
    assert.equals("current", translation.get(URI, "ja").status)
  end)

  it("survives being hand-edited, because it is a plain file", function()
    translation.save(URI, "ja", { title = "t", body = "machine wording" })
    local path = translation.path(URI, "ja")
    local raw = fs.read(path)
    fs.write(path, (raw:gsub("machine wording", "corrected by hand")))

    local got = assert(translation.get(URI, "ja"))
    assert.equals("corrected by hand", got.body)
    -- Frontmatter, and therefore staleness, is untouched by the edit.
    assert.equals("current", got.status)
  end)

  it("reports nothing for an untranslated issue", function()
    assert.is_nil(translation.get(URI, "ja"))
    assert.same({}, translation.languages(URI))
    assert.equals("", translation.searchable_text(URI))
  end)

  it("deletes", function()
    translation.save(URI, "ja", { title = "t", body = "b" })
    assert.is_true(translation.delete(URI, "ja"))
    assert.is_false(translation.delete(URI, "ja"))
    assert.is_nil(translation.get(URI, "ja"))
  end)

  it("exposes translated prose to full-text search", function()
    translation.save(URI, "ja", { title = "題名", body = "認証まわりの調査" })
    local text = translation.searchable_text(URI)
    assert.truthy(text:find("題名", 1, true))
    assert.truthy(text:find("認証", 1, true))
  end)
end)

describe("translation requests", function()
  before_each(fresh)

  it("carries the issue and the target language", function()
    local request = assert(translation.request(URI, "ja"))
    assert.equals("translate", request.kind)
    assert.equals(URI, request.resource)
    assert.equals("ja", request.metadata.target_language)
    assert.equals("Timeout on cache warmup", request.context.issue.title)
    assert.equals(2, #request.context.documents) -- title + description
  end)

  it("includes comments only when asked", function()
    cache.put(make({
      comments = { { id = "1", author = "a", body = "hi", created_at = "2026-07-19T09:00:00Z" } },
    }))
    assert.equals(2, #translation.request(URI, "ja").context.documents)
    assert.equals(3, #translation.request(URI, "ja", { include_comments = true }).context.documents)
  end)

  it("refuses when the issue is not cached", function()
    local request, err = translation.request("jira://NOPE", "ja")
    assert.is_nil(request)
    assert.truthy(err:find("not cached"))
  end)

  it("refuses a bad language tag before touching the backend", function()
    local request, err = translation.request(URI, "../evil")
    assert.is_nil(request)
    assert.truthy(err)
  end)
end)

describe("backend reply parsing", function()
  it("splits a title from the body", function()
    local title, body = translation.split_reply("題名\n\n本文の一行目\n二行目")
    assert.equals("題名", title)
    assert.equals("本文の一行目\n二行目", body)
  end)

  it("keeps everything as body when there is no title line", function()
    -- A model that ignores the format still produces a usable translation.
    local title, body = translation.split_reply("ただの本文です")
    assert.equals("", title)
    assert.equals("ただの本文です", body)
  end)

  it("does not mistake a multi-line opening paragraph for a title", function()
    local title, body = translation.split_reply("一行目\n二行目\n\n三行目")
    assert.equals("", title)
    assert.truthy(body:find("一行目", 1, true))
  end)

  it("tolerates an empty reply", function()
    assert.equals("", (translation.split_reply("")))
    assert.equals("", (translation.split_reply(nil)))
  end)
end)
