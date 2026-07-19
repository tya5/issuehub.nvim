---@brief Provider registry. Resolves a URI scheme to an implementation.
local M = {}

---@type table<string, issuehub.Provider>
local registry = {}

---@type table<string, boolean>
local configured = {}

local BUILTIN = {
  jira = "issuehub.provider.jira",
  redmine = "issuehub.provider.redmine",
  github = "issuehub.provider.github",
  gitlab = "issuehub.provider.gitlab",
}

---Named in the docs and the roadmap, but not shipped yet. Listed so the error
---says "not implemented yet" rather than "unknown provider", which would read as
---a typo.
local PLANNED = {
  azure = "future",
  linear = "future",
  youtrack = "future",
}

---Register a third-party provider.
---@param name string
---@param provider issuehub.Provider
function M.register(name, provider)
  registry[name] = provider
  configured[name] = false
end

---@param name string
---@return issuehub.Provider? provider
---@return string? err
function M.get(name)
  if not registry[name] then
    local module = BUILTIN[name]
    if not module then
      if PLANNED[name] then
        return nil, ("provider '%s' is not implemented yet (planned for %s)"):format(name, PLANNED[name])
      end
      return nil, ("unknown provider '%s' (available: %s)"):format(name, table.concat(vim.tbl_keys(BUILTIN), ", "))
    end
    local ok, impl = pcall(require, module)
    if not ok then
      return nil, ("failed to load provider '%s': %s"):format(name, impl)
    end
    registry[name] = impl.new()
  end

  local provider = registry[name]

  if not configured[name] then
    local opts = require("issuehub.config").get().providers[name]
    if not opts then
      return nil, ("provider '%s' is not configured — add providers.%s to setup()"):format(name, name)
    end
    local ok, err = provider:setup(opts)
    if not ok then
      return nil, err
    end
    configured[name] = true
  end

  return provider
end

---Resolve the provider that owns a URI.
---@param uri string
---@return issuehub.Provider? provider
---@return string? id_or_err
function M.resolve(uri)
  local name, id = require("issuehub.core.issue").parse(uri)
  if not name then
    return nil, ("not a valid issue URI: %s"):format(tostring(uri))
  end
  local provider, err = M.get(name)
  if not provider then
    return nil, err
  end
  return provider, id
end

---Names of every provider present in the user's configuration.
---@return string[]
function M.configured_names()
  return vim.tbl_keys(require("issuehub.config").get().providers)
end

---Drop cached instances. Called on setup() and by tests.
function M.reset()
  registry = {}
  configured = {}
end

return M
