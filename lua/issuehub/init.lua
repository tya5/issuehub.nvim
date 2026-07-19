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
  require("issuehub.core.repository").forget_case_index()
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

---Resolve which server an operation applies to.
---
---Every per-server entry point goes through here, so they cannot drift into
---asking differently — or, worse, into one of them quietly picking the first.
---@param name string?              Explicit choice; skips the prompt.
---@param prompt string
---@param cb fun(provider_name: string)
function M.with_provider(name, prompt, cb)
  local names = require("issuehub.provider").configured_names()
  if #names == 0 then
    return vim.notify("issuehub: no providers configured", vim.log.levels.ERROR)
  end
  if name then
    return cb(name)
  end
  if #names == 1 then
    return cb(names[1])
  end
  vim.ui.select(names, { prompt = prompt }, function(chosen)
    if chosen then
      cb(chosen)
    end
  end)
end

---Open the picker over a provider's default query.
---@param opts { provider: string?, query: any? }?
function M.open(opts)
  opts = opts or {}
  local providers = require("issuehub.provider")

  if not opts.provider then
    return M.with_provider(nil, "Issues from", function(chosen)
      M.open(vim.tbl_extend("force", opts, { provider = chosen }))
    end)
  end
  local name = opts.provider

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

---Walk a provider's whole query into the cache, in the background.
---
---@param provider_name string?
---@param opts { resume: boolean?, query: any? }?
function M.fetch_all(provider_name, opts)
  opts = opts or {}
  if not provider_name then
    return M.with_provider(nil, "Fetch all issues from", function(chosen)
      M.fetch_all(chosen, opts)
    end)
  end
  local name = provider_name

  local fetch = require("issuehub.core.fetch")
  local listcache = require("issuehub.core.listcache")

  local existing = listcache.get(name, opts.query)
  if existing and not existing.complete and not opts.resume then
    vim.notify(
      ("issuehub: %s has a partial list (%d issues, %s) — `:IssueHub fetch resume` continues it"):format(
        name,
        #existing.uris,
        listcache.describe(existing)
      ),
      vim.log.levels.INFO
    )
  end

  vim.notify(("issuehub: fetching all of %s in the background… (`:IssueHub fetch stop` to stop)"):format(name))

  local last_report = 0
  fetch.all(name, {
    query = opts.query,
    resume = opts.resume,
    on_progress = function(run)
      -- Report on a timer rather than per page: a fast server would otherwise
      -- bury the user in notifications.
      local now = vim.uv.now()
      if now - last_report > 3000 then
        last_report = now
        vim.notify(("issuehub: %s — %d issues, %d pages"):format(run.provider, run.issues, run.pages))
      end
    end,
  }, function(err, run)
    if err then
      return vim.notify(
        ("issuehub: fetch stopped after %d issues — %s (`:IssueHub fetch resume` continues)"):format(
          run and run.issues or 0,
          err
        ),
        vim.log.levels.WARN
      )
    end

    local list = listcache.get(name, opts.query)
    local state = run.cancelled and "cancelled" or (list and list.complete and "complete" or "incomplete")
    vim.notify(("issuehub: %s fetch %s — %d issues in %d pages"):format(name, state, run.issues, run.pages))
  end)
end

---Show what has been cached per query, and how fresh it is.
function M.lists()
  local listcache = require("issuehub.core.listcache")
  local lists = listcache.all()
  if #lists == 0 then
    return vim.notify("issuehub: no cached lists yet — run `:IssueHub fetch`", vim.log.levels.INFO)
  end

  local lines = {}
  for _, list in ipairs(lists) do
    lines[#lines + 1] = ("  %-12s %5d issues  %s"):format(list.provider, #list.uris, listcache.describe(list))
  end
  vim.notify("issuehub cached lists:\n" .. table.concat(lines, "\n"))
end

---Browse everything local, filtering live in the picker.
---
---The counterpart to |issuehub.open()|: same UI, different corpus. Typing in
---the picker reaches memo and metadata because those ride along on each item as
---hidden match text, so this needs no prompt of its own.
---@param provider_name string?
function M.browse(provider_name)
  M.with_provider(provider_name, "Browse local issues from", function(name)
    -- Scoped to one server, like `open`. Nothing is loaded from the others:
    -- mixing trackers in one list makes the ids ambiguous to scan and the
    -- filter terms mean different things per server.
    local items = require("issuehub.core.index").get():list({ provider = name })
    if #items == 0 then
      return vim.notify(
        ("issuehub: nothing cached for %s yet — `:IssueHub open` or `:IssueHub fetch` first"):format(name),
        vim.log.levels.INFO
      )
    end

    local view_mod = require("issuehub.ui.view")
    local view = view_mod.new({ source = "find", label = name, items = view_mod.with_notes(items) })
    require("issuehub.ui.picker").pick(view, { title = ("%s local (%d)"):format(name, #items) })
  end)
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

---Every issue known locally: the cache and the workspace, merged.
---
--- The two do not contain the same set. An issue you annotated months ago may
--- have fallen out of the cache, and an issue you fetched may have no notes.
--- Exporting either alone silently drops rows, so the union is the honest
--- default — with blanks where one side has nothing to say.
---@param provider_name string?   Scope to one server.
---@return issuehub.ViewItem[]
function M.merged_items(provider_name)
  local index = require("issuehub.core.index").get()
  local issue_mod = require("issuehub.core.issue")
  local cache = require("issuehub.core.cache")

  local items, seen = {}, {}
  for _, item in ipairs(index:list({ provider = provider_name })) do
    seen[item.uri] = true
    items[#items + 1] = item
  end

  -- Anything with local notes that the index does not know about.
  for _, uri in ipairs(require("issuehub.core.workspace").with_overlay()) do
    local provider = issue_mod.parse(uri)
    if not seen[uri] and (not provider_name or provider == provider_name) then
      seen[uri] = true
      local entry = cache.get(uri)
      if entry and entry.issue then
        items[#items + 1] = issue_mod.to_item(entry.issue)
      else
        -- No payload at all: the row still carries the workspace side, and the
        -- issue columns come out empty rather than the row vanishing.
        items[#items + 1] = {
          uri = uri,
          id = select(2, issue_mod.parse(uri)) or uri,
          title = "",
          status = "",
          closed = false,
          updated_at = "",
          bookmarked = false,
        }
      end
    end
  end

  return require("issuehub.core.index").sort(items)
end

---Resolve an export/collection source name to a View.
---
---Order matters: a collection you named wins over a provider of the same name,
---because you created it deliberately.
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
    source = "all"
  end

  if source == "local" then
    local items = require("issuehub.core.index").get():list({ closed = false })
    return view_mod.new({ source = "query", label = "local", items = items })
  elseif source == "all" then
    -- Cache and workspace merged, so nothing local is left out.
    return view_mod.new({ source = "query", label = "all", items = M.merged_items(nil) })
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

  -- A provider instance name exports that server's merged set.
  if vim.tbl_contains(require("issuehub.provider").configured_names(), source) then
    return view_mod.new({ source = "query", label = source, items = M.merged_items(source) })
  end

  return nil, ("unknown source '%s' (a collection, a provider name, or local|all|bookmarks|changed)"):format(source)
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
---@param provider_name string?
function M.local_issues(provider_name)
  M.with_provider(provider_name, "Local issues from", function(name)
    local view_mod = require("issuehub.ui.view")
    local items = view_mod.with_notes(require("issuehub.core.index").get():list({ closed = false, provider = name }))
    local view = view_mod.new({ source = "query", label = name, items = items })
    require("issuehub.ui.picker").pick(view, { title = ("%s local (%d)"):format(name, #items) })
  end)
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

  local threshold = require("issuehub.config").get().sync.confirm_above
  if threshold and threshold > 0 and #uris > threshold then
    -- One request per issue. On a tracker with thousands of tickets that is
    -- minutes of traffic and a plausible rate-limit problem, so it is asked
    -- rather than assumed.
    return vim.ui.select({ "no", "yes" }, {
      prompt = ("Sync %d issues? That is one request each."):format(#uris),
    }, function(choice)
      if choice == "yes" then
        M._sync(uris)
      end
    end)
  end

  M._sync(uris)
end

---@param uris string[]
function M._sync(uris)
  local sync = require("issuehub.core.sync")
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

---Open the conversation window: analysis history plus the next prompt.
---@param uri string?
function M.conversation(uri)
  require("issuehub.ui.conversation").open(uri or require("issuehub.ui.buffer").current_uri(), { focus = true })
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
    -- The answer belongs in the conversation, next to the prompt that produced
    -- it, rather than in a window of its own.
    require("issuehub.ui.conversation").open(uri, { focus = true })
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
