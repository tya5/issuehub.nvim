# On-disk formats — byte-level compatibility

The Python CLI and the Lua plugin share one workspace. Both read and write these
files, so these are **compatibility requirements**, not internal choices. A
divergence here silently corrupts a user's notes or cache. The Lua source of
truth is `lua/issuehub/core/repository.lua` (paths), `core/cache.lua`,
`core/issue.lua`, `core/index/*`, `core/listcache.lua`, `core/overlay.lua`,
`core/workspace.lua`, `core/analysis.lua`.

## Layout

```
<workspace>/                          # the "Repository root"; user-chosen, Git-managed
├── .issuehub/
│   ├── version                       # layout schema, currently "2\n"
│   └── collections/
│       └── <slug>/                   # v2: a directory (was <slug>.yaml pre-v2)
│           ├── collection.yaml
│           ├── memo.md               # collections carry overlay + analyses too
│           ├── prompt.md
│           └── analyses/
├── .state/                           # DERIVED, git-ignored (see .gitignore), safe to delete
│   ├── cache/
│   │   └── <provider>/<encoded-id>.json
│   ├── index/
│   │   └── issues.json  OR  issues.db
│   ├── lists/
│   │   └── <provider>-<hash>.json
│   └── lock/
├── .gitignore                        # written on init, contains "/.state/\n"
└── <provider>/                       # one dir per provider INSTANCE (URI scheme)
    └── <encoded-id>/
        ├── memo.md
        ├── metadata.yaml
        ├── prompt.md                 # (written by nvim's conversation window)
        ├── state.yaml
        └── analyses/
            └── <YYYY-MM-DDTHH-MM-SSZ>/
                ├── prompt.md
                ├── response.md
                └── metadata.yaml
```

On init, create `.issuehub/collections`, `.state/{cache,index,lists,lock}`,
write `.issuehub/version` (`"2\n"`) if absent, and write `.gitignore` (`/.state/`)
if absent. Do **not** overwrite an existing `.gitignore`.

## URI grammar and path encoding

`<provider>://<id>`, where `<provider>` matches `^[%w%-_]+$` (the instance name)
and `<id>` is the tracker's own id. The **path segment** is the id
percent-encoded per RFC 3986: every char not in `[A-Za-z0-9\-._~]` becomes
`%XX` (uppercase hex). This is used verbatim as the directory / filename.

- `jira://PROJ-123` → `jira/PROJ-123/` (unchanged, common case)
- `github://tya5/issuehub.nvim#7` — the URI is `github://tya5%2Fissuehub.nvim%237`,
  the dir is `github/tya5%2Fissuehub.nvim%237/`
- Decoding reverses it. `parse("jira://PROJ%2F123")` → `("jira", "PROJ/123")`.

**Case-collision guard:** on a case-insensitive FS (macOS) `PROJ-1` and `proj-1`
collide. Before writing a cache file, if a file exists whose encoded name differs
only by case, **error** rather than merge. (Lua: `repository.check_case_collision`.)

A **subject** is either an issue URI or `collection:<slug>`. `subject_dir` maps
the former to `<provider>/<encoded-id>/` and the latter to
`.issuehub/collections/<slug>/`. Overlay, state, and analyses all key on
subjects, so collections get the same three files an issue does.

## Issue (canonical model)

Every provider normalises to this. `core/issue.lua:normalize` fills every field
so consumers never nil-check. JSON on the wire and in the cache:

```json
{
  "uri": "jira://PROJ-123",
  "provider": "jira",
  "project": "PROJ",
  "id": "PROJ-123",
  "title": "...",
  "description": "...",         // markdown; "" for partial entries
  "status": { "id": "3", "name": "In Progress", "closed": false },
  "assignee": "Tetsuya",        // or null
  "reporter": "Alice",          // or null
  "labels": ["timeout", "cache"],
  "url": "https://.../browse/PROJ-123",
  "comments": [                 // [] for partial entries
    { "id": "1", "author": "Alice", "body": "...", "created_at": "…Z" }
  ],
  "created_at": "2026-07-01T00:00:00Z",
  "updated_at": "2026-07-19T01:15:00Z",
  "closed_at": "2026-07-11T10:00:00Z",   // null while open
  "raw": { }                    // untouched provider payload; may hold comment_total
}
```

- `status.closed` is the **only** semantic the core interprets. It is always
  taken from what the API states, never guessed from the label name (see
  PROVIDERS.md). `status.name` is the provider's own wording, shown verbatim.
- `raw.comment_total` (integer) is stashed by providers so change detection can
  count added comments without holding every comment (see PROVIDERS §Comments).
- `project` is provider-supplied; there is no cross-tracker way to infer it.

### ViewItem (flattened, for index/picker/search)

```json
{ "uri":"…", "id":"…", "project":"PROJ", "title":"…", "status":"In Progress",
  "closed": false, "assignee":"…", "updated_at":"…Z", "bookmarked": false,
  "seen_at": "…Z", "matched_in": "memo" }
```
`seen_at` mirrors `state.yaml`'s `last_seen_updated_at`; `matched_in` is set only
by search.

## Cache

`.state/cache/<provider>/<encoded-id>.json`:
```json
{ "fetched_at": "2026-07-19T00:00:00Z", "partial": false, "issue": <Issue> }
```
- **`partial: true`** means the entry came from `list`/`search` and lacks
  `description`/`comments`. A partial write must **never overwrite a complete
  entry** — instead keep the complete `description`/`comments` (CORRECTNESS
  §Partial cache). A partial entry is always treated as stale.
- Written **without fsync** (derived, rebuildable). Atomic via temp+rename.

## Index

Derived from the cache (+ workspace for FTS bodies). Holds no truth of its own —
`reindex` must rebuild it fully, recovering `bookmarked` and `seen_at` from
`state.yaml`. Two interchangeable backends; `auto` picks SQLite when `sqlite3`
resolves, else JSON.

**SQLite** (`issues.db`), exact schema:
```sql
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS issues (
  uri TEXT PRIMARY KEY, provider TEXT, project TEXT, id TEXT, title TEXT,
  status TEXT, closed INTEGER, assignee TEXT, updated_at TEXT,
  bookmarked INTEGER DEFAULT 0, seen_at TEXT );
CREATE INDEX IF NOT EXISTS idx_issues_open ON issues(closed, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_issues_project ON issues(provider, project);
-- only if the sqlite3 build has FTS5 (probe pragma_compile_options):
CREATE VIRTUAL TABLE IF NOT EXISTS issues_fts USING fts5(
  uri UNINDEXED, title, description, memo, metadata, analyses,
  tokenize = 'unicode61' );
```
The FTS table is populated with `title`, `description`, and the issue's **memo,
metadata, and concatenated analysis prose** — that is the point of FTS over the
JSON index. (Python can use `sqlite3` directly instead of shelling out, but the
schema and file must stay identical so nvim's SQLite backend reads it.)

**JSON** (`issues.json`): `{ "version": "2", "items": { "<uri>": <ViewItem>, ... } }`.

Default sort everywhere: **open before closed, then `updated_at` descending.**

## List cache

`.state/lists/<provider>-<hash>.json`, where `<hash>` is the first 16 hex chars
of `sha256(query_encoded)` and `query_encoded` is `"default"` when the query is
null, else the JSON encoding of the query.
```json
{ "provider":"jira", "query": null, "uris": ["jira://PROJ-1", ...],
  "fetched_at":"…Z", "started_at":"…Z", "cursor": <opaque>, "complete": false,
  "pages": 13 }
```
Merge semantics: append new URIs preserving order, drop duplicates. A fresh walk
resets `uris`; `--resume` appends and continues from `cursor`. Flush per page.

## Overlay files

- `memo.md`, `prompt.md` — raw text. **Trailing newlines normalised**: strip on
  read, re-add exactly one on write. Absent file == `""`. Emptying a section
  deletes the file (do not leave an empty stub).
- `metadata.yaml` — **written back verbatim** (the buffer/CLI text), never
  reserialised, so comments and key order survive. Parsing is read-only, for
  search/filter/export. The Lua parser is a deliberate YAML *subset*: scalars,
  lists of scalars, one level of nesting. Match that tolerance; do not require a
  full YAML round-trip.

## `state.yaml` (tracked in Git — user-meaningful, not derived)

```yaml
bookmarked: true
last_opened_at: 2026-07-19T10:15:00Z
last_seen_updated_at: 2026-07-18T22:04:11Z
```
Written only when there is something to record; if all fields are default/empty,
delete the file. Keys sorted on write for clean diffs.

## Analyses (owned by the nvim side, but the CLI must not disturb them)

`analyses/<YYYY-MM-DDTHH-MM-SSZ>/` (dashes in the time, `:` is illegal on
Windows; sorts lexicographically). Each holds `prompt.md`, `response.md`, and
`metadata.yaml` (`created_at`, `backend`, `model`, `issue_updated_at`,
`prompt_source`). **Staleness is derived**, never stored: current iff
`metadata.issue_updated_at == cached issue.updated_at`. The CLI indexes analysis
prose into FTS but otherwise leaves this tree to the plugin.

## Collections

`.issuehub/collections/<slug>/collection.yaml` (v2). `slug` = name lowercased,
non-alphanumeric runs → `-`, trimmed; a name that reduces to empty becomes
`"collection"`. Content:
```yaml
name: Sprint A
description: ...        # optional
issues:
  - jira://PROJ-123
  - github://tya5%2Fissuehub.nvim%237
```
`issues` kept sorted (the Lua sorts in `add`, preserves order in `remove`;
sorting on write is equivalent). **Pre-v2 compatibility:** also read a bare
`.issuehub/collections/<slug>.yaml`; on the next write, migrate to the directory
form and unlink the old file.

## Export columns (fixed order)

```
uri, provider, id, title, status, closed,
created_at, closed_at, updated_at, age_days, days_to_close,
assignee, reporter, labels, comments, url, bookmarked, fetched_at, memo,
meta.<k> ...                # union of metadata keys across rows, sorted
```
Ordered for analysis: identity, then the dates a defect curve needs, then the
rest.

- `age_days` = `created_at` → (`closed_at` or now); `days_to_close` =
  `created_at` → `closed_at`, blank while open.
- **Both are rounded to ONE DECIMAL PLACE (tenths of a day), not whole days.**
  Exact Lua: `math.floor(diff_seconds / 86400 * 10 + 0.5) / 10`, e.g. `3.5`. A
  port using integer day-division produces different values in every row — match
  the rounding.
- Multi-value fields (`labels`) join with `; `.
- CSV quotes any cell containing `"` `,` `\n` or `\r`.
- Markdown keeps `memo` as prose under a `## Notes` heading, not in a table cell.
