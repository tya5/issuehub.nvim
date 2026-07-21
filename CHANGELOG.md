# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is pre-1.0: the public API may break between minor versions until
1.0, and each such break is listed here.

## [Unreleased]

### Added

- **Username/password (HTTP Basic) authentication.** For self-hosted Jira and
  Redmine that issue no API tokens: set `user` plus `password_env`,
  `password_cmd`, or a `password` function, resolved in exactly the same order
  and cached the same way as a token. The transport already spoke Basic; this
  opens the config seam. The password reaches curl on stdin, never argv; a
  literal `password = "..."` is accepted but warns; `:checkhealth` reports the
  mode (`basic auth as <user>`) and that it resolved, never the value. Basic
  needs both `user` and a password, and when both a token and a password are
  configured the password wins. Token auth is unchanged and still preferred.

### Added

- **Cross-process locking.** The workspace is written by this plugin, by the
  `issuehub` CLI, and by a human in a text editor, concurrently and by design —
  without a protocol, each side's read-modify-write silently drops the others'.
  Every such window now takes an `O_CREAT|O_EXCL` lock file under `.state/lock/`
  (`vim.uv.fs_open(path, "wx")`; Lua's `io.open(path, "w")` truncates and is not
  a safe primitive). The wire format matches the CLI's byte for byte — it is a
  shared on-disk contract, not an implementation detail, and a lock only one
  side takes protects nothing.
  - The provider *cache directory* is locked for a cache write, not the issue:
    the case-collision guard compares two different ids that collide on one
    path, so a per-issue lock would serialise nothing.
  - **A lock is never broken automatically**, however old. Every liveness check
    is unreliable exactly where breaking would do most damage. A timeout names
    the holder, the operation, the age, and the file to delete.
  - Acquisition is re-entrant: `import` holds a subject lock and calls
    `overlay.write`, which takes the same one.
  - Plus the half a lock cannot cover: a text editor never takes one, so writes
    also refuse when the file moved since it was read. An issue buffer saves
    against what it rendered, so an hour-old buffer cannot overwrite an edit
    made in the meantime. Nothing is merged, nothing is overwritten.

### Added

- **Attachments.** `:IssueHub attachments` lists what an issue has and downloads
  the one you pick (`--all` for every one); the issue header gained a `Files:`
  line so you can see there is something to ask for. Jira and Redmine report
  them through their APIs; GitHub and GitLab have no attachment API, so those
  are read out of the body's Markdown links and their size and type are
  reported as unknown rather than guessed.
  - **Cache, never workspace.** They live under git-ignored `.state/`: a binary
    cannot be removed from Git history once committed, and a screenshot pasted
    into a ticket is often more sensitive than the ticket text.
  - **Nothing is fetched implicitly** — a sync records that a file exists and
    transfers nothing. `attachments.max_size` (default 50 MB) refuses the rest.
  - Bytes never pass through a Lua string: curl writes the file itself, to
    `<dest>.part` renamed on success, because the JSON path reads stdout as text
    and splits a status code off the end — either would corrupt a PNG.
  - Tracker-supplied filenames are reduced to one path segment before use, so
    an attachment named `../../../.ssh/authorized_keys` cannot escape; two
    attachments sharing a name get separate directories instead of overwriting.

### Added

- **Import.** `:IssueHub import <file>` merges an exported CSV or JSON back into
  the workspace, so a triage pass done in a spreadsheet can come home. Only the
  local half is merged — `memo`, `meta.*`, `bookmarked`; the issue columns are
  read and discarded, because the tracker owns them and a stale sheet must not
  rewrite the cache. Absent columns are left alone rather than cleared.
  - The file wins on conflict without prompting, which is defensible only
    because the workspace is a Git repo: the report names every issue whose
    content was replaced, `--dry-run` previews it, and the command warns when
    the workspace is *not* under Git and the undo therefore does not exist.
  - The export→import round trip is a no-op only when `metadata.yaml` is absent
    or already canonical (sorted keys, no comments). A hand-ordered file
    legitimately reports an overwrite — claiming "unchanged" for a write that
    reorders your keys would be the real bug.
  - `metadata.yaml` comments cannot survive an import (the file is regenerated
    from merged keys), so the report counts the issues where they were lost
    rather than letting it happen quietly.

### Added

- **Translations.** `:IssueHub translate <lang>` sends an issue through the
  configured backend and stores the result as `translations/<lang>.md` beside
  the notes — one file per language, tracked in Git, hand-editable when the
  machine gets it wrong. Staleness is derived from the issue revision it was made
  from, exactly like an analysis, so a `git revert` puts it right; the issue
  header shows `ja (current)` / `ja (outdated)`. Translated prose joins the
  full-text index and the ripgrep path, which reports `translation:ja` as the
  matched field (the FTS path reports `analyses` — translations and analyses
  share a column). User-triggered only, and inert without a backend.
  - Language tags are validated before becoming filenames — the tag is
    user-supplied and lands in a path, so `../` and friends are rejected rather
    than sanitised.
  - The backend contract's `kind` dispatch, built in 0.1.0 for exactly this,
    absorbed the new request type without changing the interface.
  - Documented what committing these files discloses (`:h
    issuehub-disclosure`): a translation is the issue's title and description,
    not a summary, so it puts tracker content in Git — and
    `include_comments = true` adds comment bodies and commenter names, both to
    Git and to every backend request. The default was `false` for request size;
    disclosure is the better reason.

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
