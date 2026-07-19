---@brief Walking a whole query into the cache, page by page.
---
--- Runs in the background: every request is already async (§8), so Neovim stays
--- usable throughout. What this adds is the loop, the progress reporting, the
--- ability to stop, and the ability to resume — a twenty-thousand-issue backlog
--- is minutes of traffic, and an operation that long has to be interruptible
--- and must not lose what it already collected.

local cache = require("issuehub.core.cache")
local listcache = require("issuehub.core.listcache")
local log = require("issuehub.util.log")

local M = {}

---@class issuehub.FetchRun
---@field provider string
---@field query any
---@field pages integer
---@field issues integer
---@field cancelled boolean
---@field running boolean

---@type table<string, issuehub.FetchRun>
local running = {}

---@param provider string
---@param query any
---@return string
local function run_key(provider, query)
  return listcache.key(provider, query)
end

---@return issuehub.FetchRun[]
function M.active()
  return vim.tbl_values(running)
end

---Ask an in-flight walk to stop after the page it is on.
---@param provider string?
---@return integer stopped
function M.cancel(provider)
  local stopped = 0
  for _, run in pairs(running) do
    if not provider or run.provider == provider then
      run.cancelled = true
      stopped = stopped + 1
    end
  end
  return stopped
end

---Walk every page of a query into the cache.
---
---@param provider_name string
---@param opts { query: any?, resume: boolean?, max: integer?, on_progress: fun(run: issuehub.FetchRun)? }?
---@param cb fun(err: string?, run: issuehub.FetchRun?)
function M.all(provider_name, opts, cb)
  opts = opts or {}

  local providers = require("issuehub.provider")
  local provider, perr = providers.get(provider_name)
  if not provider then
    return cb(tostring(perr))
  end
  if type(provider.page) ~= "function" then
    return cb(("provider '%s' does not support paging"):format(provider_name))
  end

  local key = run_key(provider_name, opts.query)
  if running[key] then
    return cb(("a fetch for '%s' is already running"):format(provider_name))
  end

  local cached = listcache.get(provider_name, opts.query)
  -- Resume only when explicitly asked and there is somewhere to resume from;
  -- otherwise start clean so the list reflects the query as it is now.
  local resume = opts.resume and cached and cached.cursor or nil

  ---@type issuehub.FetchRun
  local run = {
    provider = provider_name,
    query = opts.query,
    pages = resume and (cached.pages or 0) or 0,
    issues = resume and #cached.uris or 0,
    cancelled = false,
    running = true,
  }
  running[key] = run

  local function finish(err)
    run.running = false
    running[key] = nil
    cb(err, run)
  end

  local function step(cursor, first)
    provider:page(opts.query, cursor, function(err, issues, next_cursor)
      if err then
        log.warn("fetch failed", provider_name, err)
        -- Keep what we have: the cursor stays, so this is resumable.
        listcache.merge(provider_name, opts.query, {}, { cursor = cursor, complete = false })
        return finish(err)
      end

      issues = issues or {}
      cache.put_all(issues)

      local uris = {}
      for _, issue in ipairs(issues) do
        uris[#uris + 1] = issue.uri
      end

      local list = listcache.merge(provider_name, opts.query, uris, {
        cursor = next_cursor,
        complete = next_cursor == nil,
        -- A fresh walk replaces the list; a resumed one appends.
        reset = first and not resume,
      })

      run.pages = run.pages + 1
      run.issues = #list.uris
      if opts.on_progress then
        opts.on_progress(run)
      end

      if run.cancelled then
        return finish(nil)
      end
      if next_cursor == nil then
        return finish(nil)
      end
      if opts.max and run.issues >= opts.max then
        return finish(nil)
      end

      -- Yield to the event loop between pages so the editor stays responsive
      -- even when the server answers instantly.
      vim.schedule(function()
        step(next_cursor, false)
      end)
    end)
  end

  step(resume, true)
end

return M
