# How to proceed

**Phases 0-2 are done: the CLI exists.** Phase 3 (cutting the plugin over to it)
is dropped — see DESIGN.md §24. What remains live in this document is
§"Keeping the two implementations honest" and §"Live verification is the
remaining gap"; the rest is kept as the record of how the port was done.

The method that de-risked it: **contract first, golden fixtures from the working
Lua, phased port, conformance-tested each step.** No big-bang rewrite; each phase
shippable and checked against the existing behaviour.

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

**Phase 3 — ~~cut nvim over~~ → keep both, keep them honest.**
**Superseded.** The cutover is dropped; see DESIGN.md §24 for the measurement and
the reasoning. What replaces it is below.

## Keeping the two implementations honest

Two implementations of the same core means some bugs must be fixed twice. That is
the accepted cost, and it is not hypothetical: a GitHub status-precedence bug (a
draft PR closed without merging reading as open, while still carrying
`closed_at`) existed in **both**, and the port's finer partial-baseline
comparison had to be brought back to the Lua side.

Containment is mechanical, not disciplinary:

1. **A shared conformance corpus.** The golden fixtures described above stop
   being porting scaffolding and become a permanent, shared asset: recorded
   provider payloads plus the canonical Issue each must normalise to. Both CI
   suites run it. Divergence then fails a build instead of reaching a user — the
   draft-PR case would have failed in both the moment it was added.
   - Keep it in one place, vendored into the other repo (a small file set, so
     copying beats a submodule) and refreshed when either side adds a case.
   - Every bug found live becomes a corpus entry **before** it is fixed, in
     whichever implementation found it. The memo/heading truncation
     (CORRECTNESS §Overlay section boundaries) is the newest such entry: found
     by a user typing `## Metadata` into a note, and cheap to assert in both. That is what makes the second
     implementation cheap to correct rather than a place bugs hide.
2. **ONDISK.md is the on-disk contract.** Both write the same workspace, so a
   format change in either is a breaking change for the other. Change it in the
   doc first.
3. **The correctness ledger** (CORRECTNESS.md) stays the shared statement of
   *why*, and gains an entry whenever live verification finds something.

## What the plugin does call the CLI for

Exactly one thing, and it is additive rather than a replacement: **analysis /
aggregation** (`issuehub summarize`). Neovim is a poor place to build
aggregation, Python is a good one, and the latency is irrelevant for a command
that produces a report. If the CLI is absent, that one command degrades with a
clear message and nothing else in the plugin is affected.

Do **not** route the interactive path through the CLI — picker preview runs on
every cursor move, and a subprocess there costs ~130 ms per keystroke.

## Live verification is the remaining gap

Both implementations are verified against GitHub only. Jira, Redmine, and GitLab
are unverified live in **both**, and GitHub alone produced four real bugs that
recorded fixtures and hundreds of tests had all passed through. The known
suspect, already flagged: Jira's `resolutiondate` and Redmine's `closed_on` are
not reliably cleared on reopen, which is the same shape as the GitHub
`closed_at` contradiction. The Lua side now enforces "no `closed_at` unless
closed" centrally in `issue.normalize` and tests it parameterised across all four
providers (`spec/invariants_spec.lua`); mirror that placement rather than
patching per provider.

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

## Next concrete step

The port is complete; the open work is keeping the two honest and closing the
verification gap:

1. **Promote the golden fixtures to a shared conformance corpus** run by both CI
   suites, starting with the four bugs live verification already found (the
   draft-PR precedence case, the partial-baseline sync case, and the two
   CLI-surface ones that have no Lua equivalent).
2. **Catch the CLI up to the three additions the plugin has made since this
   handoff was written**, in this order — each is pure data work with no UI
   entanglement, which is why they belong here at all:
   - **Import** (CONTRACT §`issuehub import`, CORRECTNESS §Import). The
     export→import round trip is the corpus entry; the asymmetry (issue columns
     discarded, absent column ≠ empty cell) is where a port goes wrong.
   - **Translation storage** — read, index, and language-tag *validation*
     (ONDISK §Translations). Not generation.
   - **Overlay opacity** (CORRECTNESS §Overlay section boundaries): confirm the
     Python side never parses markers out of memo text.
3. **Verify Jira, Redmine, and GitLab against real instances.** GitHub alone
   produced four bugs that every recorded fixture had passed through; there is no
   reason to expect the other three to be cleaner.
4. **Wire `:IssueHub summarize`** in the plugin — the one place it calls the CLI,
   degrading with a clear message when the binary is absent.
