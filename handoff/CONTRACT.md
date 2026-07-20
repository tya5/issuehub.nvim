# The CLI contract

The interface between `issuehub.nvim` and the `issuehub` CLI. This is the
durable asset: the implementation behind it can change, this should not (without
a version bump). Design it first; the Lua plugin will be rewritten to consume
exactly this.

## Conventions

- **One invocation per command.** No daemon, no persistent state in memory. The
  process reads its inputs, does the work, prints result, exits.
- **Machine output is JSON on stdout** when `--json` is passed (the plugin
  always passes it). Without `--json`, output is human-readable text for
  terminal use.
- **Progress and logs go to stderr**, never stdout, so stdout stays parseable.
- **The workspace root** comes from `--workspace <path>` or `$ISSUEHUB_WORKSPACE`.
  Required for every verb except `version`.
- **Config** comes from `--config <path>` (TOML or JSON) or discovery
  (`$ISSUEHUB_CONFIG`, then `<workspace>/.issuehub/config.toml`). See
  [Config](#config) below. The plugin will pass provider/credential settings
  explicitly so nvim's config stays the source of truth — support both.
- **Exit codes:** `0` success; `1` a usage/config error; `2` a partial result
  (e.g. a page failed mid-sync but earlier pages succeeded); `>2` unexpected.
  The plugin distinguishes `2` from `1`.
- **All timestamps** are `YYYY-MM-DDTHH:MM:SSZ`, UTC, normalised (see
  CORRECTNESS.md §Timestamps).
- **Never print a credential**, not even in `--verbose`. See CORRECTNESS.md.

## Verbs

### `issuehub version`

`{ "version": "0.1.0", "contract": 1 }` — the `contract` integer is what the
plugin checks for compatibility. Bump it on any breaking change here.

### `issuehub health --json`

Reports readiness without doing network I/O beyond an optional credential probe.
```json
{
  "neovim": null,
  "tools": { "curl": "8.7.1", "git": true, "rg": true, "sqlite3": true },
  "workspace": { "path": "...", "exists": true, "git": false, "state_ignored": true },
  "index": { "backend": "sqlite", "fts5": true, "entries": 1240 },
  "network": { "proxy": "http://proxy.corp:8080", "ssl_verify": true, "cacert": null },
  "providers": [
    { "name": "jira", "type": "jira", "ok": true, "detail": "https://x (cloud), credential resolved" }
  ]
}
```
`ok`/`detail` per provider must report **whether the credential resolves, never
its value**. Mirror the Lua `:checkhealth` sections.

### `issuehub list --provider <name> [--project <p>] [--query <q>] [--max N] [--json]`

Query a provider (one page by default; `--max` pages further — see PROVIDERS.md
§Pagination). Writes each result to the cache as a **partial** entry (see
ONDISK.md §Cache) and returns them:
```json
{ "provider": "jira", "count": 100, "issues": [ <Issue>, ... ] }
```
`<Issue>` is the canonical shape in ONDISK.md §Issue. For `list`/`search` the
`description` and `comments` are empty (partial); `get` fills them.

### `issuehub get <uri> [--refresh] [--json]`

Return one complete issue. Serves from cache unless `--refresh`, then fetches,
merging comments (capped, see PROVIDERS.md). Writes the complete entry to cache.
```json
{ "issue": <Issue>, "cached_at": "…", "partial": false }
```

### `issuehub sync [--provider <name>] [--uri <uri>]... [--json]`

Re-fetch and report what changed. **Never mutates the workspace overlay** — only
the cache and `state.yaml` housekeeping. Targets default to everything cached
plus everything with local notes (see CORRECTNESS.md §Sync targets).
```json
{
  "total": 30, "changed": 2, "failed": 0,
  "changes": [
    { "uri": "jira://PROJ-123", "id": "PROJ-123", "fields": ["status","assignee"],
      "previous_status": "Open", "status": "In Progress", "comments_added": 2 }
  ],
  "errors": { "jira://PROJ-9": "HTTP 500: ..." }
}
```
Change detection compares the watched fields directly (see CORRECTNESS.md
§Change detection). Exit `2` if `failed > 0` but `changed`/unchanged succeeded.

### `issuehub fetch --provider <name> [--query <q>] [--resume] [--max N] [--json]`

Page a whole query into the cache, **incrementally and resumably**. This is a
long operation; the plugin runs it and streams progress. Emit one JSON object
per line to stdout as pages land (JSONL), so the plugin can show progress:
```
{"event":"page","pages":1,"issues":100}
{"event":"page","pages":2,"issues":200}
{"event":"done","pages":13,"issues":1240,"complete":true}
```
Merges into the **list cache** (ONDISK.md §List cache): pages accumulate, the
cursor persists, so `--resume` continues an interrupted walk. `--stop` is not a
verb — the plugin stops by killing the process; on the next `--resume` the
persisted cursor continues. Ensure a killed process has already flushed the list
cache for the pages it completed (flush per page, not at the end).

### `issuehub changed --json`

Issues whose remote revision moved since the user last opened them — derived
from `state.yaml`'s `last_seen_updated_at` versus the cached `updated_at`. See
CORRECTNESS.md §Changed-since-seen. Returns `{ "issues": [ <ViewItem>, ... ] }`.

### `issuehub search <pattern> [--regex] [--meta k=v]... [--provider p] [--project p] [--json]`

Local search across the cache and the workspace notes. Routing rule (CORRECTNESS
§Search routing): FTS5 for ASCII when available; **ripgrep for non-ASCII always**
and for `--regex`. `--meta` filters exactly on metadata and built-in fields
(`status`, `state`, `provider`, `project`, `assignee`, `bookmarked`, `labels`).
Returns `ViewItem`s annotated with `matched_in`:
```json
{ "items": [ { "uri":"…","id":"…","title":"…","matched_in":"memo,metadata" } ] }
```
`matched_in` may also name a translation as `translation:<lang>` on the ripgrep
path; the FTS path reports those hits as `analyses` (ONDISK §Translations).

### `issuehub export --source <src> --format <fmt> [-o <path>] [--json]`

`<src>`: `all`, `local`, `bookmarks`, `changed`, a collection name, a provider
instance name, or `provider/project`. `<fmt>`: `csv|markdown|json|yaml`.
**`all` and a provider/project source merge the cache with the workspace** — an
issue known only by its notes still appears, with blank issue columns (see
CORRECTNESS §Merged export). Columns and their order are fixed (ONDISK §Export
columns), including precomputed `age_days` / `days_to_close`. Returns the path
written: `{ "path": "…/all.csv", "rows": 1240 }`.

### `issuehub import <file> [--dry-run] [--json]`

Merge an exported CSV or JSON back into the workspace — the spreadsheet-triage
round trip. **Deliberately not the inverse of export**: only `memo`, `meta.*`,
and `bookmarked` are merged; issue columns are read and discarded (CORRECTNESS
§Import). `--dry-run` computes and reports the identical result without writing.

```json
{
  "imported": ["jira://PROJ-1"],
  "unchanged": 42,
  "overwritten": [ { "uri": "jira://PROJ-1", "field": "memo" } ],
  "metadata_comments": ["jira://PROJ-2"],
  "errors": ["not a valid issue URI: nonsense"],
  "git": true
}
```
`overwritten` must be reported, not summarised away: the file wins on conflict
without prompting, and that is only defensible because the report tells the user
where to point `git diff`. `git` is whether the workspace is a Git repository —
false means the undo does not exist and the caller should say so loudly.

### `issuehub summarize --source <src> [--by month|project|status|assignee|age] [--json]`

New surface (no Lua equivalent yet — build it here, it is why Python was chosen).
Returns aggregates the nvim side, or a model, can consume without re-implementing
date arithmetic:
```json
{
  "closed_by_month": { "2026-05": 8, "2026-06": 14 },
  "open_by_age_bucket": { "<7d": 6, "7-30d": 12, ">30d": 3 },
  "count": 1240, "open": 210, "closed": 1030
}
```

### `issuehub collection <add|remove|delete|list|show> ...`

CRUD over collections (ONDISK §Collections). `add <name> <uri>...`,
`remove <name> <uri>`, `delete <name>`, `list`, `show <name> --json`.

### `issuehub reindex [--json]`

Rebuild the index from the cache. `{ "count": 1240 }`. Must recover `bookmarked`
and `seen_at` from `state.yaml` (CORRECTNESS §Index is derived).

## Config

Accept a config file and/or explicit flags. The plugin will pass providers and
credentials rather than relying on a file, but a file must also work for
standalone CLI use. Shape (mirrors the Lua config — see the full field list in
PROVIDERS.md §Config and the `http` block below):

```toml
workspace = "~/notes/issuehub"
index = "auto"            # auto | json | sqlite

[providers.jira]
type = "jira"             # defaults to the table key
url = "https://your-org.atlassian.net"
user = "you@example.com"  # Jira Cloud basic-auth username
token_env = "JIRA_TOKEN"  # or token_cmd = [...], or token = "..."  (see below)
default_query = "assignee = currentUser() AND resolution = Unresolved"
projects = ["PROJ", "OPS"]
default_project = "PROJ"
comment_limit = 20
max_results = 100         # paging ceiling; default is one page
per_page = 100            # capped at 100 by every provider
flavor = "cloud"          # jira only; else auto-detected from hostname

[providers.jira.http]      # per-instance network override (optional)
no_proxy = "*"

[http]                     # global network settings (all optional)
proxy = "http://proxy.corp.example:8080"
no_proxy = "localhost,.internal"
proxy_user = "DOMAIN\\you"
proxy_password_env = "PROXY_PASSWORD"
proxy_auth = "ntlm"        # basic|digest|ntlm|negotiate|anyauth
cacert = "~/certs/root.pem"
client_cert = "~/certs/client.pem"
client_key = "~/certs/client.key"
ssl_verify = true          # false warns loudly; cacert is the real fix
timeout = 30000
retries = 2
```

**Credential resolution order (per secret), first hit wins:** a literal value >
a `*_cmd` array (run it, trim stdout) > a `*_env` name (read the env var). This
applies to `token` (providers) and `proxy_password` / `client_key_password`
(http). A literal must be accepted — silently ignoring it made curl prompt
interactively, which hung the editor (CORRECTNESS §Credentials).
