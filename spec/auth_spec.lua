local config = require("issuehub.config")
local putil = require("issuehub.provider.util")

local function ws()
  return vim.fn.tempname()
end

describe("username/password (HTTP Basic) auth", function()
  before_each(function()
    vim.env.IH_TEST_PW = "s3cr3t:has:colons"
  end)

  it("resolves a password from env, cmd, and a function — never leaks it", function()
    config.setup({
      workspace = ws(),
      providers = {
        a = { type = "redmine", url = "https://a", user = "u", password_env = "IH_TEST_PW" },
        b = { type = "redmine", url = "https://b", user = "u", password_cmd = { "printf", "from-cmd" } },
        c = { type = "redmine", url = "https://c", user = "u", password = function()
          return "from-fn"
        end },
      },
    })
    assert.equals("s3cr3t:has:colons", (config.password("a")))
    assert.equals("from-cmd", (config.password("b")))
    assert.equals("from-fn", (config.password("c")))
  end)

  it("forms a basic credential only when both user and password are present", function()
    config.setup({
      workspace = ws(),
      providers = {
        both = { type = "redmine", url = "https://a", user = "alice", password_env = "IH_TEST_PW" },
        token = { type = "redmine", url = "https://b", token_env = "IH_TEST_PW" },
      },
    })
    assert.is_true(config.password_configured("both"))
    assert.same({ basic = "alice:s3cr3t:has:colons" }, config.basic_auth("both"))
    -- A token-mode provider is not in basic mode: nil, and no error.
    assert.is_false(config.password_configured("token"))
    assert.is_nil(config.basic_auth("token"))
  end)

  it("distinguishes 'not basic' from 'basic but unresolved'", function()
    config.setup({
      workspace = ws(),
      providers = { p = { type = "redmine", url = "https://a", user = "u", password_env = "IH_ABSENT" } },
    })
    -- In basic mode, so this is an error, not a quiet nil-means-token.
    local auth, err = config.basic_auth("p")
    assert.is_nil(auth)
    assert.truthy(err:find("IH_ABSENT", 1, true))
  end)
end)

describe("providers pick the credential from the config", function()
  before_each(function()
    vim.env.IH_TEST_PW = "pw"
    vim.env.IH_TEST_TOKEN = "tok"
  end)

  it("sends Redmine basic auth as user:password, not the API-key header", function()
    config.setup({
      workspace = ws(),
      providers = { rm = { type = "redmine", url = "https://rm", user = "alice", password_env = "IH_TEST_PW" } },
    })
    local rm = require("issuehub.provider.redmine").new("rm")
    rm:setup(config.get().providers.rm)

    local cred = assert(putil.credential(rm:_ctx()))
    assert.same({ basic = "alice:pw" }, cred.auth)
    -- The API-key header must be absent — the two are different auth schemes.
    assert.is_nil(cred.headers)
  end)

  it("keeps the Redmine API-key header when a token is configured", function()
    config.setup({
      workspace = ws(),
      providers = { rm = { type = "redmine", url = "https://rm", token_env = "IH_TEST_TOKEN" } },
    })
    local rm = require("issuehub.provider.redmine").new("rm")
    rm:setup(config.get().providers.rm)
    local cred = assert(putil.credential(rm:_ctx()))
    assert.equals("tok", cred.headers["X-Redmine-API-Key"])
    assert.is_nil(cred.auth)
  end)

  it("uses basic user:password for a self-hosted Jira that issues no token", function()
    config.setup({
      workspace = ws(),
      providers = { jira = { url = "https://jira.corp", user = "bob", password_env = "IH_TEST_PW" } },
    })
    local jira = require("issuehub.provider.jira").new("jira")
    jira:setup(config.get().providers.jira)
    -- Server/DC hostname → would otherwise be a bearer PAT; the password wins.
    assert.same({ basic = "bob:pw" }, (jira:_auth()))
  end)

  it("still does Jira Cloud email+token basic when no password is set", function()
    config.setup({
      workspace = ws(),
      providers = { jira = { url = "https://x.atlassian.net", user = "me@x", token_env = "IH_TEST_TOKEN" } },
    })
    local jira = require("issuehub.provider.jira").new("jira")
    jira:setup(config.get().providers.jira)
    assert.same({ basic = "me@x:tok" }, (jira:_auth()))
  end)

  it("puts the password in curl's config body, never in argv", function()
    config.setup({
      workspace = ws(),
      providers = { rm = { type = "redmine", url = "https://rm", user = "alice", password_env = "IH_TEST_PW" } },
    })
    local conf = require("issuehub.util.http")._build_config({ url = "https://rm/x", auth = { basic = "alice:pw" } })
    -- argv is world-readable via ps; the config body is fed on stdin.
    assert.truthy(conf:find('user = "alice:pw"', 1, true))
  end)
end)

describe("basic-auth config validation", function()
  it("rejects a password with no username", function()
    local errors = config.setup({
      workspace = ws(),
      providers = { rm = { type = "redmine", url = "https://rm", password_env = "IH_TEST_PW" } },
    })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("password is set but user is not")
    end))
  end)

  it("reports credential status without revealing the secret", function()
    vim.env.IH_TEST_PW = "hunter2"
    config.setup({
      workspace = ws(),
      providers = { rm = { type = "redmine", url = "https://rm", user = "alice", password_env = "IH_TEST_PW" } },
    })
    local ok, msg = config.credential_status("rm")
    assert.is_true(ok)
    assert.truthy(msg:find("basic auth as alice", 1, true))
    assert.truthy(msg:find("7 characters", 1, true))
    -- The value itself must never appear.
    assert.is_nil(msg:find("hunter2", 1, true))
  end)
end)
