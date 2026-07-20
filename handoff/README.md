# Extracting the core to `tya5/issuehub` — handoff

This directory specified pulling the non-UI core of `issuehub.nvim` out into a
standalone **Python CLI** at `tya5/issuehub`, so the same logic is reusable
outside Neovim. That CLI now exists.

> **STATUS: the CLI shipped; the plugin is NOT being cut over to it.**
>
> The original plan ended with `issuehub.nvim` becoming a thin client that shells
> out to the CLI. **That final step is dropped** — see DESIGN.md §24 for the
> measurement and the reasoning. The short version: the reuse goal is met by the
> CLI existing, a subprocess costs ~130 ms per call (fatal on the picker's
> per-keystroke preview), and the cutover would trade a tested implementation for
> shims plus three new failure modes, breaking the zero-dependency principle.
>
> **The two implementations now stand side by side**, kept consistent by the
> workspace format in [ONDISK.md](ONDISK.md) and a shared conformance corpus
> ([PLAN.md](PLAN.md) §Keeping the two implementations honest). The plugin calls
> the CLI only for what should not be built in Lua — analysis/aggregation.
>
> Everything else in these documents stands: they describe the shared semantics
> both implementations must honour, which is now their *permanent* job rather
> than a porting aid.

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

## Scope: what the CLI covers, what stays Lua-only

(Written as "moves" originally; with the cutover dropped, read it as *what each
implementation is responsible for*. Both implement the first list; only the
plugin implements the second.)

**Implemented in both (the shared core the conformance corpus covers):**

- Providers — HTTP, auth, the four trackers (Jira, Redmine, GitHub, GitLab),
  pagination.
- Cache, index (SQLite + JSON fallback), list cache, attachment fetch
  (metadata in the cache, bytes on request only — ONDISK §Attachments).
- Workspace: overlay (memo/metadata), `state.yaml`, collections.
- Sync and change detection.
- Export **and import** (ONDISK §Export columns, CORRECTNESS §Import), and
  summarisation (this is where `pandas` earns its place).
- Local search (ripgrep / FTS5), including translated prose.

**Plugin-only (no CLI equivalent, and none wanted):**

- All UI: picker adapters, the virtual issue buffer, rendering, the conversation
  window, `:checkhealth`, keymaps, commands.
- **Prompt / analyze / AI backend / analysis history** — the user explicitly
  scoped these OUT of the CLI. They stay Lua-side for now. (The on-disk
  `analyses/` layout is still documented in ONDISK.md because the CLI must not
  trample it.)
- **Producing translations.** Generation goes through the AI backend, so it
  follows the same rule. The *format* is shared, though: the CLI reads
  `translations/<lang>.md`, indexes it for search, and must leave its
  frontmatter alone (ONDISK §Translations).

## Non-negotiables

1. **The workspace is the interface between the two implementations.** Plain
   files, Git-managed. Either may write them; both must read what the other
   wrote. Neither owns the format; ONDISK.md does. This matters more now than
   under the cutover plan: the two run independently against the same directory.
2. **The plugin has NO hard runtime dependency, including on the CLI.** It must
   work with nothing installed (§1.3). The CLI is invoked per command and exits;
   it holds no long-lived process. A missing CLI degrades one analysis command,
   never the plugin.
3. **Credentials never reach argv, logs, or disk.** This is a security invariant
   the Lua side upholds and the CLI must too. See CORRECTNESS.md §Credentials.
