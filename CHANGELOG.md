# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is pre-1.0: the public API may break between minor versions until
1.0, and each such break is listed here.

## [Unreleased]

### Added

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

### Changed

- `providers.<name>.url` is now required only for Jira and Redmine. GitHub and
  GitLab default to their SaaS hosts.

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
