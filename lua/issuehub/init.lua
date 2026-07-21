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

---Resolve which server, and then which project, an operation applies to.
---
---A server usually holds many projects, and a list mixing them is as hard to
---read as one mixing servers. Every scoped entry point goes through here, so
---they cannot drift into asking differently.
---
---Projects come from `providers.<name>.projects` when you have listed them, and
---otherwise from what has actually been seen locally — so it costs nothing on a
---fresh workspace and sharpens as you use it. "All projects" stays offered,
---because sometimes that is the question.
---@param opts { provider: string?, project: string?, prompt: string?, all_projects: boolean? }
---@param cb fun(provider: string, project: string?)
function M.with_scope(opts, cb)
  opts = opts or {}
  local names = require("issuehub.provider").configured_names()
  if #names == 0 then
    return vim.notify("issuehub: no providers configured", vim.log.levels.ERROR)
  end

  local function choose_project(provider)
    if opts.all_projects then
      return cb(provider, nil)
    end
    if opts.project and opts.project ~= "" then
      return cb(provider, opts.project)
    end

    local settings = require("issuehub.config").get().providers[provider] or {}
    if settings.default_project then
      return cb(provider, settings.default_project)
    end

    local projects = settings.projects
    if not projects or #projects == 0 then
      projects = require("issuehub.core.index").get():projects(provider)
    end

    -- Nothing to choose between: one project, or none seen yet.
    if #projects <= 1 then
      return cb(provider, projects[1])
    end

    local choices = vim.list_extend({ "(all projects)" }, projects)
    vim.ui.select(choices, { prompt = (opts.prompt or "Project") .. " — " .. provider }, function(chosen)
      if chosen then
        cb(provider, chosen ~= "(all projects)" and chosen or nil)
      end
    end)
  end

  if opts.provider then
    return choose_project(opts.provider)
  end
  if #names == 1 then
    return choose_project(names[1])
  end
  vim.ui.select(names, { prompt = opts.prompt or "Server" }, function(chosen)
    if chosen then
      choose_project(chosen)
    end
  end)
end

---Server only, without a project prompt. For operations that are inherently
---whole-server, like fetching everything.
---@param name string?
---@param prompt string
---@param cb fun(provider_name: string)
function M.with_provider(name, prompt, cb)
  M.with_scope({ provider = name, prompt = prompt, all_projects = true }, function(provider)
    cb(provider)
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
---@param provider_name string?
---@param project string?
function M.browse(provider_name, project)
  M.with_scope({ provider = provider_name, project = project, prompt = "Browse" }, function(name, chosen)
    -- Scoped to one server and, where there is more than one, to one project.
    -- A list mixing projects is as hard to read as one mixing servers.
    local items = require("issuehub.core.index").get():list({ provider = name, project = chosen })
    local label = chosen and ("%s / %s"):format(name, chosen) or name

    if #items == 0 then
      return vim.notify(
        ("issuehub: nothing cached for %s yet — `:IssueHub open` or `:IssueHub fetch` first"):format(label),
        vim.log.levels.INFO
      )
    end

    local view_mod = require("issuehub.ui.view")
    local view = view_mod.new({ source = "find", label = label, items = view_mod.with_notes(items) })
    require("issuehub.ui.picker").pick(view, { title = ("%s (%d)"):format(label, #items) })
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
---@param project string?         Scope further to one project.
---@return issuehub.ViewItem[]
function M.merged_items(provider_name, project)
  local index = require("issuehub.core.index").get()
  local issue_mod = require("issuehub.core.issue")
  local cache = require("issuehub.core.cache")

  local items, seen = {}, {}
  for _, item in ipairs(index:list({ provider = provider_name, project = project })) do
    seen[item.uri] = true
    items[#items + 1] = item
  end

  -- Anything with local notes that the index does not know about.
  for _, uri in ipairs(require("issuehub.core.workspace").with_overlay()) do
    local provider = issue_mod.parse(uri)
    if not seen[uri] and (not provider_name or provider == provider_name) then
      local entry = cache.get(uri)
      -- A project filter can only apply to something with a payload; an issue
      -- known only by its notes has no project to compare.
      if project and not (entry and entry.issue and entry.issue.project == project) then
        goto continue
      end
      seen[uri] = true
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
    ::continue::
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

  -- A provider instance name, or `provider/project`, exports that merged set.
  local provider, project = source:match("^([^/]+)/(.+)$")
  provider = provider or source
  if vim.tbl_contains(require("issuehub.provider").configured_names(), provider) then
    return view_mod.new({ source = "query", label = source, items = M.merged_items(provider, project) })
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

---Merge an exported file back into the workspace.
---
---Only the local half is merged: memo, `meta.*`, and bookmarks. Issue columns
---are read and discarded — the tracker owns those, and importing them would let
---a stale spreadsheet overwrite the cache with fiction.
---
---The file wins on conflict, which is safe because the workspace is a Git
---repository: `git diff` is the undo. When it is NOT one, that net is gone, so
---say so rather than assume.
---@param path string
---@param opts { dry_run: boolean? }?
function M.import(path, opts)
  opts = opts or {}
  if not path or path == "" then
    return vim.notify("issuehub: :IssueHub import <file> [--dry-run]", vim.log.levels.ERROR)
  end

  local result, err = require("issuehub.core.import").run(path, opts)
  if not result then
    return vim.notify("issuehub: " .. tostring(err), vim.log.levels.ERROR)
  end

  local verb = opts.dry_run and "would update" or "updated"
  local lines = { ("issuehub: %s %d issue(s), %d unchanged"):format(verb, #result.imported, result.unchanged) }

  if #result.overwritten > 0 then
    local names = {}
    for _, item in ipairs(result.overwritten) do
      names[#names + 1] = ("%s (%s)"):format(item.uri, item.field)
    end
    lines[#lines + 1] = ("  overwrote existing local content in %d place(s):"):format(#result.overwritten)
    for i = 1, math.min(#names, 8) do
      lines[#lines + 1] = "    " .. names[i]
    end
    if #names > 8 then
      lines[#lines + 1] = ("    … and %d more"):format(#names - 8)
    end
  end

  if #result.metadata_comments > 0 then
    -- metadata.yaml is normally written back verbatim; an import regenerates it.
    lines[#lines + 1] = ("  NOTE: comments in metadata.yaml were lost for %d issue(s)"):format(
      #result.metadata_comments
    )
  end

  for _, e in ipairs(result.errors) do
    lines[#lines + 1] = "  error: " .. e
  end

  if not opts.dry_run and #result.imported > 0 then
    local root = require("issuehub.core.repository").root()
    if root and not require("issuehub.util.fs").is_dir(vim.fs.joinpath(root, ".git")) then
      lines[#lines + 1] = "  WARNING: this workspace is not a Git repository, so there is no `git diff` to undo with"
    else
      lines[#lines + 1] = "  review with: git -C " .. (root or "<workspace>") .. " diff"
    end
  end

  vim.notify(table.concat(lines, "\n"), #result.errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
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
function M.local_issues(provider_name, project)
  M.with_scope({ provider = provider_name, project = project, prompt = "Local issues" }, function(name, chosen)
    local view_mod = require("issuehub.ui.view")
    local items = view_mod.with_notes(
      require("issuehub.core.index").get():list({ closed = false, provider = name, project = chosen })
    )
    local label = chosen and ("%s / %s"):format(name, chosen) or name
    local view = view_mod.new({ source = "query", label = label, items = items })
    require("issuehub.ui.picker").pick(view, { title = ("%s local (%d)"):format(label, #items) })
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

---Translate an issue through the configured Backend and store the result.
---
---User-triggered by design: nothing is sent anywhere unless asked, and a
---translation costs a model call.
---@param lang string?
---@param uri string?
function M.translate(lang, uri)
  uri = uri or require("issuehub.ui.buffer").current_uri()
  if not uri then
    return vim.notify("issuehub: open an issue first, or pass a URI", vim.log.levels.WARN)
  end

  local settings = require("issuehub.config").get().translate
  if not lang or lang == "" then
    lang = settings.default_language
  end

  if not lang or lang == "" then
    local choices = settings.languages
    if choices and #choices > 0 then
      return vim.ui.select(choices, { prompt = "Translate into" }, function(chosen)
        if chosen then
          M.translate(chosen, uri)
        end
      end)
    end
    return vim.ui.input({ prompt = "Translate into (e.g. ja): " }, function(value)
      if value and vim.trim(value) ~= "" then
        M.translate(vim.trim(value), uri)
      end
    end)
  end

  local translation = require("issuehub.core.translation")
  local request, err = translation.request(uri, lang, { include_comments = settings.include_comments })
  if not request then
    return vim.notify("issuehub: " .. tostring(err), vim.log.levels.ERROR)
  end

  local existing = translation.get(uri, lang)
  if existing and existing.status == "current" then
    vim.notify(("issuehub: %s translation is already current — regenerating"):format(lang), vim.log.levels.INFO)
  end

  vim.notify(("issuehub: translating %s into %s…"):format(uri, lang))

  require("issuehub.backend").send(request, {}, function(serr, res)
    if serr then
      return vim.notify("issuehub: " .. serr, vim.log.levels.ERROR)
    end

    local title, body = translation.split_reply(res.text)
    if body == "" then
      return vim.notify("issuehub: the backend returned an empty translation", vim.log.levels.ERROR)
    end

    local active = select(1, require("issuehub.backend").get())
    local ok, werr = translation.save(uri, lang, {
      title = title,
      body = body,
      backend = active and active.name or nil,
      model = res.model,
    })
    if not ok then
      return vim.notify("issuehub: could not save the translation — " .. tostring(werr), vim.log.levels.ERROR)
    end

    vim.notify(("issuehub: %s translation saved"):format(lang))
    require("issuehub.ui.translation").open(uri, lang)
  end)
end

---List an issue's attachments and download the one you pick.
---
--- Explicit by design: `sync` records that a file exists, and nothing transfers
--- until this is called. On a large tracker, fetching attachments during sync
--- would move gigabytes for files nobody asked for.
---@param uri string?
---@param opts { all: boolean? }?
function M.attachments(uri, opts)
  opts = opts or {}
  uri = uri or require("issuehub.ui.buffer").current_uri()
  if not uri then
    return vim.notify("issuehub: open an issue first, or pass a URI", vim.log.levels.WARN)
  end

  local attachment = require("issuehub.core.attachment")
  local items = attachment.list(uri)
  if #items == 0 then
    local cached = require("issuehub.core.cache").get(uri)
    if not cached then
      return vim.notify(("issuehub: %s is not cached — open or sync it first"):format(uri), vim.log.levels.WARN)
    end
    -- Distinguish "none" from "the cache predates attachment support", which
    -- otherwise looks identical and sends people hunting for a bug.
    return vim.notify(
      ("issuehub: no attachments recorded for %s (run `:IssueHub refresh` if you expected some)"):format(uri),
      vim.log.levels.INFO
    )
  end

  if opts.all then
    return M._fetch_attachments(uri, items)
  end

  vim.ui.select(items, {
    prompt = "Attachment",
    format_item = function(att)
      return ("%s  %s  [%s]"):format(
        att.filename,
        attachment.human_size(att.size or att.bytes),
        att.downloaded and "downloaded" or "not downloaded"
      )
    end,
  }, function(chosen)
    if chosen then
      M._fetch_attachments(uri, { chosen }, { open = true })
    end
  end)
end

---@param uri string
---@param items issuehub.StoredAttachment[]
---@param opts { open: boolean? }?
function M._fetch_attachments(uri, items, opts)
  opts = opts or {}
  local attachment = require("issuehub.core.attachment")
  local pending, failed = #items, {}

  for _, att in ipairs(items) do
    if not att.downloaded then
      vim.notify(("issuehub: downloading %s…"):format(att.filename))
    end
    attachment.fetch(uri, att, function(err, path)
      if err then
        failed[#failed + 1] = ("%s: %s"):format(att.filename, err)
      elseif opts.open then
        -- The path is the deliverable; opening it is a convenience, and
        -- vim.ui.open is the seam that keeps this plugin out of the business
        -- of knowing how to view a PDF.
        vim.notify(("issuehub: %s"):format(path))
        pcall(vim.ui.open, path)
      end

      pending = pending - 1
      if pending == 0 then
        if #failed > 0 then
          vim.notify("issuehub: " .. table.concat(failed, "\n"), vim.log.levels.ERROR)
        elseif not opts.open then
          vim.notify(("issuehub: %d attachment(s) in %s"):format(#items, attachment.dir(uri)))
        end
      end
    end)
  end
end

---The knowledge issuehub holds about an issue, assembled for another tool.
---
--- This is the seam for a conversational agent client (e.g. reyn.nvim over
--- AG-UI): issuehub is the information provider and knowledge store, the agent
--- is the analysis engine. The two rules that shape this return are deliberate:
---
--- 1. **Attachments are given as file PATHS, not content.** An agent that shares
---    the filesystem reads them itself, which is the whole point — embedding a
---    log in the prompt is exactly the token cost worth avoiding. This is the
---    opposite of what a remote model needs (`backend/message` embeds text,
---    because a model cannot open a path), so the two paths are kept separate on
---    purpose.
--- 2. **It reports what is on disk, it does not fetch.** Downloading stays
---    explicit (`:IssueHub attachments`); `undownloaded` lists what the caller
---    must fetch first if it needs those bytes, rather than this function
---    reaching out on its behalf.
---@param uri string
---@param opts { include_analyses: boolean?, include_translations: boolean? }?
---@return issuehub.IssueContext? context
---@return string? err
function M.context(uri, opts)
  opts = opts or {}
  if not uri or not require("issuehub.core.issue").is_uri(uri) then
    return nil, ("not a valid issue URI: %s"):format(tostring(uri))
  end

  local cache = require("issuehub.core.cache")
  local attachment = require("issuehub.core.attachment")
  local entry = cache.get(uri)

  local attachments, undownloaded = {}, {}
  for _, att in ipairs(attachment.list(uri)) do
    attachments[#attachments + 1] = {
      id = att.id,
      filename = att.filename,
      -- Present whether or not the bytes are here yet; `downloaded` says which.
      path = att.path,
      downloaded = att.downloaded,
      size = att.size or att.bytes,
      mime = att.mime,
      url = att.url,
    }
    if not att.downloaded then
      undownloaded[#undownloaded + 1] = att.id
    end
  end

  local context = {
    uri = uri,
    issue = entry and entry.issue or nil,
    cached = entry ~= nil,
    overlay = require("issuehub.core.overlay").read(uri),
    attachments = attachments,
    undownloaded = undownloaded,
  }

  if opts.include_analyses then
    context.analyses = require("issuehub.core.analysis").list(uri)
  end
  if opts.include_translations then
    local translation = require("issuehub.core.translation")
    context.translations = {}
    for _, lang in ipairs(translation.languages(uri)) do
      context.translations[#context.translations + 1] = translation.get(uri, lang)
    end
  end

  return context
end

---Ensure attachments are on disk, and hand back their paths — programmatically.
---
--- The counterpart to `M.context` for a client (reyn.nvim, a script) that wants
--- the FILES, not just the metadata. `M.context` reports what is on disk and
--- never fetches; this fetches on request, so the two stay honest about which
--- one reaches the network. Non-interactive by design: no notifications, no
--- opening — just the callback, so it composes inside another tool's flow.
---
--- Already-downloaded attachments return immediately (no network). Per-file
--- failures land in `failed` keyed by id; only a precondition failure (bad URI)
--- returns through the second value. `ids` is nil/empty for "all of them".
---@param uri string
---@param ids string[]?
---@param cb fun(result: { paths: table<string,string>, failed: table<string,string> }?, err: string?)
function M.fetch_attachments(uri, ids, cb)
  if not uri or not require("issuehub.core.issue").is_uri(uri) then
    return cb(nil, ("not a valid issue URI: %s"):format(tostring(uri)))
  end

  local attachment = require("issuehub.core.attachment")
  local by_id = {}
  for _, att in ipairs(attachment.list(uri)) do
    by_id[att.id] = att
  end

  -- Resolve the target set: the requested ids, or everything the issue has.
  local wanted = {}
  if ids and #ids > 0 then
    for _, id in ipairs(ids) do
      wanted[#wanted + 1] = tostring(id)
    end
  else
    for id in pairs(by_id) do
      wanted[#wanted + 1] = id
    end
  end

  local result = { paths = {}, failed = {} }
  local pending = #wanted
  if pending == 0 then
    return cb(result)
  end

  local function settle()
    pending = pending - 1
    if pending == 0 then
      cb(result)
    end
  end

  for _, id in ipairs(wanted) do
    local att = by_id[id]
    if not att then
      -- An id the issue does not carry: report it rather than hang the count.
      result.failed[id] = "no such attachment"
      settle()
    else
      attachment.fetch(uri, att, function(err, path)
        if path then
          result.paths[id] = path
        else
          result.failed[id] = err or "download failed"
        end
        settle()
      end)
    end
  end
end

---Save an analysis produced elsewhere (an agent client, a script) into this
---issue's history — so the knowledge stays in issuehub even when another tool
---did the analysing. A thin, deliberate counterpart to `M.context`.
---@param uri string
---@param data { prompt: string?, response: string, backend: string?, model: string? }
---@return string? stamp
---@return string? err
function M.record_analysis(uri, data)
  if not uri or not require("issuehub.core.issue").is_uri(uri) then
    return nil, ("not a valid issue URI: %s"):format(tostring(uri))
  end
  if type(data) ~= "table" or type(data.response) ~= "string" or data.response == "" then
    return nil, "an analysis needs a non-empty response"
  end
  -- analysis.save writes prompt.md unconditionally; an external caller may not
  -- have one, so give it an honest placeholder rather than crash on nil.
  return require("issuehub.core.analysis").save(uri, {
    prompt = data.prompt or "(analysis recorded from an external client)",
    prompt_source = "external",
    response = data.response,
    backend = data.backend,
    model = data.model,
  })
end

---Browse an issue's stored translations.
---@param uri string?
function M.translations(uri)
  uri = uri or require("issuehub.ui.buffer").current_uri()
  if not uri then
    return vim.notify("issuehub: open an issue first", vim.log.levels.WARN)
  end
  require("issuehub.ui.translation").select(uri)
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
