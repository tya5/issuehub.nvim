# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is pre-1.0: the public API may break between minor versions until
1.0, and each such break is listed here.

## [Unreleased]

### Added

- **`:IssueHub fetch` — cache a whole tracker in the background.** Pages through
  everything a server's query matches, per server, without blocking the editor.
  `status`, `stop`, and `resume` sub-actions. Progress is reported on a timer
  rather than per page, so a fast server does not bury you in notifications.
- **Cached issue *lists*** under `.state/lists/`, keyed by (provider, query).
  Pages merge in as they arrive rather than being all-or-nothing, so an
  interrupted walk of a twenty-thousand-issue backlog keeps what it collected
  and stores the cursor to continue from. The list carries its own `fetched_at`,
  because "which issues matched this query, and when did I last ask" is a
  different fact from "what is in PROJ-123" and deserves its own freshness.
- Providers expose `page(query, cursor, cb)` for a single page; `list` and
  `search` are that in a loop. This is what makes an incremental, resumable walk
  possible at all.
- **Pagination.** Queries fetched only the first page before, which made older
  tickets unreachable. `providers.<name>.max_results` pages until that many
  results and `per_page` sets the page size; the default is still one page, so
  a large backlog is not pulled down by accident. Paging stops at a short page,
  keeps partial results if a later page fails, and GitHub search stops before
  its 1000-result ceiling rather than surfacing a 422.

### Performance

Sized for trackers with tens of thousands of tickets:

- The cache's case-collision check listed the whole provider directory on every
  write — O(n) per write, O(n²) for a bulk fetch. Now memoised.
- Bulk fetches wrote the index once per issue, which on the sqlite backend meant
  one `sqlite3` process per issue. `put_many` batches into a single invocation
  inside one transaction.
- Opening a picker read three files per issue to look for notes, nearly all of
  which do not exist. It now resolves which issues have a workspace directory
  with two readdirs and reads only those.
- Cache and index writes skip `fsync`. The rename still makes them atomic;
  durability across a power cut is worth paying for user notes and pointless for
  `.state/`, which is declared rebuildable. Measured 1.66s to 372ms for 300
  issues.
- `:IssueHub sync` asks before syncing more than `sync.confirm_above` issues
  (default 200), since it is one request each.

### Changed

- **`<Plug>(IssueHubFind)` no longer prompts.** It opens the picker immediately
  and filters as you type, which is the same shape as `<Plug>(IssueHubOpen)` —
  the two now differ only in corpus, not in interaction. Memo and metadata ride
  along on each row as hidden match text, so typing a word that appears only in
  your notes still narrows the list without showing the note. Metadata is also
  folded in as normalized `key:value` tokens, so `priority:high` and
  `tags:cache` filter structurally in the picker — substring matching, so
  `--meta` remains the exact form.
- **Built-in fields filter the same way as metadata**: `status:`, `state:`,
  `provider:`, `assignee:`, `bookmarked:` and `labels:` work both as picker
  tokens and as `--meta` keys. When filtering, it does not matter which side a
  field came from. Metadata you wrote wins over a built-in of the same name.
  Filter values normalise spaces and underscores to hyphens, so
  `--meta status=in-progress` and `--meta "status=In Progress"` both match. `:IssueHub find
  {query}` remains the precise form and still reaches analysis history and
  regexes a picker filter cannot.
- `issuehub.browse()` is the new no-argument entry point; `find("")` routes to
  it rather than warning, since "find nothing in particular" is a request to see
  the corpus.

### Added

- **Metadata filters for `:IssueHub find`**: `--meta priority=high`,
  `--meta owner` for a presence test, and `--meta tags=cache` to match a value
  inside a YAML list. Filters are ANDed and compare case-insensitively, and
  combine with free text. With filters and no text, every known issue is a
  candidate. `core/query.lua` parses both the subcommand's arguments and the
  `Find:` prompt, so the two entry points share one syntax by construction.

### Fixed

- **`<Plug>(IssueHubFind)` never prompted.** It called `find("")` directly, so
  pressing the mapping searched for an empty string and found nothing, no matter
  what you typed afterwards. The subcommand prompted correctly, so the two entry
  points had silently diverged; they now share one `ask()` helper, `find()`
  refuses an empty pattern out loud, and a spec pins the mapping's shape.
- **Japanese (and any space-less script) was silently unsearchable.** FTS5's
  `unicode61` tokenizer splits on whitespace, so `認証まわりの調査メモ` was
  indexed as one token and searching `認証` returned nothing — no error, just an
  empty result. The `trigram` tokenizer was evaluated and rejected: it fixes
  3-character queries but not 2-character ones, which is the most common
  Japanese word length. Non-ASCII queries now route to ripgrep, which handles
  all of it. `issuehub.search_engine()` exposes the rule as a pure function so
  it is pinned by specs rather than buried in a branch.
- The snacks picker preview wrote into `ctx.buf`, but snacks hands the previewer
  an object rather than a buffer handle; the preview pane showed an error.
- The fzf-lua adapter declared `preview = true` while implementing no previewer.
  It now declares `preview = false`, and a spec pins every adapter's
  capabilities so a false claim fails the suite instead of a user's pane.

### Documentation

- Install instructions now cover a trap found while installing into a real
  LazyVim config: adding `keys` to the lazy.nvim spec switches the whole plugin
  into deferred mode, so `:IssueHub` does not exist and `:checkhealth issuehub`
  reports "No healthcheck found" until one of those keys is pressed. The fix is
  `lazy = false`, which costs nothing here because the startup file requires no
  implementation modules. README and `:help issuehub-lazy-keys`.
- Documented `token_cmd = { "gh", "auth", "token" }` (and `glab auth token`),
  which reuses an existing CLI login and stores no credential anywhere.

### Added

- **Documentation and the public API surface (0.7).**
  - `doc/issuehub.txt`: a hand-written vimdoc reference covering every option,
    command, and public function, plus the extension guide. panvimdoc was
    dropped — it renders the README, and the README is a guide while a help file
    needs to be a reference; generating one from the other would produce a worse
    version of both. A spec asserts that every `|tag|` resolves and that no line
    exceeds 78 display columns.
  - `:help issuehub-api` documents the **public surface explicitly**. Anything
    not listed is internal and may change without notice. That boundary is what
    gets frozen at 1.0.
  - Release workflow: `luarocks-tag-release` plus a GitHub release on `v*` tags.
    The rockspec now ships `doc/`.

- **Full-text search over your notes (0.6).** The FTS5 schema has carried memo,
  metadata, and analyses columns since 0.1, but only title and description were
  ever written into them. They are now populated, so `:IssueHub find` searches
  everything you wrote about an issue — not just what the tracker returned.
  - Results say **which column matched** (`[memo]`, `[metadata]`, `[analyses]`),
    using snippet markers, so the FTS path is as informative as the ripgrep one.
  - The index is refreshed when notes are saved and when an analysis is written,
    and a rebuild recovers the prose from the Repository — the index still holds
    no truth of its own.

- **Backends and analysis history (0.5).** AI is opt-in and routed through a
  single interface; the default `none` backend sends nothing anywhere.
  - **Requests carry a `kind`** and backends advertise which kinds they handle,
    so LLM completion slots in without the interface moving. `backend.complete()`
    is a documented extension point that nothing in issuehub calls yet. A request
    of an unadvertised kind is refused clearly rather than sent and
    misunderstood.
  - **A2A backend**, loaded only when selected: agent-card discovery plus
    `message/send`, message-only by design. Not yet exercised against a live
    agent — treat it as a starting point.
  - **Analysis history** under `analyses/<timestamp>/` with prompt, response, and
    the issue revision it describes. **Staleness is derived from that revision,
    never stored**, so it survives manual edits, `git revert`, and syncs that
    happen while Neovim is closed. Shown in the issue header.
  - An outdated analysis is never fed back in as context, since that would
    propagate its staleness.
  - `:IssueHub analyze` / `:IssueHub analyses`; `backend` / `backends` config.

### Fixed

- Opening an issue showed neither the "changed since you last looked" nor the
  analysis-staleness header line: `M.open` — the primary path — was the one call
  site not passing render options. Only the refresh path showed them, which is
  why earlier testing missed it.
- With `backend = "none"`, requests failed with "backend 'none' does not handle
  'analyze' (it handles: )" instead of the actionable "no backend configured"
  message. A backend advertising no kinds is now allowed to explain itself.

- **Collections, export, and the ripgrep search path (0.4).**
  - **Collections** are local, static, cross-provider lists stored as YAML under
    `.issuehub/collections/` and committed with the workspace. Static lists
    rather than saved queries: a list diffs cleanly and "why is this in here"
    always has a literal answer. Members that fall out of the cache are still
    listed — a collection is the user's list, not the cache's.
  - **Export** takes a View, never a picker, which is what makes
    `:IssueHub export csv` work identically on a collection, a multi-select, or
    the last thing the picker showed. Formats: csv, markdown, json, yaml, plus
    `export.register()` for third parties. Rows combine the cached issue with the
    overlay, flatten metadata to `meta.<key>`, and carry `fetched_at` so
    staleness travels with the data. No network I/O.
  - **Current View**: with no source, export acts on what you were just looking
    at. The picker records the view it showed, so this needs no picker-specific
    code anywhere in export.
  - **`:IssueHub find --regex`** forces the ripgrep path, which reaches text the
    index does not hold and annotates each result with *which* field matched.
  - `export.dir` / `export.default_format` config, now that the feature exists.

### Fixed

- Local search silently excluded every cached issue body: `.state/` is both a
  dot-directory and git-ignored, so ripgrep skipped it by default. Now passes
  `--hidden --no-ignore-vcs` while still excluding `.git/`.

- **Sync and change detection (0.3).** `:IssueHub sync [target]` re-fetches
  everything local — or one provider instance, or one issue — and reports what
  moved per issue (`status Open → In Progress, assignee, +2 comments`).
  `:IssueHub changed` opens a picker over issues whose remote revision moved
  since you last opened them, and the issue header carries a `Changed:` line.
  - **Sync never mutates the Workspace.** It refreshes the cache and the
    `state.yaml` housekeeping, nothing else: a remote edit must not rewrite your
    notes.
  - Change detection compares the watched fields directly rather than hashing.
    An earlier design used `updated_at` plus a content-hash fallback; direct
    comparison is cheaper to reason about and strictly more informative, since
    the report has to say *what* moved anyway.
  - Comment counts come from the provider's reported total, because the fetched
    list is capped and its length would understate the change.
  - "Changed since I last looked" is derived from `state.yaml`, so it survives
    restarts and accumulates across syncs, and clears when you open the issue
    rather than when a sync runs. The marker is mirrored into the index, so
    listing changed issues is a filter rather than a walk of the Repository.
  - Sync targets everything cached plus anything with local notes, so an
    annotated issue that fell out of the cache is still tracked.
  - Repainting after a sync preserves unsaved buffer edits.

- **Workspace overlay (0.2).** The issue buffer now has three editable regions —
  Memo, Metadata, and Prompt — written back to `memo.md`, `metadata.yaml`, and
  `prompt.md` on `:w`. Only files whose content changed are written, so `:w` on
  an unmodified buffer produces no Git churn, and emptying a section deletes its
  file rather than leaving a stub.
  - **metadata.yaml round-trips verbatim.** Writeback is the buffer text, so
    comments, key order, and spacing survive. The YAML parser is used only for
    reading (search, filtering, export), which sidesteps round-trip fidelity
    entirely rather than trying to preserve it through a parse/serialize cycle.
  - Read-only enforcement is advisory, as designed: Neovim cannot lock part of a
    buffer, so an edit above `## Memo` is reverted with a warning while
    everything typed in the editable regions is kept. Destroying a section
    heading reverts the whole buffer, because without it the text can no longer
    be mapped back onto files.
  - A background refresh preserves unsaved edits rather than overwriting them.
- **Bookmarks**, stored in `state.yaml` beside your notes so they are committed
  rather than derived. `:IssueHub bookmark` toggles, `:IssueHub bookmarks` opens
  a picker. A rebuilt index recovers them from `state.yaml`.
- `state.yaml` also records `last_seen_updated_at`, which is what makes
  "changed since I last looked" possible in 0.3 without diffing payloads.
- `util/yaml.lua`: a deliberately minimal YAML subset — scalars, lists, one level
  of nesting — for reading hand-written metadata.

- **Redmine provider.** `closed` comes from `/issue_statuses.json`, fetched once
  per session and cached, because Redmine's issue payload only carries
  `status.is_closed` on newer versions and status names are per-instance
  configurable. Journal entries with no note are field-change records, not
  comments, and are skipped.
- **GitHub provider** for github.com and Enterprise Server. Pull requests are
  included — GitHub numbers issues and PRs in one sequence per repository, so
  `owner/repo#123` stays unambiguous — and status distinguishes `Open`, `Draft`,
  `Merged`, and `Closed`. Newest comments are fetched by requesting the last
  page rather than the first.
- **GitLab provider** for gitlab.com and self-managed. Uses the per-project `iid`
  (what the UI shows), not the global issue id. System notes are GitLab's audit
  trail and are dropped.
- **Repository-qualified IDs** for GitHub and GitLab (`owner/repo#123`), so one
  workspace can span many repositories. These are the first IDs to actually
  exercise the RFC 3986 path encoding.
- `provider/util.lua`, shared request and auth plumbing, extracted once there
  were four providers repeating it.
- **Multiple instances of the same provider type.** The config key is now an
  instance name and `providers.<name>.type` selects the implementation
  (defaulting to the key), so a Jira Cloud and a self-hosted Jira — or two
  GitLabs — can be registered side by side. The instance name is the URI scheme,
  credential key, network-settings key, and workspace directory, so the same
  issue key on two servers never collides.
- **Corporate network support** via a new `http` config block: proxy (with
  NTLM/negotiate/digest auth), `no_proxy`, custom CA bundle, mutual TLS, and
  `ssl_verify`. Every field is optional; with none set, curl still honours
  `http_proxy` / `https_proxy` / `no_proxy` from the environment. Settings can be
  overridden per provider, for the common case of an internal tracker reached
  directly while SaaS goes through the proxy.
  - Proxy passwords and client-key passphrases are handled exactly like API
    tokens — resolved from env or a command, passed on stdin, never in argv.
  - `ssl_verify = false` is accepted but warns at setup and is reported as an
    **error** by `:checkhealth`; `cacert` is the supported answer to TLS
    interception.
  - `:checkhealth issuehub` gained a Network section showing the effective
    settings with credentials stripped.

### Changed

- `providers.<name>.url` is now required only for Jira and Redmine. GitHub and
  GitLab default to their SaaS hosts.

### Fixed

- A literal string credential (`proxy_password = "..."`) was silently discarded,
  because the resolver only accepted a function, `_cmd`, or `_env`. curl then
  fell back to prompting for the password interactively, which hangs a headless
  Neovim. Literal strings are now accepted, and a proxy user without a resolved
  password emits an empty password rather than triggering the prompt.

Planned next: the Workspace overlay — memo, metadata, and prompt as editable
buffer regions with `:w` writeback (0.2). See §22 of [DESIGN.md](DESIGN.md).

## [0.1.0] — 2026-07-19

Initial release. Read-only issue browsing with the local Repository skeleton in
place for the Workspace features that follow.

### Added

- **Providers** — Jira, covering both Cloud and Server/DC. Flavor selects auth
  style and REST version; detection is a hostname heuristic and
  `providers.jira.flavor` overrides it. Includes an ADF → Markdown converter for
  the node types that actually appear, with unsupported nodes rendered visibly
  rather than dropped.
- **Canonical Issue model** with a minimal `Status = { id, name, closed }`. The
  core interprets only `closed`; workflow semantics stay provider-specific.
- **Repository** — Git-managed workspace with derived state isolated under
  `.state/` and git-ignored automatically. Paths use RFC 3986 percent-encoding,
  so `PROJ-123` stays readable and only the rare `PROJ/123` is escaped.
- **Index** behind a single interface, with two backends: JSON (default, zero
  dependencies) and SQLite through the `sqlite3` CLI, using FTS5 when the local
  build has it. Switching backends or deleting `.state/` is always safe — the
  index holds no truth of its own.
- **View**, the picker-agnostic list model that export, analysis, and collections
  will consume, so adding a picker backend adds no downstream code paths.
- **Picker abstraction** over snacks.picker, fzf-lua, telescope, and
  `vim.ui.select`, auto-detected in that order, with three declared capabilities
  (`preview`, `multi_select`, `actions`).
- **Read-only virtual buffer** rendering line-based Markdown, so Treesitter,
  folding, search, marks, and any markdown renderer work unmodified.
- **HttpClient** on `vim.system()` + curl, with retry and `Retry-After` handling,
  a concurrency cap, and credentials delivered on stdin.
- `:IssueHub` with subcommands `open`, `search`, `find`, `local`, `refresh`,
  `reindex`, `provider`, and `health`; `<Plug>(IssueHubOpen)`,
  `<Plug>(IssueHubFind)`, `<Plug>(IssueHubRefresh)`.
- `:checkhealth issuehub`, reporting tool availability, workspace state, index
  backend, picker backends, and whether credentials resolve — never their values.

### Notes

- Neovim 0.11 is the supported floor. `vim.net.request()` is not used: it is
  GET-only with no header support in 0.12 and cannot make authenticated calls.
- No hard dependencies. Every integration is a runtime `pcall`.
- Config keys belonging to unimplemented milestones (`backend`, `backends`,
  `export`) are rejected by validation rather than silently accepted.

[Unreleased]: https://github.com/tya5/issuehub.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tya5/issuehub.nvim/releases/tag/v0.1.0
