local fs = require("issuehub.util.fs")
local repository = require("issuehub.core.repository")
local config = require("issuehub.config")

local tmp

local function setup_workspace()
  tmp = vim.fn.tempname()
  config.setup({ workspace = tmp })
  require("issuehub.core.index").reset()
end

describe("repository.ensure", function()
  before_each(setup_workspace)

  it("creates the skeleton", function()
    assert.is_true(repository.ensure())
    assert.is_true(fs.is_dir(vim.fs.joinpath(tmp, ".issuehub", "collections")))
    assert.is_true(fs.is_dir(vim.fs.joinpath(tmp, ".state", "cache")))
    assert.is_true(fs.is_dir(vim.fs.joinpath(tmp, ".state", "index")))
  end)

  it("git-ignores .state so derived data is never committed", function()
    repository.ensure()
    local gitignore = fs.read(vim.fs.joinpath(tmp, ".gitignore"))
    assert.truthy(gitignore:find("/.state/", 1, true))
  end)

  it("records the layout version", function()
    repository.ensure()
    assert.equals(repository.layout_version(), repository.version())
  end)

  it("is idempotent", function()
    repository.ensure()
    fs.write(vim.fs.joinpath(tmp, ".gitignore"), "custom\n")
    repository.ensure()
    -- An existing .gitignore is user-owned and must not be clobbered.
    assert.equals("custom\n", fs.read(vim.fs.joinpath(tmp, ".gitignore")))
  end)
end)

describe("repository paths", function()
  before_each(setup_workspace)

  it("uses the percent-encoded id verbatim as the directory name", function()
    assert.equals(vim.fs.joinpath(tmp, "jira", "PROJ-123"), repository.issue_dir("jira://PROJ-123"))
    assert.equals(vim.fs.joinpath(tmp, "jira", "PROJ%2F123"), repository.issue_dir("jira://PROJ%2F123"))
  end)

  it("keeps cache under .state", function()
    local path = repository.cache_file("jira://PROJ-123")
    assert.equals(vim.fs.joinpath(tmp, ".state", "cache", "jira", "PROJ-123.json"), path)
  end)

  it("errors on a malformed uri", function()
    local path, err = repository.issue_dir("PROJ-123")
    assert.is_nil(path)
    assert.truthy(err)
  end)
end)

describe("repository without configuration", function()
  it("reports a clear error rather than guessing a path", function()
    config.setup({})
    local root, err = repository.root()
    assert.is_nil(root)
    assert.truthy(err:find("workspace"))
  end)
end)
