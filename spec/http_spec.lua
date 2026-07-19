local http = require("issuehub.util.http")
local config = require("issuehub.config")

---The curl config file is where every secret must live: argv is world-readable
---via `ps`, a config file on stdin is not.
local function conf(req)
  return http._build_config(req)
end

describe("curl config", function()
  it("puts a bearer token in a header line, not in argv", function()
    local out = conf({ url = "https://x", auth = { bearer = "s3cret" } })
    assert.truthy(out:find('header = "Authorization: Bearer s3cret"', 1, true))
  end)

  it("puts basic credentials in a user line", function()
    local out = conf({ url = "https://x", auth = { basic = "me@example.com:tok" } })
    assert.truthy(out:find('user = "me@example.com:tok"', 1, true))
  end)

  it("escapes quotes and newlines so a value cannot break out of the config", function()
    local out = conf({ url = "https://x", headers = { X = 'a"b' .. "\n" .. "proxy = evil" } })
    assert.is_nil(out:find("\nproxy = evil", 1, true))
    assert.truthy(out:find('a\\"b', 1, true))
  end)
end)

describe("curl config: proxy", function()
  it("omits proxy entirely when unset, leaving curl to honour the environment", function()
    local out = conf({ url = "https://x", net = {} })
    assert.is_nil(out:find("proxy", 1, true))
  end)

  it("emits proxy and noproxy", function()
    local out = conf({
      url = "https://x",
      net = { proxy = "http://proxy.corp:8080", no_proxy = "localhost,.internal" },
    })
    assert.truthy(out:find('proxy = "http://proxy.corp:8080"', 1, true))
    assert.truthy(out:find('noproxy = "localhost,.internal"', 1, true))
  end)

  it("keeps the proxy password out of argv by putting it in the config", function()
    local out = conf({
      url = "https://x",
      net = { proxy = "http://p:8080", proxy_user = "corp\\user", proxy_password = "pw" },
    })
    assert.truthy(out:find('proxy-user = "corp\\\\user:pw"', 1, true))
  end)

  it("emits the proxy auth scheme as a bare flag", function()
    local out = conf({ url = "https://x", net = { proxy = "http://p:8080", proxy_auth = "ntlm" } })
    assert.truthy(out:find("\nproxy-ntlm", 1, true))
  end)

  it("emits an empty password rather than letting curl prompt", function()
    -- A bare `proxy-user = "user"` makes curl prompt on the terminal, which
    -- hangs a headless Neovim instead of failing.
    local out = conf({ url = "https://x", net = { proxy_user = "user" } })
    assert.truthy(out:find('proxy-user = "user:"', 1, true))
  end)

  it("accepts a literal proxy password as well as env/cmd", function()
    config.setup({
      workspace = vim.fn.tempname(),
      http = { proxy = "http://p:8080", proxy_user = "u", proxy_password = "literal-pw" },
    })
    assert.equals("literal-pw", config.net(nil).proxy_password)
    assert.truthy(conf({ url = "https://x", net = config.net(nil) }):find('proxy-user = "u:literal-pw"', 1, true))
  end)
end)

describe("curl config: TLS", function()
  it("passes a custom CA bundle", function()
    local out = conf({ url = "https://x", net = { cacert = "/etc/corp/root.pem" } })
    assert.truthy(out:find('cacert = "/etc/corp/root.pem"', 1, true))
    -- Trusting a root is not the same as disabling verification.
    assert.is_nil(out:find("insecure", 1, true))
  end)

  it("emits insecure only when ssl_verify is explicitly false", function()
    assert.is_nil(conf({ url = "https://x", net = {} }):find("insecure", 1, true))
    assert.is_nil(conf({ url = "https://x", net = { ssl_verify = true } }):find("insecure", 1, true))
    assert.truthy(conf({ url = "https://x", net = { ssl_verify = false } }):find("insecure", 1, true))
  end)

  it("passes a client certificate and keeps its passphrase in the config", function()
    local out = conf({
      url = "https://x",
      net = { client_cert = "/c.pem", client_key = "/k.pem", client_key_password = "kpw" },
    })
    assert.truthy(out:find('cert = "/c.pem"', 1, true))
    assert.truthy(out:find('key = "/k.pem"', 1, true))
    assert.truthy(out:find('pass = "kpw"', 1, true))
  end)
end)

describe("config.net", function()
  local function setup(opts)
    config.setup(vim.tbl_extend("force", { workspace = vim.fn.tempname() }, opts))
  end

  it("defaults to verification on and no explicit proxy", function()
    setup({})
    local net = config.net(nil)
    assert.is_true(net.ssl_verify)
    assert.is_nil(net.proxy)
  end)

  it("carries ssl_verify = false through to the request", function()
    setup({ http = { ssl_verify = false } })
    assert.is_false(config.net(nil).ssl_verify)
    assert.truthy(http._build_config({ url = "https://x", net = config.net(nil) }):find("insecure", 1, true))
  end)

  it("carries no_proxy through to the request", function()
    setup({ http = { no_proxy = "localhost,.internal.example" } })
    local out = http._build_config({ url = "https://x", net = config.net(nil) })
    assert.truthy(out:find('noproxy = "localhost,.internal.example"', 1, true))
  end)

  it("supports no_proxy = '*' to bypass an environment proxy entirely", function()
    setup({ http = { no_proxy = "*" } })
    assert.truthy(http._build_config({ url = "https://x", net = config.net(nil) }):find('noproxy = "*"', 1, true))
  end)

  it("lets a provider override the global block", function()
    setup({
      http = { proxy = "http://global:8080", ssl_verify = true },
      providers = {
        -- An internal tracker reached directly, while the rest goes via proxy.
        redmine = { url = "https://redmine.internal", http = { proxy = nil, no_proxy = "*" } },
      },
    })
    assert.equals("http://global:8080", config.net("jira").proxy)
    assert.equals("*", config.net("redmine").no_proxy)
  end)

  it("resolves the proxy password from the environment", function()
    vim.env.SPEC_PROXY_PW = "pw-from-env"
    setup({ http = { proxy = "http://p:8080", proxy_user = "u", proxy_password_env = "SPEC_PROXY_PW" } })
    assert.equals("pw-from-env", config.net(nil).proxy_password)
  end)

  it("expands ~ in certificate paths", function()
    setup({ http = { cacert = "~/corp.pem" } })
    assert.is_nil(config.net(nil).cacert:find("~", 1, true))
  end)
end)

describe("config.net_summary", function()
  it("never reveals the proxy password", function()
    config.setup({
      workspace = vim.fn.tempname(),
      http = { proxy = "http://user:hunter2@proxy.corp:8080", proxy_user = "user" },
    })
    local summary = config.net_summary(nil)
    assert.is_nil(summary:find("hunter2", 1, true))
    assert.truthy(summary:find("proxy.corp:8080", 1, true))
  end)

  it("reports the verification state", function()
    config.setup({ workspace = vim.fn.tempname(), http = { ssl_verify = false } })
    assert.truthy(config.net_summary(nil):find("ssl_verify=false", 1, true))
  end)
end)

describe("config validation: http", function()
  it("rejects an unknown proxy auth scheme", function()
    local errors = config.setup({ workspace = vim.fn.tempname(), http = { proxy_auth = "kerberos" } })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("proxy_auth")
    end))
  end)

  it("rejects a client cert without a key", function()
    local errors = config.setup({ workspace = vim.fn.tempname(), http = { client_cert = "/nope.pem" } })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("requires http.client_key")
    end))
  end)

  it("rejects a CA bundle path that does not exist", function()
    local errors = config.setup({ workspace = vim.fn.tempname(), http = { cacert = "/definitely/not/here.pem" } })
    assert.truthy(vim.iter(errors):any(function(e)
      return e:find("http.cacert does not exist")
    end))
  end)

  it("accepts a CA bundle that does exist", function()
    local path = vim.fn.tempname()
    require("issuehub.util.fs").write(path, "-----BEGIN CERTIFICATE-----\n")
    local errors = config.setup({ workspace = vim.fn.tempname(), http = { cacert = path } })
    assert.equals(0, #errors)
  end)
end)

describe("config.net_summary: per-instance overrides", function()
  it("shows no_proxy, so a bypass is visible when diagnosing", function()
    config.setup({
      workspace = vim.fn.tempname(),
      http = { proxy = "http://proxy.corp:8080" },
      providers = {
        jira = { url = "https://saas.atlassian.net", token_env = "X" },
        jira_internal = { type = "jira", url = "https://jira.internal", token_env = "Y", http = { no_proxy = "*" } },
      },
    })
    assert.is_nil(config.net_summary("jira"):find("no_proxy", 1, true))
    assert.truthy(config.net_summary("jira_internal"):find("no_proxy=*", 1, true))
    assert.equals("*", config.net("jira_internal").no_proxy)
  end)
end)
