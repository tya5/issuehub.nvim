# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is pre-1.0: the public API may break between minor versions until
1.0, and each such break is listed here.

## [Unreleased]

### Added

- **Translations.** `:IssueHub translate <lang>` sends an issue through the
  configured backend and stores the result as `translations/<lang>.md` beside
  the notes — one file per language, tracked in Git, hand-editable when the
  machine gets it wrong. Staleness is derived from the issue revision it was made
  from, exactly like an analysis, so a `git revert` puts it right; the issue
  header shows `ja (current)` / `ja (outdated)`. Translated prose joins the
  full-text index and the ripgrep path, which reports `translation:ja` as the
  matched field. User-triggered only, and inert without a backend.
  - Language tags are validated before becoming filenames — the tag is
    user-supplied and lands in a path, so `../` and friends are rejected rather
    than sanitised.
  - The backend contract's `kind` dispatch, built in 0.1.0 for exactly this,
    absorbed the new request type without changing the interface.

### Added

- **Project scoping.** A server holds many projects, and scoping only to the
  server left lists as mixed as they were before. `project` is now part of the
  canonical Issue — the Jira project key, the Redmine identifier, the GitHub or
  GitLab repository — carried through the index, the picker tokens
  (`project:ops`), `--meta project=`, and export sources (`jira/PROJ`).
  `providers.<name>.projects` lists the choices and `default_project` skips the
  prompt; without either, the choices come from what has actually been seen
  locally, so a fresh workspace costs nothing and sharpens as you use it. You
  are asked only where there is a choice, and `(all projects)` stays offered.

- **Collections carry a prompt and an analysis history**, like issues do. Paths
  now resolve a *subject* — an issue URI or `collection:<slug>` — so overlay,
  analysis, and state work on both. A collection is stored as a directory
  (`collection.yaml` plus `prompt.md` and `analyses/`) rather than a bare file;
  the pre-v2 file is still read, and migrated away on the next write. Repository
  layout is v2.

- **Export merges the cache with the workspace.** `all`, and a provider instance
  name, now export the union of both rather than whatever the index happens to
  hold. The two sets differ — an issue annotated months ago may have fallen out
  of the cache, a fetched issue may have no notes — and exporting either alone
  dropped rows silently. Rows with no payload keep their notes and leave the
  issue columns blank.
- **Columns for analysis.** `created_at` and `closed_at` (new on the canonical
  Issue, populated by all four providers from `resolutiondate`, `closed_at`,
  `merged_at`, and `closed_on`), plus `provider`, `reporter`, `comments`, and
  precomputed `age_days` / `days_to_close`. A defect curve needs the dates an
  issue arrived and left; the export previously carried neither. The arithmetic
  is precomputed because doing it in a spreadsheet is where these analyses
  usually go wrong — an open issue ages to now and leaves `days_to_close` empty.

### Changed

- **`open`, `find`/browse, `local`, and `fetch` are all per server.** Browsing
  local issues previously merged every provider into one list while `open` asked
  which server to query — an asymmetry, and the merged list was the worse half:
  ids from different trackers are ambiguous to scan and a filter term means
  different things on each. All four now route through one `with_provider`
  helper, so they ask identically and cannot drift apart. With a single provider
  configured, nothing prompts.

## [0.1.0] — 2026-07-19

First release. Nothing was published before this, so it covers the whole of
development milestones 0.1 through 0.7 (§22 of [DESIGN.md](DESIGN.md)) plus
everything that came out of using it against a real tracker.

### Providers

- **Jira** (Cloud and Server/DC), **Redmine**, **GitHub** (github.com and
  Enterprise Server), **GitLab** (gitlab.com and self-managed).
- **Multiple instances of any type.** The config key is an instance name and
  `type` selects the implementation, so a Jira Cloud and a self-hosted Jira
  coexist. The instance name is the URI scheme, credential key, network-settings
  key, and workspace directory — so the same issue key on two servers never
  collides.
- **`closed` is always taken from what the API states** — Jira's
  `statusCategory`, Redmine's `/issue_statuses.json`, `state` on GitHub and
  GitLab — never guessed from a status label, since those are per-installation
  configurable. Nothing finer is interpreted: "in review" means different things
  at different organisations.
- GitHub pull requests are included; GitHub numbers them in one sequence per
  repository, so `owner/repo#123` stays unambiguous.
- **Pagination** via `max_results` and `per_page`, defaulting to one page so a
  large backlog is never pulled down by accident. Partial results survive a
  failed page, and GitHub search stops before its 1000-result ceiling.
- ADF → Markdown for Jira Cloud, covering the node types that actually appear.

### The workspace

- **An issue buffer** that is the cached issue (read-only) above your own notes
  (editable), as one Markdown document — so Treesitter, folding, search, marks,
  and any Markdown renderer work unmodified. Sections are labelled and divided,
  so the boundary is visible rather than discovered.
- **`:w` writes memo and metadata**, and only the files whose content changed,
  so an unmodified buffer produces no Git noise. Emptying a section deletes its
  file. `metadata.yaml` round-trips verbatim — comments, key order, and spacing
  survive, because writeback is the buffer text and parsing is read-only.
- **Read-only is advisory**, as it must be: Neovim cannot lock part of a buffer,
  so an edit above the divider is reverted with a warning while everything typed
  below is kept.
- **Bookmarks and last-seen revisions** in `state.yaml`, committed alongside the
  notes rather than derived, so a rebuilt index recovers them.
- The Repository holds only what belongs in Git; everything derived lives under
  `.state/` and is git-ignored automatically. Issue IDs are RFC 3986
  percent-encoded, so `PROJ-123` stays readable and only `PROJ/123` is escaped.

### Sync

- **`:IssueHub sync`** reports what moved, per issue
  (`status Open → In Progress, +2 comments`), and **never mutates the
  workspace**. Change detection compares the watched fields directly rather than
  hashing, since the report has to say *what* moved anyway.
- **`:IssueHub changed`** and a header line answer the different question of
  what moved since *you* last looked — derived from `state.yaml`, so it survives
  restarts and clears when you open the issue rather than when a sync runs.
- **`:IssueHub fetch`** pages a whole server into the cache in the background,
  per server, with `status`, `stop`, and `resume`. The issue *list* is cached in
  its own right under `.state/lists/` with its own freshness, and pages merge in
  as they arrive, so an interrupted walk keeps what it collected.

### Search, collections, export

- **Two pickers, one shape.** `open` and `find` both open immediately and filter
  as you type; only the corpus differs. Memo and metadata ride along as hidden
  match text and built-in fields are folded in as tokens, so `status:open` and
  `priority:high` filter alike.
- **`:IssueHub find`** with `--meta key=value` for exact filtering (built-in
  fields included), `--regex`, and full-text search across memo, metadata, and
  analysis history. FTS5 when sqlite3 has it, ripgrep otherwise — and always
  ripgrep for non-ASCII, because `unicode61` makes a run of Japanese one token.
- **Collections**: local, static, cross-provider lists, committed with the
  workspace. Static rather than saved queries, so "why is this in here" always
  has a literal answer.
- **Export** to csv, markdown, json, or yaml. Takes a View, never a picker, so
  the same call works on a collection, a multi-select, or the last thing the
  picker showed. Metadata flattens to `meta.<key>` and `fetched_at` travels with
  the data.

### AI (opt-in)

- **A Backend interface** whose requests carry a `kind`, so LLM completion slots
  in without the interface moving. The default is `none`: nothing is sent
  anywhere. An A2A backend is included, written against the documented JSON-RPC
  shape but not yet exercised against a live agent.
- **A conversation window** (`:IssueHub prompt`) holding every past prompt and
  response for an issue, oldest first, with the next prompt at the bottom.
- **Analysis history** with staleness *derived* from the issue revision each
  answer was made against, never stored — so it survives a manual edit, a
  `git revert`, or a sync that happened while Neovim was closed.

### Infrastructure

- **No hard dependencies.** Pickers, git, diff, Markdown rendering, and AI are
  delegated to whatever you already have; every integration is a runtime
  `pcall`. Works with zero plugins installed, just less comfortably.
- **HttpClient** on `vim.system()` + curl, because `vim.net.request()` is
  GET-only in Neovim 0.12 and cannot make an authenticated call. Retry with
  `Retry-After`, a concurrency cap, and every credential delivered on stdin —
  never argv, so `ps` cannot see it.
- **Corporate networks**: proxy with NTLM/negotiate/digest auth, `no_proxy`, a
  custom CA bundle, mutual TLS, and per-provider overrides. `ssl_verify = false`
  is accepted but warns and is reported as an error by `:checkhealth`, since
  `cacert` is the real answer to TLS interception.
- **Index** behind one interface with JSON and SQLite backends. The index holds
  no truth of its own, so deleting `.state/` is always safe.
- `:checkhealth issuehub` reporting tools, network, workspace, index, providers,
  backend, and picker — and whether credentials resolve, never their values.
- Sized for tens of thousands of issues: batched index writes, memoised
  directory scans, no `fsync` on derived data, and a confirmation prompt before
  a sync that would issue thousands of requests.
- 281 specs, run under busted + nlua against Neovim 0.11, stable, and nightly.

### Known limitations

- The A2A backend has not been tested against a live agent.
- The fzf-lua adapter declares no preview, because it does not implement one.
- Picker filtering is substring matching; `--meta` is the exact form.
- Neovim 0.11 is the floor; `vim.net` is unusable for authenticated calls until
  0.13.

[Unreleased]: https://github.com/tya5/issuehub.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tya5/issuehub.nvim/releases/tag/v0.1.0
