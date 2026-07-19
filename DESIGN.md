# issuehub.nvim — Design Specification

Status: **v0.4** — 0.1 is implemented; later milestones are still design.
Target Neovim: **0.11+** (0.12 recommended)
Version policy: pre-1.0. The public API may break between minor versions until 1.0.

---

## 0. Scope of this document

This is the implementation-facing design derived from the requirements draft
(v0.2 + §23 Ecosystem Integration). It fixes the decisions that are expensive to
change later: on-disk formats, module boundaries, the async model, and the
public extension APIs.

---

## 0.1 Terminology

These three words are used precisely throughout this document.

| Term | Meaning |
| ---- | ------- |
| **Workspace** | The *logical model*, in memory and in the public API: Issue + Overlay + State for a given URI. Has no knowledge of files. |
| **Repository** | The *on-disk representation* of a Workspace: directory layout, file formats, atomic write rules. An implementation detail. |
| **View** | The picker-agnostic model of "the set of issues currently under consideration" (§9.3). |

Consequence: the Repository layout may change in a future minor version without
breaking the Workspace API. Only `core/repository.lua` knows about paths.

The user-facing config key is `workspace` (it is the word users think in), even
though the path it holds is the Repository root. This is the one place the two
terms are deliberately conflated; everywhere else in code and docs they are kept
distinct.

**View is a core concept, not a UI concept.** The pipeline is:

```
Provider → Issue → View → { Picker, Export, Analysis, Collection }
```

Every list-shaped operation consumes a View. There is exactly one list model.

---

## 1. Design principles

### 1.1 Issue is a source, Workspace is knowledge

Remote issues are volatile and read-only. The Workspace is durable, local,
human+AI authored, and Git-managed. These two are never merged on disk — only at
render time.

### 1.2 Zero vendor lock-in

issuehub.nvim does **not** implement:

| Concern        | Delegated to                                    |
| -------------- | ----------------------------------------------- |
| Picker         | snacks.picker / fzf-lua / telescope / `vim.ui.select` |
| Git            | fugitive / gitsigns / the `git` CLI             |
| Diff           | `:diffthis` / vimdiff                           |
| Markdown view  | render-markdown.nvim / markview / anything      |
| File explorer  | oil.nvim / neo-tree / mini.files                |
| Notification   | `vim.notify` (snacks/noice override it)         |
| Input          | `vim.ui.input` (dressing/snacks override it)    |
| Search UI      | ripgrep + the host picker                       |
| AI             | Backend interface only                          |

What issuehub.nvim *does* own:

1. Provider abstraction (remote → Canonical Issue)
2. Cache
3. Workspace / Overlay management
4. Virtual buffer composition
5. Export
6. Backend connection

Everything else is a thin adapter.

**Accepted cost:** the `vim.ui.select` fallback cannot render columns, previews,
or async filtering. Issue listing is *usable* without a picker plugin but is
designed for one. This is documented, not worked around.

### 1.3 No hard dependencies

`dependencies = {}`. Every integration is `pcall(require, ...)` at call time.
Rationale: `vim.pack` (Neovim 0.12's built-in manager) has no concept of optional
dependencies, so runtime probing is the only portable mechanism.

### 1.4 Works before `setup()`

Defaults must be valid standalone. `setup(opts)` is exported (so lazy.nvim's
`opts = {}` works) but calling it is not required for the plugin to load — only
for provider credentials, which have no sensible default.

---

## 2. Source tree layout

(The plugin's own git repository — not to be confused with the *Repository* of
§0.1, which is the on-disk Workspace.)

```
issuehub.nvim/
├── plugin/
│   └── issuehub.lua              # commands + <Plug> maps only; no top-level require
├── lua/
│   └── issuehub/
│       ├── init.lua              # setup(), public entry
│       ├── config.lua            # defaults, merge, validation
│       ├── health.lua            # :checkhealth issuehub
│       ├── types.lua             # LuaCATS type definitions (no runtime code)
│       │
│       ├── core/
│       │   ├── issue.lua         # Canonical Issue model, uri parse/format
│       │   ├── repository.lua    # THE ONLY module that knows about paths (§5)
│       │   ├── cache.lua         # remote snapshot persistence (via repository)
│       │   ├── index/
│       │   │   ├── init.lua      # Index interface + backend selection (§5.2)
│       │   │   ├── json.lua
│       │   │   └── sqlite.lua    # sqlite3 CLI via vim.system
│       │   ├── workspace.lua     # logical model: Issue + Overlay + State (0.2)
│       │   ├── overlay.lua       # memo / metadata / prompt / tags (0.2)
│       │   ├── analysis.lua      # analysis history, staleness (0.5)
│       │   ├── collection.lua    # named issue sets (0.4)
│       │   ├── sync.lua          # refresh + change detection (0.3)
│       │   ├── search.lua        # ripgrep path for find() (0.4)
│       │   └── export.lua        # csv / md / json / yaml (0.4)
│       │
│       ├── provider/
│       │   ├── init.lua          # registry, resolve by uri scheme
│       │   ├── util.lua          # shared request/auth plumbing
│       │   ├── adf.lua           # Atlassian Document Format -> Markdown
│       │   ├── jira.lua
│       │   ├── redmine.lua
│       │   ├── github.lua
│       │   └── gitlab.lua
│       │
│       ├── backend/               # 0.5
│       │   ├── init.lua          # registry
│       │   ├── none.lua          # default no-op
│       │   └── a2a.lua           # lazily required
│       │
│       ├── ui/
│       │   ├── view.lua          # picker-agnostic View (§9.3)
│       │   ├── picker/
│       │   │   ├── init.lua      # auto-detect + dispatch, capability table
│       │   │   ├── format.lua    # shared column formatting
│       │   │   ├── snacks.lua
│       │   │   ├── fzf.lua
│       │   │   ├── telescope.lua
│       │   │   └── select.lua    # vim.ui.select fallback
│       │   ├── buffer.lua        # virtual buffer construction
│       │   ├── render.lua        # issue → lines + extmarks
│       │   └── highlight.lua     # highlight group definitions
│       │
│       └── util/
│           ├── http.lua          # HttpClient: vim.system + curl (§8)
│           ├── fs.lua            # atomic write, mkdir -p
│           ├── yaml.lua          # minimal YAML subset r/w (0.2)
│           └── log.lua
│
├── doc/
│   └── issuehub.txt              # generated by panvimdoc
├── spec/                         # busted specs
│   ├── runner.lua                # toolchain-free local harness (nvim -l)
│   └── *_spec.lua
├── .busted
├── .luacheckrc
├── .stylua.toml
├── issuehub.nvim-scm-1.rockspec
└── .github/workflows/
    ├── ci.yml                    # lint + test matrix (0.11, stable, nightly)
    └── release.yml               # luarocks-tag-release (0.7)
```

Entries annotated with a version do not exist yet; they are listed so the
intended home of each concern is fixed in advance.

**`plugin/issuehub.lua` rule:** it may only create user commands, `<Plug>`
mappings, and highlight groups. Every callback defers its `require`. Result: the
plugin self-lazy-loads; users do not need `cmd =` in their spec.

No default keymaps are created. `<Plug>(IssueHubOpen)` etc. are exposed instead.

---

## 3. Configuration

```lua
require("issuehub").setup({
  -- REQUIRED. Points at the Repository root (§5). No default: this is a
  -- Git-managed knowledge base and must live at a path the user chose
  -- deliberately.
  workspace = "~/notes/issuehub",
  -- Derived state lives at <workspace>/.state/ and is not configurable.

  -- "auto" uses sqlite3 when the CLI is present, else json (§5.3)
  index = "auto",     -- "auto" | "json" | "sqlite"

  providers = {
    jira = {
      url = "https://example.atlassian.net",
      user = "me@example.com",
      -- Credential resolution order (first hit wins):
      token_env = "JIRA_TOKEN",
      token_cmd = { "op", "read", "op://vault/jira/token" },
      -- token = function() ... end   -- escape hatch
      default_query = 'assignee = currentUser() AND resolution = Unresolved',
    },
    redmine = {
      url = "https://redmine.example.com",
      token_env = "REDMINE_API_KEY",
      default_query = { assigned_to_id = "me", status_id = "open" },
    },
  },

  backend = "none",         -- "none" | "a2a" | custom name
  backends = { a2a = { url = "http://localhost:9100" } },

  ui = {
    picker  = "auto",       -- "auto"|"snacks"|"fzf"|"telescope"|"select"
    notify  = "auto",
    input   = "auto",
    preview = true,
  },

  sync = {
    on_open = "stale",      -- "always" | "stale" | "never"
    stale_after = 15 * 60,  -- seconds
  },

  export = { dir = nil, default_format = "markdown" },
  log_level = vim.log.levels.WARN,
})
```

**Credential rules (non-negotiable):**

- Tokens are never written to the config file in plaintext by us, never logged,
  never placed in `argv` (visible in `ps`).
- `token_cmd` output is trimmed and cached in-memory for the session only.
- curl receives credentials via `--config -` on **stdin**.

Validation: LuaCATS `---@class issuehub.Config` in `types.lua` is the contract.
Merging is `vim.tbl_deep_extend("force", defaults, opts or {})`, after which a
hand-rolled `validate()` returns a list of human-readable errors reported in one
`vim.notify`. `vim.validate` is deliberately not used: it throws on the first
failure, and a config with three mistakes should report three, not one.

Keys belonging to unimplemented milestones (`backend`, `backends`, `export`) are
**rejected**, not ignored — silently accepting `setup({ backend = "a2a" })` and
doing nothing is worse than an error.

---

## 4. Canonical Issue model

```lua
---@class issuehub.Issue
---@field uri string            -- "jira://PROJ-123"
---@field provider string
---@field id string
---@field title string
---@field description string
---@field status issuehub.Status
---@field assignee string?
---@field reporter string?
---@field labels string[]
---@field url string?           -- browser URL
---@field comments issuehub.Comment[]
---@field created_at string     -- ISO 8601 UTC
---@field updated_at string     -- ISO 8601 UTC
---@field raw table             -- untouched provider payload
```

### 4.1 Status

**The core does not model workflow semantics.**

```lua
---@class issuehub.Status
---@field id string          -- provider-stable identifier, e.g. "in_review", "3"
---@field name string        -- display label, verbatim from the provider
---@field closed boolean     -- the only semantic the core interprets
```

An earlier draft mapped every provider onto a fixed `todo|active|review|done`
ladder. That is dropped, for the same reason there is no cross-provider query DSL
(§7): "In Review", "QA", "Waiting for Release" mean different things in different
organizations, and both Jira and Redmine let each installation define its own
workflow. Any fixed enum either loses information or forces a wrong answer.

So the core interprets exactly one thing — `closed` — and treats everything else
as opaque display data:

| Core behavior | Uses |
| ------------- | ---- |
| Default sort | `closed` last, then `updated_at` desc |
| Default filter | `closed == false` |
| Rendering | `status.name` verbatim |
| Collections | e.g. "Critical Open Bugs" == `closed == false` + labels |

Mapping to `closed` is the provider's only obligation, and it is unambiguous in
practice: Jira uses `statusCategory.key == "done"`, Redmine uses
`status.is_closed`. Both are supplied by the API — no guessing, no built-in
label table to maintain, no `status_map` config.

**Accepted cost:** grouping "everything in progress" across providers is not
possible from core data alone. Anyone needing it filters on `status.id` /
`status.name` per provider, or builds a Collection. This is the honest boundary:
the core knows whether work is finished, and nothing more.

`raw` retains the full provider status object for anyone who needs it.

### 4.2 URI grammar

`<provider>://<id>`. The `<id>` is percent-encoded per RFC 3986 for any character
that is unsafe in a path segment (`/`, `#`, `?`, `%`, and control characters).

The URI is the single join key across remote, cache, and Repository, and appears
verbatim in exports and Backend requests. See §5.4 for how it maps to a path.

---

## 5. Repository (on-disk layout)

The single governing rule: **the Repository root contains only what belongs in
Git.** Everything derived, volatile, or machine-generated lives under `.state/`.

```
<workspace>/            # the Repository root (§0.1)
├── .issuehub/                  # tracked: schema + user-authored config
│   ├── version                 # Repository layout version, e.g. "1"
│   └── collections/
│       └── sprint-a.yaml
│
├── .state/                     # NEVER tracked (see .gitignore below)
│   ├── cache/
│   │   └── jira/PROJ-123.json  # { fetched_at, issue }
│   ├── index/
│   │   └── issues.json         # or issues.db — derived, see §5.2-5.3
│   └── lock/
│       └── sync.lock
│
├── .gitignore                  # written on init, contains "/.state/"
│
├── jira/
│   └── PROJ-123/
│       ├── memo.md
│       ├── metadata.yaml
│       ├── prompt.md
│       ├── state.yaml
│       └── analyses/
│           └── 2026-07-19T13-24-18Z/
│               ├── prompt.md
│               ├── response.md
│               └── metadata.yaml
└── redmine/
    └── 12345/
        └── ...
```

Why `.state/` inside the Repository rather than a separate cache dir: cache,
index, and locks are meaningless without the Workspace they describe, and keeping
them adjacent means `mv` / `rsync` / backup of one directory moves everything
consistently. `.gitignore` keeps them out of history. It also leaves an obvious
home for future additions (search index, SQLite, rendered previews) without
another top-level decision.

`config.cache` is therefore removed; `.state/` is always
`<workspace>/.state/`. Users who need it elsewhere can symlink.

### 5.1 File rules

- Every file is optional. Absence == empty. Directories are created lazily on
  first write, so browsing does not litter the tree.
- All writes are **atomic**: write to `.tmp`, `fsync`, `rename`.
- Tracked files are text-only and must diff cleanly in Git.
- `.issuehub/version` gates future migrations.
- `.state/` is safe to delete at any time; the next operation rebuilds it.

`state.yaml` (tracked — it is user-meaningful, not derived):

```yaml
bookmarked: true
last_opened_at: 2026-07-19T10:15:00Z
last_seen_updated_at: 2026-07-18T22:04:11Z   # for "changed since I last looked"
```

Analysis directories are stamped `YYYY-MM-DDTHH-MM-SSZ` (dashes in the time
component, since `:` is illegal on Windows and awkward in shells), so multiple
analyses in one day never collide and sort lexicographically.

### 5.2 Index

The index lets the picker open instantly and fully offline without reading N
cache files. It is a **derived projection of `cache/` plus the Workspace files**,
never a source of truth: it is rebuilt whenever missing, corrupt, or
version-mismatched, and deleting `.state/` is always safe.

```lua
---@class issuehub.Index
---@field name string
---@field put fun(self, issue: issuehub.Issue)
---@field delete fun(self, uri: string)
---@field list fun(self, filter: table?): issuehub.ViewItem[]
---@field search fun(self, query: string): issuehub.ViewItem[]
---@field rebuild fun(self): integer   -- returns the number of entries rebuilt
---@field health fun(self): boolean, string
```

Note these are **colon methods** taking `self`, and `health` returns two values
rather than a table — matching every other interface in the plugin. `put` takes a
whole Issue rather than a pre-projected item plus a separate text bundle: the
backend decides what it can index (the sqlite backend feeds title and description
to FTS5; the json backend ignores them).

### 5.3 Index backends

Two implementations behind that one interface:

| Backend | Storage | Selected when |
| ------- | ------- | ------------- |
| `json` | `.state/index/issues.json` | default; always available |
| `sqlite` | `.state/index/issues.db` | `config.index = "sqlite"`, or `"auto"` with a working `sqlite3` |

**SQLite is driven through the `sqlite3` CLI via `vim.system()`** — the same
decision as HTTP (§8), for the same reason. `sqlite.lua` would require
libsqlite3 plus a LuaJIT FFI binding: a genuine hard dependency, which §1.3
forbids. The CLI is a single optional binary, probed at runtime, degrading to
`json` when absent.

Schema:

```sql
CREATE TABLE issues (
  uri TEXT PRIMARY KEY, provider TEXT, id TEXT, title TEXT,
  status TEXT, closed INTEGER, assignee TEXT,
  updated_at TEXT, fetched_at TEXT, bookmarked INTEGER
);
CREATE INDEX idx_issues_open ON issues(closed, updated_at DESC);

-- optional, only if the sqlite3 build has FTS5
CREATE VIRTUAL TABLE issues_fts USING fts5(
  uri UNINDEXED, title, description, memo, metadata, analyses,
  tokenize = 'unicode61'
);
```

What SQLite buys, and when it earns its place:

- `list()` with filters and ordering stops being an O(n) Lua scan — this matters
  at thousands of issues, not dozens.
- **FTS5 gives ranked full-text search over memo and analysis history**, which
  ripgrep cannot do: ripgrep finds *lines*, FTS5 finds *documents by relevance*.
  For a knowledge base that accumulates prose, this is the real payoff.
- Incremental update on sync instead of rewriting the whole JSON file.

Writes go through a single serialized queue (one `sqlite3` process at a time,
WAL enabled) since concurrent CLI invocations would contend on the write lock.

**The sqlite3 CLI has no parameter binding**, so values are escaped and
interpolated into SQL text by a single total escaping function (quote-doubling,
NUL-stripping, numeric and boolean passthrough). That is tolerable only because
every value originates from a provider payload and the database holds nothing but
a rebuildable projection of the cache. If this layer ever accepts user-authored
SQL fragments, it must move to real binding first.

FTS5 is not universally compiled in. Its presence is probed once
(`SELECT * FROM pragma_compile_options`) and recorded; without it, the `sqlite`
backend still serves `list()` and delegates `search()` to ripgrep.

**Migration is a non-event:** switching backends just deletes `.state/index/`
and rebuilds from `cache/`. No user data is at risk, because the index holds
none.

### 5.4 URI → path mapping

The percent-encoded form from §4.2 is used **verbatim as the directory name**:

```
jira://PROJ-123      → jira/PROJ-123/
jira://PROJ/123      → jira/PROJ%2F123/
redmine://12345      → redmine/12345/
```

Hashing was rejected: the Repository is meant to be browsed with oil.nvim, read
in a Git diff, and grepped by a human. Percent-encoding keeps the common case
(`PROJ-123`) completely unchanged and stays readable in the rare case.

Case-insensitive filesystems (macOS default) mean `PROJ-1` and `proj-1` would
share one path. Rather than normalize casing — which would require knowing each
provider's canonical form — the cache checks for an existing entry differing only
by case before writing, and **returns an error rather than merging two issues'
data into one directory**.

---

## 6. Virtual buffer

```
Cache(Issue)  +  Workspace(Overlay)  →  rendered buffer
```

Buffer name: `issuehub://jira/PROJ-123`
`buftype=acwrite`, `filetype=issuehub`, `swapfile=false`.

Layout:

```
# PROJ-123  Timeout on cache warmup            ← readonly region

- Status:   In Progress
- Assignee: tetsuya
- Reporter: alice
- Labels:   timeout, cache
- Updated:  2026-07-19T01:15:00Z  (synced 2026-07-19T09:59:30Z)
- URL:      https://example.atlassian.net/browse/PROJ-123

## Description                                 ← readonly
...

## Comments (3)                                ← readonly, foldable
...

## Memo                                        ← EDITABLE → memo.md
...

## Metadata                                    ← EDITABLE → metadata.yaml
priority: high

## Prompt                                      ← EDITABLE → prompt.md
...
```

0.1 renders the readonly sections plus a single `## Memo` placeholder; Metadata
and Prompt appear with the overlay in 0.2. Timestamps are absolute rather than
relative ("2 minutes ago") so a buffer left open overnight cannot lie.

**Read-only enforcement:** section boundaries are tracked with extmarks
(`right_gravity=false` on the start, `true` on the end). On `TextChanged`, edits
that touch a readonly region are reverted with a `vim.notify` warning. This is
advisory-by-design: Neovim has no true per-region lock, and fighting the user
harder than this produces a worse experience than the occasional revert.

**Writing:** `:w` (BufWriteCmd) extracts each editable region and writes only the
files whose content changed. `modified` is cleared on success.

Rendering is line-based Markdown so that Treesitter, folding, `/` search, marks,
and any markdown renderer plugin just work — per §23 no custom editor is built.
Highlighting is extmark-based on top of the markdown parser.

`ftplugin` sets buffer-local options and a buffer-local `gx`. Nothing global
is touched and no keys are mapped in the user's namespace.

---

## 7. Provider interface

```lua
---@class issuehub.Provider
---@field name string
---@field setup fun(self, opts: table): boolean, string?
---@field list fun(self, query: any?, cb: fun(err: string?, issues: issuehub.Issue[]?))
---@field get fun(self, id: string, cb: fun(err: string?, issue: issuehub.Issue?))
---@field search fun(self, query: string, cb: fun(err: string?, issues: issuehub.Issue[]?))
---@field health fun(self): boolean, string
```

Rules:

- Providers are **UI-free** and **workspace-unaware**. They convert remote
  payloads to Canonical Issues and nothing else.
- All I/O is asynchronous and callback-based; callbacks are invoked via
  `vim.schedule()` so consumers are never in a fast event context.
- Errors are returned, never thrown, never `vim.notify`'d from inside a provider.
- `list()` may return partial issues (no `comments`/`description`) for speed;
  `get()` must return complete ones. The picker only needs `list()` fields.

### 7.1 Instances vs types

A configured provider is an **instance**. `providers.<name>.type` chooses the
implementation and defaults to `<name>`, so the common single-server case stays
`providers.jira = { … }` while a second Jira is just another key:

```lua
jira          = { url = "https://org.atlassian.net", … }   -- type = "jira"
jira_internal = { type = "jira", url = "https://jira.internal", … }
```

The instance name — not the type — is the URI scheme, the credential key, the
network-settings key, and the workspace directory. That is what keeps
`jira://PROJ-123` and `jira_internal://PROJ-123` from colliding on disk, which is
the whole point: two servers routinely use the same issue keys.

Providers therefore never hardcode their own name. `M.new(name)` receives the
instance name and stamps it on every Issue it produces.

### 7.2 Shipped providers

| Provider | Hosts | Auth | ID form | `closed` derived from |
| -------- | ----- | ---- | ------- | --------------------- |
| `jira` | Cloud, Server/DC | API token (Basic) / PAT (Bearer) | `PROJ-123` | `statusCategory.key == "done"` |
| `redmine` | self-hosted | `X-Redmine-API-Key` header | `12345` | `/issue_statuses.json` map |
| `github` | github.com, Enterprise Server | PAT (Bearer) | `owner/repo#123` | `state` (+ `merged_at`, `draft`) |
| `gitlab` | gitlab.com, self-managed | `PRIVATE-TOKEN` header | `group/project#12` | `state == "closed"` |

No provider guesses `closed` from a status label — each uses a field the API
states outright. Redmine is the interesting case: its issue payload carries
`status.is_closed` only on newer versions, so the provider fetches
`/issue_statuses.json` **once per session** and uses it as the authority, falling
back to the per-issue field when present. Status names are per-instance
configurable in Redmine, so a name-based table would be exactly the guessing §4.1
exists to prevent.

**Repository-qualified IDs.** GitHub and GitLab number issues per repository, so
the ID must carry the repository for a workspace to span more than one. The
resulting `/` and `#` are what the RFC 3986 encoding of §4.2 was designed for:

```
github://tya5%2Fissuehub.nvim%23123   →  github/tya5%2Fissuehub.nvim%23123/
gitlab://group%2Fsub%2Fproj%2312      →  gitlab/group%2Fsub%2Fproj%2312/
```

**GitHub pull requests are included.** GitHub numbers issues and pull requests in
one sequence per repository, so `owner/repo#123` remains unambiguous. Status
distinguishes them: `Open`, `Draft`, `Merged`, `Closed`.

**Query passthrough in practice.** `search()` takes JQL for Jira, GitHub search
qualifiers for GitHub, and a free-text term for GitLab and Redmine. `list()`
additionally accepts a parameter table for Redmine and GitLab, whose list
endpoints are filter-driven rather than query-driven. None of these are
translated into one another — see §7's rationale.

Third-party registration:

```lua
require("issuehub.provider").register("github", my_provider)
```

`search()` semantics differ per provider (JQL vs Redmine filters) and are
intentionally passed through rather than abstracted into a query DSL — a
lowest-common-denominator query language would be worse than either native one.
Cross-provider search is handled by `core/search.lua` over the local cache.

---

## 8. HTTP layer

Providers never call `vim.system` or `curl` directly. They depend only on the
**HttpClient** interface:

```lua
---@class issuehub.HttpClient
---@field request fun(req: issuehub.HttpRequest, cb: fun(err: string?, res: issuehub.HttpResponse?))
```

This is the seam that makes tests injectable (§20) and lets the transport be
swapped for `vim.net` once 0.13 ships headers and bodies, or extended with OAuth,
cookie jars, or client certificates — all of which are curl config-file concerns
and therefore already expressible through the stdin channel below.

The default implementation, `util/http.lua`, is built on `vim.system()` + `curl`.

Rationale: `vim.net.request()` in Neovim 0.12 is GET-only with no header or body
support (it lands complete in 0.13), so it cannot make authenticated API calls.
plenary.curl would mean a hard dependency, which §1.3 forbids.

```lua
http.request({
  method = "GET",
  url = ...,
  headers = { ... },
  body = ...,          -- table → JSON
  auth = { bearer = "..." },   -- or { basic = "user:token" }; sent via stdin
  timeout = 30000,
}, function(err, res) end)   -- res = { status, headers, body }
```

- Secrets go through `--config -` on stdin.
- `--fail-with-body -w '\n%{http_code}'` to recover the status code.
- `on_exit` runs in a fast event context → every callback is wrapped in
  `vim.schedule()` inside `http.lua`, so no caller has to remember.
- Retry with backoff on 429/5xx, honoring `Retry-After`.
- Concurrency is capped (default 6) to avoid hammering the API on bulk sync.

### 8.1 Corporate networks

Everything an enterprise deployment needs is a curl config-file concern, which is
why §8's stdin channel was worth building even before there was a proxy to
configure:

| Concern | Config | curl |
| ------- | ------ | ---- |
| Proxy | `http.proxy`, `http.no_proxy` | `proxy`, `noproxy` |
| Proxy auth | `http.proxy_user` + password, `http.proxy_auth` | `proxy-user`, `proxy-ntlm` … |
| TLS interception | `http.cacert`, `http.capath` | `cacert`, `capath` |
| Mutual TLS | `http.client_cert`, `http.client_key` | `cert`, `key`, `pass` |
| Verification off | `http.ssl_verify = false` | `insecure` |

Rules:

- **Omitting a setting means "let curl decide."** With no `http` block at all,
  curl honours `http_proxy` / `https_proxy` / `no_proxy` from the environment,
  which is what managed machines already set. issuehub does not re-implement that
  precedence.
- **Proxy passwords and key passphrases are credentials** and go through the same
  resolver as provider tokens (`config.secret`): literal, command, or env, then
  stdin — never argv.
- **Settings merge per provider.** `providers.<name>.http` overrides the global
  block, because an internal tracker reached directly alongside SaaS behind a
  proxy is the normal mixed case, not an exotic one.
- **A proxy user always emits `user:password`,** with an empty password if none
  resolved. A bare user makes curl prompt on the terminal, which hangs a headless
  Neovim rather than failing.
- **`ssl_verify = false` is accepted but never silent.** It warns at `setup()`
  and `:checkhealth` reports it as an error while enabled. The supported answer
  to TLS interception is `cacert`, which keeps verification on.

Health check verifies `curl` is present and reports its version, and the Network
section reports the effective proxy (credentials stripped), CA bundle, mTLS
state, verification setting, and any per-provider override.

---

## 9. UI facade

There is deliberately **no `issuehub.ui` facade module**. An earlier draft
specified one wrapping `notify`/`input`/`confirm`; building it would have been
pure indirection, because snacks, noice, and dressing all override `vim.notify`
and `vim.ui.input` *globally*. Calling core Neovim directly IS the integration,
and `config.ui.notify` / `config.ui.input` settings would have nothing to switch
between. Call sites use `vim.notify` and `vim.ui.input` directly.

Only the picker needs an abstraction, because pickers do not override anything
global.

### 9.1 Picker capability levels

**Primary UI backend: snacks.nvim.** It is the reference implementation; every
picker feature is designed against it first and then degraded.

| Tier | Backend | Meaning |
| ---- | ------- | ------- |
| **Primary** | snacks.picker | Reference implementation. Features are designed here first. |
| **Secondary** | fzf-lua | Fully supported, actively verified in CI-adjacent manual testing. |
| **Compatible** | telescope | Works; kept in step but not driving design. Upstream is in maintenance mode. |
| **Fallback** | `vim.ui.select` | Single-column selection only. Guarantees issuehub functions with zero plugins. |

The first three are capability Level 1 (multi-column, preview, async filtering,
multi-select, actions). `vim.ui.select` is Level 2.

Level 2 is a guarantee that issuehub *functions* with zero plugins installed. It
is not a target for feature parity, and the docs say so plainly.

### 9.2 Picker backend interface

```lua
---@class issuehub.Picker
---@field name string
---@field caps issuehub.PickerCaps
---@field pick fun(view: issuehub.View, opts: issuehub.PickOpts)
```

```lua
---@class issuehub.PickerCaps
---@field preview boolean       -- can render a side preview pane
---@field multi_select boolean  -- can return >1 item
---@field actions boolean       -- can bind extra keys to item actions
```

Capabilities are limited to the three flags the core actually branches on:

- `preview = false` → the picker shows only the item list; issue detail is seen
  after opening the buffer. Core does not attempt a substitute preview.
- `multi_select = false` → bulk operations (export/analyze/collection-add) fall
  back to "current view" or "single item" scope, and the UI does not advertise
  a multi-select keymap that cannot work.
- `actions = false` → all secondary operations are reachable only via
  `:IssueHub` subcommands after selection.

Adding a backend means implementing `pick` and declaring these three. Nothing
else is negotiated. Flags that no core branch reads (icons, sorting, layout) are
deliberately **not** capabilities — they are adapter-internal presentation.

Detection order when `config.ui.picker == "auto"`:

```
snacks.picker → fzf-lua → telescope → vim.ui.select
```

Resolved once, lazily, cached; only the chosen adapter is `require`d.

### 9.3 View

A **View** is the picker-agnostic representation of "the set of issues currently
under consideration". It is what the picker renders and what every downstream
operation consumes.

```lua
---@class issuehub.View
---@field source string                    -- "query"|"collection"|"find"|"bookmarks"
---@field label string                     -- human-readable, used in export filenames
---@field items issuehub.ViewItem[]
---@field get_items fun(self): issuehub.ViewItem[]
---@field get_selected fun(self): issuehub.ViewItem[]   -- falls back to all items
```

```lua
---@class issuehub.ViewItem
---@field uri string
---@field id string
---@field title string
---@field status string        -- status.name, flattened for display
---@field closed boolean       -- status.closed, the only sortable/filterable semantic
---@field assignee string?
---@field updated_at string
---@field bookmarked boolean
```

This is the key decoupling: `export`, `analyze`, and `collection add` take a
`View`, never a picker. So

```lua
require("issuehub.export").write("csv", view)
```

works identically whether the view came from snacks multi-select, a collection
file, a `find` result, or a headless script that built one by hand. Adding a
picker backend adds zero code paths to export.

`get_selected()` returning all items when the backend lacks `multi_select` is
what makes Level 2 degrade gracefully instead of erroring.

The preview callback renders the same content as `ui/buffer.lua`, so preview and
the real buffer can never drift.

---

## 10. Synchronization

```
:IssueHub sync [uri|collection]
```

For each target: fetch → compare against cache → write cache → record a change
summary. **The workspace is never mutated by sync**, except `state.yaml`
housekeeping.

Detected changes: `description`, `status`, `assignee`, new comments.

Change detection compares the watched fields directly (status, assignee, title,
description, labels, comment count). An earlier draft specified `updated_at` with
a content-hash fallback; direct comparison replaced it because it is both cheaper
to reason about and strictly more informative — the report has to say *what*
moved, so the comparison has to happen regardless, and a hash would be a second
mechanism answering a weaker question.

`updated_at` is still used, but for a different question: `state.yaml` records
the revision the user last opened, so "changed since I last looked" survives
restarts and accumulates across syncs. That marker is mirrored into the index, so
listing changed issues is a filter rather than a walk of the Repository.

Comment counts come from the provider's reported total where available, since the
fetched list is capped (§23.3) and its length would understate the change.

`sync.on_open = "stale"` refreshes on open only when the cache is older than
`stale_after`, and does so **asynchronously after rendering** — the buffer always
appears instantly from cache, then updates in place.

Offline: every read path falls back to cache and shows the staleness in the
header. Read-only operation with no network is a supported mode, not an error.

---

## 11. Analysis

```
analyses/<timestamp>/{prompt.md,response.md,metadata.yaml}
```

`metadata.yaml`:

```yaml
created_at: 2026-07-19T10:15:00Z
backend: a2a
model: claude-opus-4-8
issue_updated_at: 2026-07-18T22:04:11Z
issue_hash: sha256:...
prompt_source: workspace   # workspace | ad-hoc
```

**Staleness** is derived, never stored as a mutable flag: an analysis is
`current` if `issue_updated_at` matches the cached issue, otherwise `outdated`.
This means it can never go wrong after a manual Git edit or a revert.

---

## 12. Metadata

Free-form YAML, no fixed schema. issuehub only requires that the file parses as a
flat-ish map of scalars, lists, and one nesting level — enough for the built-in
minimal YAML reader/writer, and enough to project into CSV columns for export.

Unknown keys are preserved verbatim on rewrite (round-trip safety matters more
than normalization, because these files are hand-edited and Git-diffed).

---

## 13. Collections

`<workspace>/.issuehub/collections/<slug>.yaml`:

```yaml
name: Sprint A
description: 2026-07 sprint
issues:
  - jira://PROJ-123
  - redmine://12345
```

Collections are local, may span providers, and are the unit for bulk
`sync` / `analyze` / `export` / `search`. A dynamic (query-backed) collection is
deliberately deferred — static lists are Git-diffable and predictable.

---

## 14. Export

Input: a **View** (§9.3) — never a picker, never a raw selection. For each item,
the latest cached Issue + Workspace overlay. Output: `csv`, `markdown`, `json`,
`yaml`. The output filename defaults to `<view.label>.<ext>`.

Column selection for tabular formats is configurable; metadata keys are flattened
to `meta.<key>`. Multi-value fields join with `; `. Export never performs network
I/O — sync first if freshness matters (and the exporter records `fetched_at` so
staleness is visible in the output).

Third parties register exporters:

```lua
require("issuehub.export").register("xlsx", { ext = "xlsx", write = fn })
```

---

## 15. Search

Two distinct operations, deliberately not merged:

| Command                | Scope                                        |
| ---------------------- | -------------------------------------------- |
| `:IssueHub search`     | Provider-side (JQL / Redmine filter), online  |
| `:IssueHub find`       | Local: cache + memo + metadata + analyses     |

`find` is served by the Index (§5.2). With the `sqlite` backend and FTS5, it is a
ranked full-text query across title, description, memo, metadata, and analysis
history. Otherwise it shells out to `ripgrep` (`--json`) over `.state/cache/` and
the Workspace and maps hits back to URIs. Both paths return the matched field, so
the picker can show *why* something matched.

The two are complementary, not redundant: FTS5 ranks whole documents by
relevance, ripgrep finds exact lines and regexes. `:IssueHub find` uses whichever
is available; a `--regex` flag forces the ripgrep path even when FTS5 is present.
If neither is available, `find` degrades to a Lua scan of the index.

---

## 16. Backend interface

```lua
---@class issuehub.Backend
---@field name string
---@field discover fun(self, cb: fun(err: string?, caps: table?))
---@field send fun(self, req: issuehub.Request, cb: fun(err: string?, res: table?))
---@field health fun(self): boolean, string
```

Internal request model:

```lua
---@class issuehub.Request
---@field resource string          -- issue uri or collection name
---@field workspace table          -- memo, metadata, prompt (as text)
---@field prompt string
---@field selection string?        -- visual selection, if any
---@field metadata table           -- model hints, backend-specific
```

`none` is the default and returns a clear "no backend configured" error.
`a2a.lua` is `require`d only when selected, so its cost is zero otherwise. A2A
Task support is optional; Message-only operation is fully supported.

Bridging to Copilot Chat / CodeCompanion / Avante is done by third-party backends
registered against this interface — issuehub itself ships no AI integration.

---

## 17. Commands

Single namespaced command with subcommands (per Neovim plugin conventions —
`:Rocks install`, not `:RocksInstall`), plus completion:

Implemented in 0.1:

```
:IssueHub                     -- open the picker (default action)
:IssueHub open [uri]
:IssueHub search <query>      -- provider-side
:IssueHub find <pattern>      -- local index
:IssueHub local               -- everything cached, offline
:IssueHub sync [target]       -- re-fetch and report what moved
:IssueHub changed             -- moved since you last looked
:IssueHub refresh             -- re-fetch the current issue buffer
:IssueHub bookmark            -- toggle on the current issue
:IssueHub bookmarks           -- picker over bookmarked issues
:IssueHub reindex             -- rebuild the index from cache
:IssueHub provider list|health
:IssueHub health
```

Planned, with the milestone that adds them:

```
:IssueHub export <format> [target]   -- 0.4
:IssueHub collection [name]          -- 0.4
:IssueHub analyze [target]           -- 0.5
```

No user-facing string may reference a command from the second list.

The namespaced form is what makes `provider list` / `collection add` possible
without inventing a new top-level command per noun.

The short aliases from the draft (`:IssueOpen`, …) are **dropped** — nine
top-level commands pollute the global command namespace and break completion
discoverability. If demand appears, an opt-in `config.short_commands = true` can
define them.

`<Plug>(IssueHubOpen)`, `<Plug>(IssueHubFind)`, and `<Plug>(IssueHubRefresh)`
are exposed for user keymaps. More are added alongside the commands that need
them.

---

## 18. Error handling & logging

- No error is ever silently swallowed; user-visible failures go through
  `vim.notify` once, with the provider name and a short cause.
- `util/log.lua` writes to `stdpath("log")/issuehub.log` at `log_level`.
- Tokens and `Authorization` headers are redacted by the logger unconditionally.
- Network errors during background sync notify at `WARN` and leave the cache
  intact.

---

## 19. Health check

`lua/issuehub/health.lua` returns `{ check = function() ... end }`, using
`vim.health.start/ok/warn/error/info`:

- Neovim ≥ 0.11
- `curl` present (required); `git`, `rg`, `sqlite3` present (recommended)
- Active index backend, and whether FTS5 is compiled into `sqlite3`
- `repository` configured, exists, writable, is a Git repo (info if not),
  `.state/` present in `.gitignore` (warn if tracked)
- Per-provider: URL set, credential resolvable (**without printing it**), reachable
- Detected picker backends and which one is active, with its capabilities
- Index backend in use, and whether FTS5 is compiled into `sqlite3`
- Selected Backend and its `health()` (from 0.5)

---

## 20. Testing & CI

- **busted + nlua** (`spec/`, `.busted` with `lua = "nlua"`). No plenary
  dependency, consistent with §1.3.
- Providers are tested against **recorded fixtures**, not live APIs. `util/http`
  is injectable so specs substitute a fake transport.
- Workspace/overlay tests run against a temp dir and assert exact file bytes —
  the on-disk format is the contract.
- CI: `lumen-oss/nvim-busted-action` matrix over `0.11`, `stable`, `nightly`;
  `stylua --check` + `luacheck`.
- Release: `luarocks-tag-release` on tag. Docs: panvimdoc → `doc/issuehub.txt`.

---

## 21. Non-goals (v0.x)

Unchanged from the draft: no issue updates, no comment posting, no status
changes, no board/sprint views, no custom TUI. Additionally: no query DSL across
providers, no dynamic collections, no semantic search.

---

## 22. Milestones

Versions stay `0.x` throughout. **1.0 is not tagged until the public
Provider/Backend/Export/Workspace APIs have been stable across at least one minor
release** with a third-party provider proving the interface.

| Version | Contents |
| ------- | -------- |
| **0.1** ✅ | config + validation, health, HttpClient, Canonical Issue + minimal Status, Repository skeleton (`.state/`, `.gitignore`, URI→path, case-collision guard), cache incl. partial-result handling, **both index backends incl. FTS5**, Jira provider + ADF, View, picker abstraction + all four adapters, read-only virtual buffer, `find` / `local` / `reindex` |
| **0.1.1** ✅ | Redmine, GitHub, and GitLab providers; repository-qualified IDs |
| **0.2** ✅ | Workspace + Overlay (memo/metadata/prompt), editable regions, `:w` writeback, bookmarks, `state.yaml` |
| **0.3** ✅ | sync + change detection, "changed since I last looked", `:IssueHub sync` / `changed` |
| **0.4** | Collections, Export (all four formats), ripgrep path + `--regex` for `find` |
| **0.5** | Backend interface, `none` + A2A, Analysis history and staleness |
| **0.6** | FTS5 indexing of memo / metadata / analysis bodies (the schema columns exist in 0.1 but are populated only with title and description) |
| **0.7** | Docs, vimdoc, third-party extension guide, API freeze candidate |

Rationale for the ordering: each milestone is independently useful, and the
riskiest unknowns (auth/HTTP, picker portability) are resolved in 0.1 rather than
discovered late.

---

## 23. Resolved design decisions

1. **Jira Cloud vs Server/DC** — *fully hidden inside the provider.* Core knows
   only `Provider`. `jira.lua` carries a `flavor = "cloud"|"server"` switch selecting auth style
   (API token + Basic vs PAT bearer) and REST version (`/rest/api/3` vs
   `/rest/api/2`). Detection is a **hostname heuristic** (`*.atlassian.net` ⇒
   Cloud), not a `/serverInfo` probe: auth style and REST version must be known
   before the first request can be built, and a probe would itself need them.
   Cloud on a vanity domain is misclassified, so `providers.jira.flavor`
   overrides it explicitly. No flavor concept leaks above the provider boundary.

2. **ADF (Atlassian Document Format)** — *Markdown-subset conversion only.*
   Supported nodes: paragraph, text (+ marks), heading, bulletList, orderedList,
   listItem, codeBlock, blockquote, link, mention, rule, hardBreak, table.
   Anything else renders as `[Unsupported ADF node: <type>]` and the original
   remains available in `issue.raw`. Chasing complete ADF fidelity is unbounded
   work for a read-only view; this is a deliberate stop.

3. **Comment volume** — *fetch the latest 20, not all.* This is a fetch-side
   limit, not just a render-side one: pulling hundreds of comments is slow on the
   wire and bloats the cache. Configurable via `providers.<name>.comment_limit`.
   0.1 renders a `_N older comment(s) not fetched._` notice; the paginating
   `Load more comments` action is 0.3, alongside sync.

4. **URI → path escaping** — **decided, see §5.4.** RFC 3986 percent-encoding
   used verbatim as the directory name. Not hashed: the Repository must stay
   human-readable in oil.nvim, Git diffs, and grep. Locked before 0.2 because it
   becomes a breaking on-disk change afterwards.

## 24. Remaining open questions

- Whether `.state/index/` should become SQLite once cross-issue search grows
  beyond ripgrep's comfort. The `.state/` layout is designed to absorb this
  without another structural decision, so it can be deferred safely.
- FTS5 availability in the wild: some distro `sqlite3` builds omit it. The
  probe exists (§5.3) and the fallback is ripgrep, but it is worth measuring how
  often the fallback actually triggers before leaning on FTS5 in the UX.
