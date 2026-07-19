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
  require("issuehub.backend").reset()

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
    local view_mod = require("issuehub.ui.view")
    local view = view_mod.from_issues(issues, { source = "query", label = name })
    view_mod.with_notes(view:get_items())
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

---Which engine should answer a local search.
---
---Exposed as a pure function because the rule is not obvious and is worth
---pinning: FTS5's unicode61 tokenizer splits on whitespace, so a run of
---Japanese (or Chinese, or Thai) becomes ONE token and substring search cannot
---match it. The trigram tokenizer would fix 3+ character queries but not
---2-character ones, which is the most common Japanese word length. ripgrep
---handles all of it. The two engines were already complementary (§15); this
---routes by what each is actually good at.
---@param pattern string
---@param opts { regex: boolean? }?
---@return "ripgrep"|"index"
function M.search_engine(pattern, opts)
  opts = opts or {}
  if opts.regex then
    return "ripgrep"
  end
  if pattern:find("[\128-\255]") then
    return "ripgrep"
  end
  local index = require("issuehub.core.index").get()
  if index.has_fts and index:has_fts() then
    return "index"
  end
  return "ripgrep"
end

---Browse everything local, filtering live in the picker.
---
---The counterpart to |issuehub.open()|: same UI, different corpus. Typing in
---the picker reaches memo and metadata because those ride along on each item as
---hidden match text, so this needs no prompt of its own.
function M.browse()
  local items = require("issuehub.core.index").get():list()
  if #items == 0 then
    return vim.notify("issuehub: nothing cached yet — run `:IssueHub open` first", vim.log.levels.INFO)
  end

  local view_mod = require("issuehub.ui.view")
  local view = view_mod.new({ source = "find", label = "local", items = view_mod.with_notes(items) })
  require("issuehub.ui.picker").pick(view, { title = ("local (%d)"):format(#items) })
end

---Local search, with optional metadata filters.
---
---Accepts either a plain pattern or a parsed query, so `:IssueHub find` and the
---`Find:` prompt share one syntax:
---    find eviction
---    find --meta priority=high
---    find eviction --meta priority=high --meta tags=cache
---@param input string|issuehub.FindQuery
---@param opts { regex: boolean? }?
function M.find(input, opts)
  opts = opts or {}
  local query_mod = require("issuehub.core.query")
  local query = type(input) == "table" and input or query_mod.parse(input)
  if opts.regex then
    query.regex = true
  end

  -- Nothing specified means "show me everything and let me filter", which is
  -- the same shape as `:IssueHub open` rather than an error.
  if query.pattern == "" and #query.meta == 0 then
    return M.browse()
  end

  local search = require("issuehub.core.search")
  local index = require("issuehub.core.index").get()
  local items

  if query.pattern == "" then
    -- Filter-only: every known issue is a candidate.
    items = index:list()
  elseif M.search_engine(query.pattern, { regex = query.regex }) == "ripgrep" then
    if search.available() then
      local err
      items, err = search.find(query.pattern, { regex = query.regex })
      if err then
        vim.notify("issuehub: " .. err, vim.log.levels.WARN)
        items = index:search(query.pattern)
      end
    else
      local why = query.regex and "--regex" or "this search"
      vim.notify(
        ("issuehub: %s needs ripgrep, which is not installed — results will be incomplete"):format(why),
        vim.log.levels.WARN
      )
      items = index:search(query.pattern)
    end
  else
    items = index:search(query.pattern)
  end

  if #query.meta > 0 then
    items = vim.tbl_filter(function(item)
      return query_mod.matches_meta(item.uri, query.meta, item)
    end, items)
  end

  local label = query_mod.describe(query)
  if #items == 0 then
    return vim.notify("issuehub: no local matches for " .. label, vim.log.levels.INFO)
  end

  local view_mod = require("issuehub.ui.view")
  local view = view_mod.new({ source = "find", label = "find: " .. label, items = view_mod.with_notes(items) })
  require("issuehub.ui.picker").pick(view, { title = ("find (%d)"):format(#items) })
end

---Resolve an export/collection source name to a View.
---@param source string?
---@return issuehub.View?
---@return string? err
function M.resolve_view(source)
  local view_mod = require("issuehub.ui.view")

  if not source or source == "" then
    -- "What I was just looking at" (§9.3).
    local last = view_mod.last()
    if last and not last:is_empty() then
      return last
    end
    source = "local"
  end

  if source == "local" then
    local items = require("issuehub.core.index").get():list({ closed = false })
    return view_mod.new({ source = "query", label = "local", items = items })
  elseif source == "all" then
    return view_mod.new({ source = "query", label = "all", items = require("issuehub.core.index").get():list() })
  elseif source == "bookmarks" then
    local items = require("issuehub.core.index").get():list({ bookmarked = true })
    return view_mod.new({ source = "bookmarks", label = "bookmarks", items = items })
  elseif source == "changed" then
    local items = require("issuehub.core.sync").changed_since_seen()
    return view_mod.new({ source = "changed", label = "changed", items = items })
  end

  local view = require("issuehub.core.collection").to_view(source)
  if view then
    return view
  end
  return nil, ("unknown source '%s' (try a collection name, or local|all|bookmarks|changed)"):format(source)
end

---Export a View.
---@param format string?
---@param source string?
---@param path string?
function M.export(format, source, path)
  local export = require("issuehub.core.export")
  format = format or require("issuehub.config").get().export.default_format

  local view, err = M.resolve_view(source)
  if not view then
    return vim.notify("issuehub: " .. tostring(err), vim.log.levels.ERROR)
  end

  local written, werr = export.write(format, view, { path = path })
  if not written then
    return vim.notify("issuehub: " .. tostring(werr), vim.log.levels.ERROR)
  end
  vim.notify(("issuehub: exported %d issue(s) to %s"):format(#view:get_selected(), written))
end

---Open a collection, or pick one when no name is given.
---@param name string?
function M.collection(name)
  local collections = require("issuehub.core.collection")

  if not name or name == "" then
    local slugs = collections.list()
    if #slugs == 0 then
      return vim.notify("issuehub: no collections yet (`:IssueHub collection add <name>`)", vim.log.levels.INFO)
    end
    return vim.ui.select(slugs, { prompt = "Collection" }, function(chosen)
      if chosen then
        M.collection(chosen)
      end
    end)
  end

  local view = collections.to_view(name)
  if not view then
    return vim.notify(("issuehub: no collection '%s'"):format(name), vim.log.levels.ERROR)
  end
  if view:is_empty() then
    return vim.notify(("issuehub: collection '%s' is empty"):format(name), vim.log.levels.INFO)
  end
  require("issuehub.ui.picker").pick(view, { title = ("%s (%d)"):format(view.label, view:count()) })
end

---Add issues to a collection: the current issue buffer, or the current View.
---@param name string
function M.collection_add(name)
  local collections = require("issuehub.core.collection")
  local uri = require("issuehub.ui.buffer").current_uri()

  local uris = {}
  if uri then
    uris = { uri }
  else
    local view = require("issuehub.ui.view").last()
    if not view or view:is_empty() then
      return vim.notify("issuehub: open an issue or a picker first", vim.log.levels.WARN)
    end
    for _, item in ipairs(view:get_selected()) do
      uris[#uris + 1] = item.uri
    end
  end

  local added = 0
  for _, member in ipairs(uris) do
    if collections.add(name, member) then
      added = added + 1
    end
  end
  vim.notify(("issuehub: added %d issue(s) to '%s'"):format(added, name))
end

---@param name string
function M.collection_remove(name)
  local uri = require("issuehub.ui.buffer").current_uri()
  if not uri then
    return vim.notify("issuehub: not in an issue buffer", vim.log.levels.WARN)
  end
  if require("issuehub.core.collection").remove(name, uri) then
    vim.notify(("issuehub: removed %s from '%s'"):format(uri, name))
  else
    vim.notify(("issuehub: %s is not in '%s'"):format(uri, name), vim.log.levels.WARN)
  end
end

---Open a specific issue URI.
---@param uri string
function M.open_uri(uri)
  require("issuehub.ui.buffer").open(uri)
end

---Everything currently in the local index.
function M.local_issues()
  local view_mod = require("issuehub.ui.view")
  local items = view_mod.with_notes(require("issuehub.core.index").get():list({ closed = false }))
  local view = view_mod.new({ source = "query", label = "local", items = items })
  require("issuehub.ui.picker").pick(view, { title = ("local (%d)"):format(#items) })
end

---Everything bookmarked, across providers.
function M.bookmarks()
  local items = require("issuehub.core.index").get():list({ bookmarked = true })
  if #items == 0 then
    return vim.notify("issuehub: no bookmarks yet (`:IssueHub bookmark` in an issue buffer)", vim.log.levels.INFO)
  end
  local view = require("issuehub.ui.view").new({ source = "bookmarks", label = "bookmarks", items = items })
  require("issuehub.ui.picker").pick(view, { title = ("bookmarks (%d)"):format(#items) })
end

---Sync issues against their providers and report what moved.
---
---@param target string?  A URI, a provider name, or nil for everything local.
function M.sync(target)
  local sync = require("issuehub.core.sync")
  local uris

  if target and require("issuehub.core.issue").is_uri(target) then
    uris = { target }
  else
    uris = sync.targets()
    if target then
      uris = vim.tbl_filter(function(uri)
        return require("issuehub.core.issue").parse(uri) == target
      end, uris)
      if #uris == 0 then
        return vim.notify(("issuehub: nothing cached for provider '%s'"):format(target), vim.log.levels.WARN)
      end
    end
  end

  if #uris == 0 then
    return vim.notify("issuehub: nothing to sync yet — open some issues first", vim.log.levels.INFO)
  end

  vim.notify(("issuehub: syncing %d issue(s)…"):format(#uris))

  sync.many(uris, nil, function(result)
    local lines = {}
    for _, change in ipairs(result.changes) do
      lines[#lines + 1] = "  " .. sync.describe(change)
    end

    local failures = vim.tbl_count(result.errors)
    local summary = ("issuehub: %d changed, %d unchanged"):format(
      #result.changes,
      result.total - #result.changes - failures
    )
    if failures > 0 then
      summary = summary .. (", %d failed"):format(failures)
    end

    if #lines > 0 then
      vim.notify(summary .. "\n" .. table.concat(lines, "\n"))
    else
      vim.notify(summary)
    end

    -- Repaint anything open so the buffer matches what was just fetched.
    local buffer = require("issuehub.ui.buffer")
    for _, change in ipairs(result.changes) do
      buffer.repaint(change.uri)
    end

    if failures > 0 then
      for uri, err in pairs(result.errors) do
        vim.notify(("issuehub: %s — %s"):format(uri, err), vim.log.levels.WARN)
      end
    end
  end)
end

---Issues whose remote revision moved since you last opened them.
function M.changed()
  local items = require("issuehub.core.sync").changed_since_seen()
  if #items == 0 then
    return vim.notify("issuehub: nothing changed since you last looked", vim.log.levels.INFO)
  end
  local view = require("issuehub.ui.view").new({ source = "changed", label = "changed", items = items })
  require("issuehub.ui.picker").pick(view, { title = ("changed (%d)"):format(#items) })
end

---Analyse an issue through the configured Backend and save the result.
---@param uri string?
---@param opts { prompt: string?, selection: string?, include_history: boolean? }?
function M.analyze(uri, opts)
  opts = opts or {}
  uri = uri or require("issuehub.ui.buffer").current_uri()
  if not uri then
    return vim.notify("issuehub: open an issue first, or pass a URI", vim.log.levels.WARN)
  end

  local analysis = require("issuehub.core.analysis")
  local backend = require("issuehub.backend")

  local prompt, source = opts.prompt, "ad-hoc"
  if not prompt then
    prompt, source = analysis.prompt_for(uri)
  end

  vim.notify(("issuehub: analysing %s…"):format(uri))

  backend.send({
    kind = "analyze",
    resource = uri,
    prompt = prompt,
    context = analysis.context(uri, { selection = opts.selection, include_history = opts.include_history }),
  }, {}, function(err, res)
    if err then
      return vim.notify("issuehub: " .. err, vim.log.levels.ERROR)
    end

    local active = select(1, backend.get())
    local stamp, serr = analysis.save(uri, {
      prompt = prompt,
      response = res.text,
      backend = active and active.name or nil,
      model = res.model,
      prompt_source = source,
    })
    if not stamp then
      return vim.notify("issuehub: could not save the analysis — " .. tostring(serr), vim.log.levels.ERROR)
    end

    vim.notify(("issuehub: analysis saved (%s)"):format(stamp))
    require("issuehub.ui.analysis").open(uri, stamp)
  end)
end

---Browse the analysis history of an issue.
---@param uri string?
function M.analyses(uri)
  uri = uri or require("issuehub.ui.buffer").current_uri()
  if not uri then
    return vim.notify("issuehub: open an issue first", vim.log.levels.WARN)
  end

  local entries = require("issuehub.core.analysis").list(uri)
  if #entries == 0 then
    return vim.notify("issuehub: no analyses yet for " .. uri, vim.log.levels.INFO)
  end

  vim.ui.select(entries, {
    prompt = "Analyses",
    format_item = function(entry)
      return ("%s  [%s]  %s"):format(entry.stamp, entry.status, entry.model or entry.backend or "")
    end,
  }, function(entry)
    if entry then
      require("issuehub.ui.analysis").open(uri, entry.stamp)
    end
  end)
end

---@return integer count
function M.reindex()
  local count = require("issuehub.core.index").get():rebuild()
  vim.notify(("issuehub: reindexed %d issue(s)"):format(count))
  return count
end

return M
