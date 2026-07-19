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
  },

  log_level = vim.log.levels.WARN,

  -- NOTE: `backend`, `backends`, `export`, and `ui.preview` are deliberately
  -- absent until the milestone that implements them (§22). Shipping them as
  -- live defaults would mean setup({ backend = "a2a" }) is silently accepted
  -- and ignored — worse than an unknown-key error.
}

---Keys that are planned but not yet wired up. Passing one is a user error
---worth surfacing, not a no-op.
local NOT_YET = {
  backend = "0.5",
  backends = "0.5",
  export = "0.4",
  workspace_dir = "renamed to `workspace`",
}

---@type issuehub.Config
local options = vim.deepcopy(defaults)
local did_setup = false

---Resolved tokens, cached for the session only. Never written to disk.
local token_cache = {}

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

  -- Self-hosted-only providers have no sensible default host; the SaaS ones do.
  local URL_REQUIRED = { jira = true, redmine = true }

  for name, p in pairs(opts.providers) do
    if type(p) ~= "table" then
      errors[#errors + 1] = ("providers.%s must be a table"):format(name)
    elseif p.url ~= nil and (type(p.url) ~= "string" or p.url == "") then
      errors[#errors + 1] = ("providers.%s.url must be a non-empty string"):format(name)
    elseif p.url == nil and URL_REQUIRED[name] then
      errors[#errors + 1] = ("providers.%s.url is required"):format(name)
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
  return errors
end

---Resolve a provider credential.
---
---Order: token() > token_cmd > token_env. The value is cached in memory for the
---session and is never logged or persisted.
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

  local token
  if type(p.token) == "function" then
    local ok, value = pcall(p.token)
    if not ok then
      return nil, ("providers.%s.token() failed: %s"):format(provider, tostring(value))
    end
    token = value
  elseif p.token_cmd then
    local out = vim.system(p.token_cmd, { text = true }):wait()
    if out.code ~= 0 then
      return nil, ("providers.%s.token_cmd failed: %s"):format(provider, vim.trim(out.stderr or ""))
    end
    token = vim.trim(out.stdout or "")
  elseif p.token_env then
    token = vim.env[p.token_env]
    if not token or token == "" then
      return nil, ("$%s is not set (providers.%s.token_env)"):format(p.token_env, provider)
    end
  else
    return nil, ("providers.%s has no token_env, token_cmd, or token"):format(provider)
  end

  if not token or token == "" then
    return nil, ("providers.%s credential resolved to an empty value"):format(provider)
  end

  token_cache[provider] = token
  return token
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

return M
