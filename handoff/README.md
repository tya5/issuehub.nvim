# Extracting the core to `tya5/issuehub` — handoff

This directory hands off a planned refactor to **a different session**: pull the
non-UI core of `issuehub.nvim` out into a standalone **Python CLI** at
`tya5/issuehub`, so the same logic is reusable outside Neovim. `issuehub.nvim`
then becomes a thin client that shells out to it.

These documents were written from the working Lua implementation, so they
describe *what actually exists*, not an aspiration. Read them in this order.

| Doc | What it is |
| --- | --- |
| [CONTRACT.md](CONTRACT.md) | The CLI interface: verbs, arguments, stdin, the exact JSON in and out, exit codes, streaming. This is the durable, language-independent asset. |
| [ONDISK.md](ONDISK.md) | The workspace / `.state/` on-disk formats. The Python CLI and the Lua plugin **read and write the same files**, so these are byte-level compatibility requirements, not suggestions. |
| [PROVIDERS.md](PROVIDERS.md) | Per-provider specifics: endpoints, auth, pagination, project extraction, `closed_at`, and the quirks each tracker forced. |
| [CORRECTNESS.md](CORRECTNESS.md) | The ledger of hard-won decisions and bugs already fixed. A rewrite's real risk is silently re-introducing these. Port this list into the new test suite. |
| [PLAN.md](PLAN.md) | How to proceed: repo layout, the golden-fixtures method, phased migration, testing, and the division of labour with the nvim side. |

## The one-paragraph summary

The Lua core (`lua/issuehub/core/*`, `lua/issuehub/provider/*`, `util/http`,
`util/fs`, `util/yaml`) is already UI-free and clean — but it is **wedded to the
Neovim runtime** (`vim.system`, `vim.uv`, `vim.json`, `vim.fs`, `vim.fn.sha256`,
`vim.schedule`). It cannot run as `lua issuehub.lua` without shipping Neovim.
That is *why* a reimplementation, rather than a wrapper, is justified for a
genuine standalone CLI. The reusable seam is the **JSON contract**, not the
language: get [CONTRACT.md](CONTRACT.md) right and the implementation behind it
can be Python now and something else later.

## Scope: what moves, what stays

**Moves to `tya5/issuehub` (Python CLI):**

- Providers — HTTP, auth, the four trackers (Jira, Redmine, GitHub, GitLab),
  pagination.
- Cache, index (SQLite + JSON fallback), list cache.
- Workspace: overlay (memo/metadata), `state.yaml`, collections.
- Sync and change detection.
- Export and summarisation (this is where `pandas` earns its place).
- Local search (ripgrep / FTS5).

**Stays in `issuehub.nvim` (Lua):**

- All UI: picker adapters, the virtual issue buffer, rendering, the conversation
  window, `:checkhealth`, keymaps, commands.
- **Prompt / analyze / AI backend / analysis history** — the user explicitly
  scoped these OUT of the CLI. They stay Lua-side for now. (The on-disk
  `analyses/` layout is still documented in ONDISK.md because the CLI must not
  trample it.)

## Non-negotiables

1. **The workspace is the interface between the two halves.** Plain files, Git-
   managed. The CLI writes them, nvim reads them (and vice versa). Neither owns
   the format; ONDISK.md does.
2. **No hard runtime dependency beyond the one CLI binary.** The user accepted
   "one tool on PATH" (like curl/sqlite3), and explicitly rejected a daemon. The
   CLI is invoked per command and exits; it holds no long-lived process.
3. **Credentials never reach argv, logs, or disk.** This is a security invariant
   the Lua side upholds and the CLI must too. See CORRECTNESS.md §Credentials.
