---@brief Defaults, merge, validation, and credential resolution.
local M = {}

---@type issuehub.Config
local defaults = {
  -- REQUIRED. Points at the Repository root (§5). Deliberately has no default:
  -- this is a Git-managed knowledge base, not a scratch directory.
  workspace = nil,

  index = "auto", -- "auto" | "json" | "sqlite"

  providers = {},

  ui = {
    picker = "auto",
  },

  sync = {
    on_open = "stale",
    stale_after = 15 * 60,
    -- Above this many targets, `:IssueHub sync` asks first. One request per
    -- issue against a corporate tracker with thousands of tickets is a long
    -- operation and possibly a rate-limit problem, so it should be deliberate.
    confirm_above = 200,
  },

  -- Corporate network settings. Every field is optional, and `nil` means "let
  -- curl decide", which includes honouring http_proxy / https_proxy / no_proxy
  -- from the environment. Setting `proxy` here overrides the environment.
  http = {
    proxy = nil, -- "http://proxy.corp.example:8080"
    no_proxy = nil, -- "localhost,127.0.0.1,.internal.example"
    proxy_user = nil, -- password via proxy_password_env / _cmd / function
    proxy_password_env = nil,
    proxy_password_cmd = nil,
    proxy_auth = nil, -- "basic"|"digest"|"ntlm"|"negotiate"|"anyauth"

    -- TLS. A corporate MITM appliance is handled by trusting its root here,
    -- NOT by turning verification off.
    cacert = nil, -- path to a CA bundle (PEM)
    capath = nil, -- directory of hashed CA certs
    ssl_verify = true, -- false disables verification entirely; see below

    -- Mutual TLS, if the gateway requires a client certificate.
    client_cert = nil,
    client_key = nil,
    client_key_password_env = nil,
    client_key_password_cmd = nil,

    timeout = 30000, -- ms
    retries = 2,
  },

  export = {
    dir = nil, -- defaults to the current working directory
    default_format = "markdown",
  },

  -- Translations are produced on request through the configured backend and
  -- stored per language beside the issue's notes.
  translate = {
    default_language = nil, -- e.g. "ja"; prompts when unset and none is given
    languages = {}, -- offered in the prompt; free text is still accepted
    include_comments = false, -- comments can dominate the request on busy issues
  },

  -- Attachments are cache, never workspace: they land under .state/, which is
  -- git-ignored, because binaries cannot be removed from Git history and a
  -- pasted screenshot is often more sensitive than the ticket text. Nothing is
  -- fetched until you ask for it by name.
  attachments = {
    max_size = 50 * 1024 * 1024, -- refuse anything larger; 0 disables the check
  },

  -- AI is opt-in. With "none", nothing is ever sent anywhere.
  backend = "none",
  backends = {
    -- a2a = { url = "http://localhost:9100", token_env = "A2A_TOKEN" },
    -- openai = { url = "https://gateway/v1", model = "gpt-4o-mini", token_env = "OPENAI_API_KEY" },
  },

  log_level = vim.log.levels.WARN,
}

---Keys that are planned but not yet wired up. Passing one is a user error
---worth surfacing, not a no-op.
local NOT_YET = {
  workspace_dir = "renamed to `workspace`",
}

---@type issuehub.Config
local options = vim.deepcopy(defaults)
local did_setup = false

---Resolved tokens, cached for the session only. Never written to disk.
local token_cache = {}
local password_cache = {}

---@return issuehub.Config
function M.get()
  return options
end

---@return boolean
function M.is_setup()
  return did_setup
end

---@return issuehub.Config
function M.defaults()
  return vim.deepcopy(defaults)
end

local VALID_INDEX = { auto = true, json = true, sqlite = true }
local VALID_PICKER = { auto = true, snacks = true, fzf = true, telescope = true, select = true }
local VALID_ON_OPEN = { always = true, stale = true, never = true }
local VALID_PROXY_AUTH = { basic = true, digest = true, ntlm = true, negotiate = true, anyauth = true }

---@param opts table
---@return string[] errors
local function validate(opts, raw)
  local errors = {}

  -- `workspace` is documented as required, so it must actually fail at setup()
  -- rather than surfacing as "workspace is not configured" on first use.
  if opts.workspace == nil then
    errors[#errors + 1] = "workspace is required, e.g. workspace = '~/notes/issuehub'"
  elseif type(opts.workspace) ~= "string" then
    errors[#errors + 1] = "workspace must be a string path"
  end

  for key, when in pairs(NOT_YET) do
    if raw[key] ~= nil then
      errors[#errors + 1] = ("`%s` is not implemented yet (%s) — remove it for now"):format(key, when)
    end
  end
  if not VALID_INDEX[opts.index] then
    errors[#errors + 1] = ("index must be one of auto|json|sqlite (got %s)"):format(tostring(opts.index))
  end
  if not VALID_PICKER[opts.ui.picker] then
    errors[#errors + 1] = ("ui.picker must be one of auto|snacks|fzf|telescope|select (got %s)"):format(
      tostring(opts.ui.picker)
    )
  end
  if not VALID_ON_OPEN[opts.sync.on_open] then
    errors[#errors + 1] = ("sync.on_open must be one of always|stale|never (got %s)"):format(
      tostring(opts.sync.on_open)
    )
  end

  local http = opts.http or {}
  if http.proxy_auth ~= nil and not VALID_PROXY_AUTH[http.proxy_auth] then
    errors[#errors + 1] = ("http.proxy_auth must be one of basic|digest|ntlm|negotiate|anyauth (got %s)"):format(
      tostring(http.proxy_auth)
    )
  end
  if http.client_cert and not http.client_key then
    errors[#errors + 1] = "http.client_cert requires http.client_key"
  end
  if http.ssl_verify == false then
    -- Not an error: some internal CAs genuinely cannot be exported. But it must
    -- never be silent, because it disables MITM protection entirely.
    require("issuehub.util.log").warn("http.ssl_verify = false: TLS certificate verification is DISABLED")
  end
  for _, field in ipairs({ "cacert", "capath", "client_cert", "client_key" }) do
    local path = http[field]
    if path and not require("issuehub.util.fs").exists(vim.fn.expand(path)) then
      errors[#errors + 1] = ("http.%s does not exist: %s"):format(field, path)
    end
  end

  if opts.export.default_format ~= nil and type(opts.export.default_format) ~= "string" then
    errors[#errors + 1] = "export.default_format must be a string"
  end

  if type(opts.backend) ~= "string" then
    errors[#errors + 1] = "backend must be a string"
  elseif opts.backend == "a2a" and not (opts.backends.a2a or {}).url then
    errors[#errors + 1] = "backend = 'a2a' requires backends.a2a.url"
  elseif opts.backend == "openai" then
    local b = opts.backends.openai or {}
    if not b.url then
      errors[#errors + 1] = "backend = 'openai' requires backends.openai.url (e.g. https://gateway/v1)"
    end
    if not b.model then
      errors[#errors + 1] = "backend = 'openai' requires backends.openai.model (e.g. gpt-4o-mini)"
    end
  end

  -- Self-hosted-only providers have no sensible default host; the SaaS ones do.
  -- Keyed by TYPE, not by instance name: `providers.jira_internal` is still a
  -- Jira and still needs a url.
  local URL_REQUIRED = { jira = true, redmine = true }

  for name, p in pairs(opts.providers) do
    if type(p) ~= "table" then
      errors[#errors + 1] = ("providers.%s must be a table"):format(name)
    else
      local kind = p.type or name
      if p.type ~= nil and type(p.type) ~= "string" then
        errors[#errors + 1] = ("providers.%s.type must be a string"):format(name)
      end
      if p.url ~= nil and (type(p.url) ~= "string" or p.url == "") then
        errors[#errors + 1] = ("providers.%s.url must be a non-empty string"):format(name)
      elseif p.url == nil and URL_REQUIRED[kind] then
        errors[#errors + 1] = ("providers.%s.url is required"):format(name)
      end

      -- Basic auth needs both halves; a password with no username silently
      -- resolves to nothing useful, which is worse than saying so now.
      local has_password = p.password ~= nil or p.password_cmd ~= nil or p.password_env ~= nil
      if has_password and not p.user then
        errors[#errors + 1] = ("providers.%s: password is set but user is not — Basic auth needs both"):format(name)
      end
      if type(p.password) == "string" then
        -- Accepted (refusing it would make curl prompt and hang), but a plain
        -- password in a config file is exactly what password_env/_cmd exist to
        -- avoid.
        require("issuehub.util.log").warn(
          ("providers.%s.password is a literal string in your config — prefer password_env or password_cmd"):format(
            name
          )
        )
      end
    end
  end

  return errors
end

---@param opts table?
---@return string[] errors
function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  if options.workspace then
    options.workspace = require("issuehub.util.fs").expand(options.workspace)
  end

  local errors = validate(options, opts or {})
  did_setup = true
  token_cache = {}
  password_cache = {}
  password_cache = {}
  return errors
end

---Resolve a secret from a `<prefix>` / `<prefix>_cmd` / `<prefix>_env` triple.
---
---Shared by provider tokens and proxy passwords: both are credentials, and both
---must be resolvable from a password manager rather than written in a config
---file. Order: literal function > command > environment variable.
---@param source table          Table holding the fields.
---@param prefix string         e.g. "token", "proxy_password"
---@param label string          Human-readable location, used in errors.
---@return string? value
---@return string? err
function M.secret(source, prefix, label)
  local direct = source[prefix]

  -- A literal string is accepted (and documented as discouraged) because
  -- refusing it silently — as an earlier version did — meant curl fell back to
  -- prompting interactively, which hangs a headless Neovim.
  if type(direct) == "string" then
    if direct == "" then
      return nil, ("%s.%s is an empty string"):format(label, prefix)
    end
    return direct
  end

  if type(direct) == "function" then
    local ok, value = pcall(direct)
    if not ok then
      return nil, ("%s.%s() failed: %s"):format(label, prefix, tostring(value))
    end
    if value and value ~= "" then
      return value
    end
    return nil, ("%s.%s() returned an empty value"):format(label, prefix)
  end

  local cmd = source[prefix .. "_cmd"]
  if cmd then
    local out = vim.system(cmd, { text = true }):wait()
    if out.code ~= 0 then
      return nil, ("%s.%s_cmd failed: %s"):format(label, prefix, vim.trim(out.stderr or ""))
    end
    local value = vim.trim(out.stdout or "")
    if value == "" then
      return nil, ("%s.%s_cmd produced no output"):format(label, prefix)
    end
    return value
  end

  local env = source[prefix .. "_env"]
  if env then
    local value = vim.env[env]
    if not value or value == "" then
      return nil, ("$%s is not set (%s.%s_env)"):format(env, label, prefix)
    end
    return value
  end

  return nil, ("%s has no %s, %s_cmd, or %s_env"):format(label, prefix, prefix, prefix)
end

---Resolve a provider credential.
---
---The value is cached in memory for the session and is never logged or
---persisted.
---@param provider string
---@return string? token
---@return string? err
function M.token(provider)
  if token_cache[provider] then
    return token_cache[provider]
  end

  local p = options.providers[provider]
  if not p then
    return nil, ("no configuration for provider '%s'"):format(provider)
  end

  local token, err = M.secret(p, "token", "providers." .. provider)
  if not token then
    return nil, err
  end

  token_cache[provider] = token
  return token
end

---Whether a provider is configured for HTTP Basic (username + password) rather
---than a token.
---
--- Self-hosted Jira and Redmine that never issue API tokens authenticate this
--- way; the transport has always supported it (curl `user =`), this is the
--- config seam. Both `user` and a password source must be present — a password
--- without a username cannot form a Basic credential.
---@param provider string
---@return boolean
function M.password_configured(provider)
  local p = options.providers[provider]
  if not p then
    return false
  end
  return p.password ~= nil or p.password_cmd ~= nil or p.password_env ~= nil
end

---Resolve a provider's password, same triple as any other credential.
---@param provider string
---@return string? password
---@return string? err
function M.password(provider)
  if password_cache[provider] then
    return password_cache[provider]
  end
  local p = options.providers[provider]
  if not p then
    return nil, ("no configuration for provider '%s'"):format(provider)
  end
  local password, err = M.secret(p, "password", "providers." .. provider)
  if not password then
    return nil, err
  end
  password_cache[provider] = password
  return password
end

---The HTTP Basic credential for a provider, or nil when it is not in Basic mode.
---
--- Returns `nil` (no error) when the provider uses a token; returns `nil, err`
--- when it IS in Basic mode but the password will not resolve, so a caller can
--- tell "not basic" from "basic but broken".
---@param provider string
---@return issuehub.HttpAuth? auth
---@return string? err
function M.basic_auth(provider)
  local p = options.providers[provider]
  if not p or not p.user or not M.password_configured(provider) then
    return nil
  end
  local password, err = M.password(provider)
  if not password then
    return nil, err
  end
  return { basic = ("%s:%s"):format(p.user, password) }
end

---Network settings for a provider: the global `http` block with the provider's
---own `http` overriding it.
---
---A provider may need different settings from the rest — an internal Redmine
---reached directly while Jira Cloud goes through the proxy is the common case.
---@param provider string?
---@return table net
function M.net(provider)
  local base = vim.deepcopy(options.http or {})
  local p = provider and options.providers[provider]
  if p and type(p.http) == "table" then
    base = vim.tbl_deep_extend("force", base, p.http)
  end

  -- Resolved late and never cached: unlike a provider token this is cheap to
  -- re-read, and a stale proxy password would fail every request confusingly.
  if base.proxy_user and (base.proxy_password or base.proxy_password_cmd or base.proxy_password_env) then
    local password, err = M.secret(base, "proxy_password", "http")
    if password then
      base.proxy_password = password
    else
      require("issuehub.util.log").warn("proxy password unresolved:", err)
      base.proxy_password = nil
    end
  end

  if base.client_key and (base.client_key_password_cmd or base.client_key_password_env) then
    local password = M.secret(base, "client_key_password", "http")
    base.client_key_password = password
  end

  for _, field in ipairs({ "cacert", "capath", "client_cert", "client_key" }) do
    if base[field] then
      base[field] = vim.fn.expand(base[field])
    end
  end

  return base
end

---Human-readable summary of the network configuration, with the proxy password
---removed. Used by :checkhealth.
---@param provider string?
---@return string
function M.net_summary(provider)
  local net = M.net(provider)
  local parts = {}

  if net.proxy then
    -- A proxy URL may itself embed credentials; strip them before display.
    parts[#parts + 1] = "proxy=" .. net.proxy:gsub("//[^/@]*@", "//")
  else
    local env = vim.env.https_proxy or vim.env.HTTPS_PROXY or vim.env.http_proxy or vim.env.HTTP_PROXY
    parts[#parts + 1] = env and ("proxy=" .. env:gsub("//[^/@]*@", "//") .. " (from environment)") or "proxy=none"
  end

  -- Shown even though it is not a credential: "why is this host still going
  -- through the proxy" is a common thing to diagnose.
  if net.no_proxy then
    parts[#parts + 1] = "no_proxy=" .. net.no_proxy
  end
  if net.proxy_user then
    parts[#parts + 1] = ("proxy_auth=%s as %s"):format(net.proxy_auth or "basic", net.proxy_user)
  end
  if net.cacert then
    parts[#parts + 1] = "cacert=" .. net.cacert
  end
  if net.capath then
    parts[#parts + 1] = "capath=" .. net.capath
  end
  if net.client_cert then
    parts[#parts + 1] = "mTLS=on"
  end
  parts[#parts + 1] = "ssl_verify=" .. tostring(net.ssl_verify ~= false)

  return table.concat(parts, ", ")
end

---Whether a credential can be resolved, without revealing it. Used by health.
---@param provider string
---@return boolean ok
---@return string msg
function M.token_status(provider)
  local token, err = M.token(provider)
  if not token then
    return false, err or "unresolved"
  end
  return true, ("resolved (%d characters)"):format(#token)
end

---What :checkhealth reports for a provider's credential — Basic or token —
---never the value itself.
---@param provider string
---@return boolean ok
---@return string msg
function M.credential_status(provider)
  local p = options.providers[provider]
  if p and p.user and M.password_configured(provider) then
    local password, err = M.password(provider)
    if not password then
      return false, err or "password unresolved"
    end
    return true, ("basic auth as %s, password resolved (%d characters)"):format(p.user, #password)
  end
  return M.token_status(provider)
end

return M
