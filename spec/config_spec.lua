local config = require("issuehub.config")

describe("config validation", function()
  it("rejects a missing workspace at setup time, not on first use", function()
    local errors = config.setup({})
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("workspace is required")
    end))
  end)

  it("accepts a valid config", function()
    assert.equals(0, #config.setup({ workspace = vim.fn.tempname() }))
  end)

  it("rejects keys that are accepted-but-ignored", function()
    -- Silently swallowing setup({ backend = "a2a" }) is worse than erroring.
    local errors = config.setup({ workspace = vim.fn.tempname(), backend = "a2a" })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("`backend` is not implemented yet")
    end))
  end)

  it("validates enums", function()
    local errors = config.setup({ workspace = vim.fn.tempname(), index = "postgres" })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("index must be one of")
    end))
  end)

  it("requires a url per provider", function()
    local errors = config.setup({ workspace = vim.fn.tempname(), providers = { jira = {} } })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("providers.jira.url is required")
    end))
  end)
end)

describe("multiple instances of one provider type", function()
  local providers = require("issuehub.provider")

  before_each(function()
    providers.reset()
    config.setup({
      workspace = vim.fn.tempname(),
      providers = {
        -- Name is the instance; `type` picks the implementation.
        jira = { url = "https://saas.atlassian.net", user = "me@example.com", token_env = "JIRA_SAAS" },
        jira_internal = { type = "jira", url = "https://jira.internal", token_env = "JIRA_INTERNAL" },
        gitlab_internal = { type = "gitlab", url = "https://gitlab.internal", token_env = "GL_INTERNAL" },
      },
    })
    vim.env.JIRA_SAAS = "saas-token"
    vim.env.JIRA_INTERNAL = "internal-token"
  end)

  it("resolves the implementation from type, defaulting to the name", function()
    assert.equals("jira", providers.type_of("jira"))
    assert.equals("jira", providers.type_of("jira_internal"))
    assert.equals("gitlab", providers.type_of("gitlab_internal"))
  end)

  it("builds independent instances", function()
    local saas = assert(providers.get("jira"))
    local internal = assert(providers.get("jira_internal"))

    assert.equals("https://saas.atlassian.net", saas.base)
    assert.equals("https://jira.internal", internal.base)
    -- Hostname heuristic still applies per instance.
    assert.is_true(saas:_is_cloud())
    assert.is_false(internal:_is_cloud())
  end)

  it("gives each instance its own credential", function()
    assert.equals("saas-token", config.token("jira"))
    assert.equals("internal-token", config.token("jira_internal"))
  end)

  it("stamps the instance name as the URI scheme, keeping workspaces separate", function()
    local internal = assert(providers.get("jira_internal"))
    local issue = internal:_to_issue({ key = "PROJ-1", fields = { summary = "x", status = {} } })

    -- The same issue key in two instances must not collide on disk.
    assert.equals("jira_internal://PROJ-1", issue.uri)
    assert.equals("jira_internal", issue.provider)

    local repository = require("issuehub.core.repository")
    -- Plain search: "-" is a quantifier in a Lua pattern.
    assert.truthy(repository.issue_dir(issue.uri):find("/jira_internal/PROJ-1", 1, true))
    assert.truthy(repository.cache_file(issue.uri):find("/jira_internal/PROJ-1.json", 1, true))
  end)

  it("routes a uri back to the right instance", function()
    local provider, id = providers.resolve("jira_internal://PROJ-1")
    assert.equals("jira_internal", provider.name)
    assert.equals("PROJ-1", id)
  end)

  it("still requires a url for a renamed self-hosted provider", function()
    local errors = config.setup({
      workspace = vim.fn.tempname(),
      providers = { redmine_b = { type = "redmine" } },
    })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("providers.redmine_b.url is required")
    end))
  end)

  it("reports an unknown type against the instance name", function()
    config.setup({ workspace = vim.fn.tempname(), providers = { tracker = { type = "bugzilla" } } })
    providers.reset()
    local _, err = providers.get("tracker")
    assert.truthy(err:find("unknown provider type 'bugzilla' for 'tracker'"))
  end)
end)
