---@brief issuehub.nvim public API.
---
--- setup() is exported so lazy.nvim's `opts = {}` works, but calling it is not
--- required for the plugin to load — only for provider credentials, which have
--- no sensible default (§1.4).

local M = {}

M.VERSION = "0.1.0"

---@param opts issuehub.Config?
function M.setup(opts)
  local config = require("issuehub.config")
  local errors = config.setup(opts)

  -- Cached singletons must not survive a re-setup with different options.
  require("issuehub.provider").reset()
  require("issuehub.core.index").reset()
  require("issuehub.ui.picker").reset()

  if #errors > 0 then
    vim.notify("issuehub: invalid configuration\n  - " .. table.concat(errors, "\n  - "), vim.log.levels.ERROR)
    return
  end

  if config.get().workspace then
    local ok, err = require("issuehub.core.repository").ensure()
    if not ok then
      vim.notify("issuehub: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

---Open the picker over a provider's default query.
---@param opts { provider: string?, query: any? }?
function M.open(opts)
  opts = opts or {}
  local providers = require("issuehub.provider")

  local name = opts.provider
  if not name then
    local names = providers.configured_names()
    if #names == 0 then
      return vim.notify("issuehub: no providers configured", vim.log.levels.ERROR)
    end
    if #names > 1 and not opts.query then
      return vim.ui.select(names, { prompt = "Provider" }, function(chosen)
        if chosen then
          M.open(vim.tbl_extend("force", opts, { provider = chosen }))
        end
      end)
    end
    name = names[1]
  end

  local provider, err = providers.get(name)
  if not provider then
    return vim.notify("issuehub: " .. tostring(err), vim.log.levels.ERROR)
  end

  vim.notify(("issuehub: querying %s…"):format(name), vim.log.levels.INFO)
  provider:list(opts.query, function(lerr, issues)
    if lerr then
      return vim.notify("issuehub: " .. lerr, vim.log.levels.ERROR)
    end
    require("issuehub.core.cache").put_all(issues)
    local view = require("issuehub.ui.view").from_issues(issues, { source = "query", label = name })
    require("issuehub.ui.picker").pick(view, { title = ("%s (%d)"):format(name, #issues) })
  end)
end

---Provider-side search. The query is passed through, not translated (§7).
---@param query string
---@param provider_name string?
function M.search(query, provider_name)
  local providers = require("issuehub.provider")
  local name = provider_name or providers.configured_names()[1]
  if not name then
    return vim.notify("issuehub: no providers configured", vim.log.levels.ERROR)
  end

  local provider, err = providers.get(name)
  if not provider then
    return vim.notify("issuehub: " .. tostring(err), vim.log.levels.ERROR)
  end

  provider:search(query, function(serr, issues)
    if serr then
      return vim.notify("issuehub: " .. serr, vim.log.levels.ERROR)
    end
    require("issuehub.core.cache").put_all(issues)
    local view = require("issuehub.ui.view").from_issues(issues, { source = "query", label = "search: " .. query })
    require("issuehub.ui.picker").pick(view, { title = ("search (%d)"):format(#issues) })
  end)
end

---Local search over the index.
---@param pattern string
function M.find(pattern)
  local items = require("issuehub.core.index").get():search(pattern)
  if #items == 0 then
    return vim.notify("issuehub: no local matches for " .. pattern, vim.log.levels.INFO)
  end
  local view = require("issuehub.ui.view").new({ source = "find", label = "find: " .. pattern, items = items })
  require("issuehub.ui.picker").pick(view, { title = ("find (%d)"):format(#items) })
end

---Open a specific issue URI.
---@param uri string
function M.open_uri(uri)
  require("issuehub.ui.buffer").open(uri)
end

---Everything currently in the local index.
function M.local_issues()
  local items = require("issuehub.core.index").get():list({ closed = false })
  local view = require("issuehub.ui.view").new({ source = "query", label = "local", items = items })
  require("issuehub.ui.picker").pick(view, { title = ("local (%d)"):format(#items) })
end

---@return integer count
function M.reindex()
  local count = require("issuehub.core.index").get():rebuild()
  vim.notify(("issuehub: reindexed %d issue(s)"):format(count))
  return count
end

return M
