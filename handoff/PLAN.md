# How to proceed

The method that de-risks this: **contract first, golden fixtures from the working
Lua, phased port, conformance-tested each step.** Do not big-bang a 7000-line
rewrite; each phase must be shippable and checked against the existing behaviour.

## Repo layout for `tya5/issuehub`

```
tya5/issuehub/
├── pyproject.toml            # entry point: issuehub = "issuehub.cli:main"
├── issuehub/
│   ├── cli.py                # arg parsing → verbs; the CONTRACT.md surface
│   ├── config.py             # config load + credential resolution
│   ├── model.py              # Issue, ViewItem, Status, Change (dataclasses)
│   ├── repository.py         # paths, URI encode/parse, case-collision, init
│   ├── cache.py              # cache read/write, partial merge
│   ├── index/                # base, json.py, sqlite.py
│   ├── listcache.py
│   ├── overlay.py            # memo/metadata, verbatim writeback, yaml subset
│   ├── workspace.py          # state.yaml, changed-since-seen
│   ├── collection.py
│   ├── sync.py               # diff, targets
│   ├── fetch.py              # paged walk, JSONL progress
│   ├── search.py             # fts + ripgrep routing, --meta
│   ├── export.py             # columns, formats, merged source, summarize
│   ├── http.py               # one HTTP client; proxy/TLS/retry/auth-on-not-argv
│   └── providers/
│       ├── base.py           # page(), limits, paginate, shared request
│       ├── jira.py  adf.py
│       ├── redmine.py  github.py  gitlab.py
├── tests/
│   ├── fixtures/             # golden JSON captured from the Lua CLI (below)
│   ├── recorded/             # provider HTTP fixtures (see Testing)
│   └── test_*.py
└── handoff/                  # copy these six docs in as the spec of record
```

Suggested deps: `httpx` (proxy/TLS/mTLS support), stdlib `sqlite3`, `PyYAML`
*only for reading* metadata (write it verbatim), `pandas` for `summarize`/export
aggregates. Keep the dependency set small — the binary should install cleanly.

## Golden fixtures (the safety net)

The Lua implementation is the correctness oracle. Before porting a module,
capture its outputs and assert the Python matches them.

1. There is a headless Lua runner already: `spec/runner.lua` and the pattern
   `nvim -l <script>` used throughout `handoff` verification. Write a small Lua
   script that, given a seeded temp workspace, prints canonical JSON for: an
   Issue after `normalize`, a `to_item`, a cache round-trip, an index `list`
   result, an export row set, a `sync.diff` result, and the URI encode/parse
   pairs. Save each as `tests/fixtures/*.json`.
2. Reuse the **provider fixtures** already in `spec/*_spec.lua` — those are
   recorded API payloads (`CLOUD_ISSUE`, Redmine statuses, GitHub pagination,
   GitLab notes). Copy the payloads into `tests/recorded/` and assert the Python
   provider maps them to the same canonical Issue.
3. Cross-check the on-disk format directly: have both implementations write the
   same issue, and `diff` the resulting `.state/cache/...json` and `issues.db`
   dump. They must be byte/-row-identical (modulo `fetched_at`).

This turns "did I re-derive the behaviour" from a guess into a failing test.

## Phases

Each phase ends green and is independently useful. Do not start the next until
the current one passes its fixtures.

**Phase 0 — contract + skeleton (small, prove the loop).**
Freeze [CONTRACT.md](CONTRACT.md). Implement `version`, `health`, and the arg/
JSON plumbing. Implement `repository.py` + `model.py` + URI encoding, tested
against the encode/parse golden pairs. No network yet. Deliverable: `issuehub
health --json` runs and matches the health shape.

**Phase 1 — read path.**
`cache.py`, `index/` (both backends), `listcache.py`, `overlay.py`,
`workspace.py`. `issuehub list` (serving from cache), `search`, `changed`,
`export`, `summarize`, `collection`, `reindex`. All offline — tested entirely
against golden fixtures and a hand-seeded workspace. This is most of the value
and none of the network risk. Ship it: nvim can already use these for the local
surfaces (`find`, `local`, `export`, `bookmarks`, `changed`).

**Phase 2 — providers + network.**
`http.py` (proxy/TLS/mTLS/retry, auth-not-in-argv), `providers/base.py`, then one
provider at a time (Jira first — it is the hardest; ADF, flavor, cursor paging).
`issuehub list`/`get`/`sync`/`fetch` go live. Test each provider against its
recorded payloads before any live call. Then verify against a real instance
(GitHub via `gh auth token` is the cheapest — that is how the Lua side was
verified).

**Phase 3 — cut nvim over.**
See "Division of labour" below. Do this provider-surface by provider-surface, not
all at once, so a regression is bisectable.

## Division of labour with `issuehub.nvim`

The plugin keeps all UI and the AI/prompt/analysis features. Replace only the
core calls. Concretely, in the Lua side:

- `core/cache`, `core/index/*`, `core/listcache`, `core/sync`, `core/fetch`,
  `core/search`, `core/export`, `core/collection`, and `provider/*` become **thin
  shims that shell out** to `issuehub <verb> --json` (via `vim.system`) and parse
  the JSON. Keep the module names and function signatures so the UI layer does
  not change.
- `core/overlay`, `core/workspace` (state.yaml), `core/repository` can **stay
  Lua** and keep reading files directly — that keeps buffer rendering instant and
  avoids a subprocess on every keystroke. The CLI and the plugin both touch these
  files; ONDISK.md is the shared contract that lets them.
- `core/analysis`, `backend/*`, `ui/*` are **unchanged** — the CLI has no prompt
  surface by the user's decision.
- Add a `checkhealth` line for the `issuehub` binary (present? version? contract
  compatible?), the way `curl`/`sqlite3` are checked now.

Guard the seam: the plugin should degrade to a clear "install the `issuehub` CLI"
message when the binary is absent, exactly as it does for a missing picker —
never a stack trace.

## What to read in the Lua source

Ground every port in the original, not in these docs alone (docs can drift; code
cannot):

| Python module | Lua source of truth |
| --- | --- |
| model, repository | `core/issue.lua`, `core/repository.lua` |
| cache | `core/cache.lua` |
| index | `core/index/{init,json,sqlite}.lua` |
| listcache, fetch | `core/listcache.lua`, `core/fetch.lua` |
| overlay, workspace | `core/overlay.lua`, `core/workspace.lua` |
| sync | `core/sync.lua` |
| search | `core/search.lua`, routing in `init.lua:search_engine` |
| export | `core/export.lua` |
| collection | `core/collection.lua` |
| http | `util/http.lua`, network in `config.lua:net` |
| config | `config.lua` |
| providers | `provider/{util,jira,adf,redmine,github,gitlab}.lua` |

The Lua test suite (`spec/*_spec.lua`, 318 cases) is the behaviour spec. Read the
relevant `_spec` alongside each module — the tests name the edge cases in
English, which is faster than re-deriving them.

## First concrete step

Copy these six docs into `tya5/issuehub/handoff/`, freeze CONTRACT.md, and do
Phase 0. When `issuehub health --json` runs and the encode/parse fixtures pass,
you have proven the loop and the rest is mechanical, one module at a time.
