local config = require("issuehub.config")
local cache = require("issuehub.core.cache")
local issue_mod = require("issuehub.core.issue")
local attachment = require("issuehub.core.attachment")
local repository = require("issuehub.core.repository")
local putil = require("issuehub.provider.util")
local fs = require("issuehub.util.fs")

local URI = "jira://PROJ-1"

local function make(attachments)
  return issue_mod.normalize({
    provider = "jira",
    id = "PROJ-1",
    title = "Timeout on cache warmup",
    status = { id = "1", name = "Open" },
    updated_at = "2026-07-19T10:00:00Z",
    attachments = attachments,
  })
end

local function fresh()
  config.setup({ workspace = vim.fn.tempname(), index = "json" })
  require("issuehub.core.index").reset()
  repository.forget_case_index()
  repository.ensure()
end

describe("attachment filenames", function()
  it("reduces a tracker-supplied name to one path segment", function()
    -- The name comes from a remote system and becomes a path, so this is a
    -- traversal guard first.
    assert.equals("passwd", attachment.safe_filename("../../../etc/passwd"))
    assert.equals("evil.sh", attachment.safe_filename("/tmp/evil.sh"))
    assert.equals("report.pdf", attachment.safe_filename("C:\\Users\\me\\report.pdf"))
    assert.equals("bashrc", attachment.safe_filename(".bashrc"))
  end)

  it("keeps ordinary names, including spaces and non-ASCII", function()
    assert.equals("design doc.pdf", attachment.safe_filename("design doc.pdf"))
    assert.equals("設計メモ.md", attachment.safe_filename("設計メモ.md"))
  end)

  it("refuses rather than inventing a name when nothing usable is left", function()
    for _, bad in ipairs({ "..", ".", "/", "...", "", "  " }) do
      assert.is_nil(attachment.safe_filename(bad), "should have refused " .. vim.inspect(bad))
    end
    assert.is_nil(attachment.safe_filename(nil))
  end)

  it("truncates a name long enough to break a filesystem", function()
    assert.equals(120, #attachment.safe_filename(("x"):rep(400)))
  end)
end)

describe("attachment storage", function()
  before_each(fresh)

  it("lives under .state/, never in the workspace", function()
    -- Binaries cannot be removed from Git history, so this is the one part of
    -- an issue that is deliberately not tracked.
    local dir = attachment.dir(URI)
    assert.truthy(dir:find("/.state/attachments/", 1, true))
    assert.is_nil(dir:find(repository.root() .. "/jira/PROJ-1", 1, true))
  end)

  it("gives same-named attachments separate directories", function()
    cache.put(make({
      { id = "1", filename = "screenshot.png", url = "https://x/1" },
      { id = "2", filename = "screenshot.png", url = "https://x/2" },
    }))
    local list = attachment.list(URI)
    assert.equals(2, #list)
    assert.is_true(list[1].path ~= list[2].path)
    -- ...and the human-readable name still survives in both.
    assert.equals("screenshot.png", vim.fs.basename(list[1].path))
  end)

  it("reports what is on disk without being told", function()
    cache.put(make({ { id = "1", filename = "a.txt", url = "https://x/1" } }))
    assert.is_false(attachment.list(URI)[1].downloaded)

    local path = attachment.list(URI)[1].path
    fs.mkdirp(vim.fs.dirname(path))
    fs.write(path, "hello")

    local after = attachment.list(URI)[1]
    assert.is_true(after.downloaded)
    assert.equals(5, after.bytes)
  end)

  it("purges the bytes but keeps the metadata", function()
    cache.put(make({ { id = "1", filename = "a.txt", url = "https://x/1" } }))
    local path = attachment.list(URI)[1].path
    fs.mkdirp(vim.fs.dirname(path))
    fs.write(path, "hello")

    assert.equals(1, attachment.purge(URI))
    assert.is_false(fs.exists(path))
    -- Reclaiming a cache must never look like losing data.
    assert.equals(1, #attachment.list(URI))
    assert.is_false(attachment.list(URI)[1].downloaded)
  end)

  it("drops entries it could not fetch even if asked", function()
    -- id, filename and url are all needed; listing a file that cannot then be
    -- downloaded is worse than not listing it.
    cache.put(make({
      { id = "1", filename = "ok.txt", url = "https://x/1" },
      { filename = "no-id.txt", url = "https://x/2" },
      { id = "3", url = "https://x/3" },
      { id = "4", filename = "no-url.txt" },
    }))
    local list = attachment.list(URI)
    assert.equals(1, #list)
    assert.equals("ok.txt", list[1].filename)
  end)

  it("has none for an issue that is not cached", function()
    assert.same({}, attachment.list("jira://NOPE"))
  end)
end)

describe("attachments parsed from Markdown", function()
  local function urls(list)
    return vim.tbl_map(function(a)
      return a.url
    end, list)
  end

  it("finds image and file links, and skips everything else", function()
    local body = table.concat({
      "See ![shot](https://github.com/user-attachments/assets/abc-123) and",
      "[report.pdf](https://github.com/o/r/files/99/report.pdf).",
      "Unrelated: [the docs](https://example.com/guide).",
    }, "\n")
    local list = putil.markdown_attachments({ body }, function(url)
      if url:match("^https://github%.com/user%-attachments/") or url:match("/files/%d+/") then
        return url
      end
      return nil
    end)
    assert.same({
      "https://github.com/user-attachments/assets/abc-123",
      "https://github.com/o/r/files/99/report.pdf",
    }, urls(list))
  end)

  it("names a file from the URL, falling back to the link text", function()
    local list = putil.markdown_attachments({
      "[design notes](https://h/uploads/deadbeef/notes.md) [screenshot](https://h/uploads/beef/asset)",
    }, function(url)
      return url
    end)
    assert.equals("notes.md", list[1].filename)
    -- GitHub's asset URLs carry no filename; the link text is all there is.
    assert.equals("screenshot", list[2].filename)
  end)

  it("gives the same URL the same id, and lists it once", function()
    local list = putil.markdown_attachments({ "[a](https://h/uploads/x/f.txt)", "[a](https://h/uploads/x/f.txt)" },
      function(url)
        return url
      end)
    assert.equals(1, #list)
    local again = putil.markdown_attachments({ "[a](https://h/uploads/x/f.txt)" }, function(url)
      return url
    end)
    -- Stable across runs: the id names a directory on disk.
    assert.equals(list[1].id, again[1].id)
  end)

  it("reports unknown size and type as unknown rather than guessing", function()
    local list = putil.markdown_attachments({ "[f](https://h/uploads/x/f.txt)" }, function(url)
      return url
    end)
    assert.is_nil(list[1].size)
    assert.is_nil(list[1].mime)
    assert.equals("?", attachment.human_size(nil))
  end)
end)

describe("attachment metadata from providers", function()
  it("maps Jira's attachment field to the content URL, not the metadata one", function()
    local jira = require("issuehub.provider.jira").new("jira")
    jira:setup({ url = "https://acme.atlassian.net", user = "me@acme.com", token = function()
      return "t"
    end })
    local issue = jira:_to_issue({
      key = "PROJ-1",
      fields = {
        summary = "x",
        status = { id = "1", name = "Open" },
        attachment = {
          {
            id = 10001,
            filename = "trace.log",
            content = "https://acme.atlassian.net/secure/attachment/10001/trace.log",
            self = "https://acme.atlassian.net/rest/api/3/attachment/10001",
            size = 2048,
            mimeType = "text/plain",
            author = { displayName = "Ada" },
            created = "2026-07-19T10:00:00.000+0900",
          },
        },
      },
    })
    local att = issue.attachments[1]
    assert.equals("10001", att.id)
    assert.equals("trace.log", att.filename)
    assert.truthy(att.url:find("/secure/attachment/", 1, true))
    assert.equals(2048, att.size)
    assert.equals("2026-07-19T01:00:00Z", att.created_at)
  end)

  it("resolves a GitLab upload against the project it belongs to", function()
    local gitlab = require("issuehub.provider.gitlab").new("gitlab")
    gitlab:setup({ url = "https://gitlab.example.com", token = function()
      return "t"
    end })
    local issue = gitlab:_to_issue({
      iid = 12,
      title = "x",
      state = "opened",
      web_url = "https://gitlab.example.com/group/proj/-/issues/12",
      description = "![shot](/uploads/abc123/shot.png)",
    })
    assert.equals("https://gitlab.example.com/group/proj/uploads/abc123/shot.png", issue.attachments[1].url)
  end)

  it("skips a relative GitLab upload when the project is unknown", function()
    local gitlab = require("issuehub.provider.gitlab").new("gitlab")
    gitlab:setup({ url = "https://gitlab.example.com", token = function()
      return "t"
    end })
    -- Without web_url there is nothing to resolve against, and a wrong URL
    -- would download the wrong project's file or 404 confusingly.
    local issue = gitlab:_to_issue({ iid = 12, title = "x", description = "![s](/uploads/abc/s.png)" })
    assert.same({}, issue.attachments)
  end)
end)
