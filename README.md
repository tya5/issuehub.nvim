# issuehub.nvim

[![CI](https://github.com/tya5/issuehub.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/tya5/issuehub.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Neovim 0.11+](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)

An **Issue Workspace** for Neovim: browse issue trackers through one UI, and pair
every issue with a local, Git-managed workspace of notes, metadata, and analysis.

> **Status: 0.1.0 — early.**
>
> **Works today:** four providers — Jira, Redmine, GitHub, GitLab — caching, the
> local index (JSON or SQLite+FTS5), the picker across all four UI backends,
> local search, bookmarks, collections, export, sync with change detection,
> optional AI backends with saved analysis history, and an issue buffer with
> editable memo / metadata / prompt written back to your Git-managed workspace.
>
> **Not yet:** 1.0. The public API is documented and stable in intent, but is
> not frozen until a third-party provider has proven the interface.
>
> The public API may break between minor versions until 1.0.
> See [DESIGN.md](DESIGN.md).

## Using it

A walkthrough, from nothing to a workspace worth keeping.

**1. Find something to work on.**

```
<leader>ji          the provider's query, fetched now
<leader>jf          everything already local, offline
```

Both open the same picker and filter as you type. `ji` asks the server; `jf`
asks your machine and also searches what you wrote. Type `status:open`,
`priority:high`, or any word from your own notes.

**2. Open it.** `<CR>` in the picker. The issue is on top, read-only, labelled
as such. Below the divider is your workspace.

**3. Write what you learn.**

```vim
" type under ## Memo, then
:w
```

Only the files whose content changed are written, so `:w` on an unmodified
buffer produces no Git noise. Put structured facts under `## Metadata` as YAML —
`priority: high`, `tags: [timeout, cache]` — and they become filterable.

**4. Mark it.** `<leader>jm` bookmarks; `<leader>jb` lists bookmarks.

**5. Come back later.**

```vim
:IssueHub sync           " what moved on the remote?
<leader>jc               " what moved since I last looked?
```

Sync reports per issue: `PROJ-123: status Open → In Progress, +2 comments`. It
never touches your notes.

**6. Find it again**, weeks later, by something only you would remember:

```vim
:IssueHub find eviction
:IssueHub find --meta priority=high
:IssueHub find 認証
```

**7. Ask a model about it** (optional, off by default):

```
<leader>jp               conversation window, right side
:IssueHub analyze        run the prompt at the bottom
```

Answers accumulate in that window and are stored in the workspace, marked
`OUTDATED` once the issue moves on.

**8. Commit.** It is your directory:

```sh
git -C ~/notes/issuehub add -A && git -C ~/notes/issuehub commit -m "PROJ-123 notes"
```

### A big tracker

```vim
:IssueHub fetch          " page the whole server into the cache, in background
:IssueHub fetch status   " progress, or what is cached and how fresh
```

Then `<leader>jf` works entirely offline over everything you fetched.

## Why

Issues are a *source*; what you learn while working them is *knowledge*. Trackers
are good at the former and hopeless at the latter. issuehub keeps the remote
issue read-only and cached, and gives you a plain directory of Markdown next to
it that you own, diff, and commit.

## Design principles

**Zero vendor lock-in.** issuehub does not implement a picker, a git integration,
a diff viewer, a markdown renderer, or an AI client. It detects what you already
use and delegates:

| Concern | Delegated to |
| ------- | ------------ |
| Picker | snacks.picker → fzf-lua → telescope → `vim.ui.select` |
| Git | fugitive / gitsigns / the `git` CLI |
| Diff | `:diffthis` |
| Markdown | render-markdown.nvim / markview / anything |
| File explorer | oil.nvim / neo-tree / mini.files |
| Notify & input | `vim.notify` / `vim.ui.input` |

**No hard dependencies.** `dependencies = {}`. Every integration is a runtime
`pcall`. issuehub works with zero plugins installed — just less comfortably.

## Providers

| Type | Hosts | Auth | ID form |
| ---- | ----- | ---- | ------- |
| `jira` | Cloud and Server/DC | API token (Basic) or PAT (Bearer) | `PROJ-123` |
| `redmine` | self-hosted | `X-Redmine-API-Key` | `12345` |
| `github` | github.com and Enterprise Server | PAT (Bearer) | `owner/repo#123` |
| `gitlab` | gitlab.com and self-managed | `PRIVATE-TOKEN` | `group/project#12` |

Any number of instances of each type can be registered — see
[Multiple servers](#multiple-servers).

### Caching a whole tracker

```vim
:IssueHub fetch              " pick a server, or the only one
:IssueHub fetch jira_internal
:IssueHub fetch status       " progress, or what is already cached
:IssueHub fetch stop         " halt after the page in flight
:IssueHub fetch resume       " continue a partial walk
```

Pages through everything a server's query matches, **in the background**. Every
request is already async, so Neovim stays usable throughout — measured against
the real GitHub API, the event loop kept ticking while 400 issues came down over
4 pages in 5 seconds.

It is **per server**, since each is a different amount of traffic against a
different system; with several configured you are asked which.

Pages merge into the cache as they arrive, so an interrupted walk keeps what it
collected and knows where to continue. A fresh walk replaces the list, a resumed
one appends.

The **list itself** is cached separately from the issues, under `.state/lists/`,
because "which issues matched this query, and when did I last ask" is a
different fact with its own freshness:

```
issuehub cached lists:
  github        1240 issues  2h ago
  jira_internal 8300 issues  12m ago, partial
```

### Large trackers

By default a query fetches **one page** (100 issues). A backlog of twenty
thousand tickets is not pulled down by accident.

```lua
github = {
  token_cmd = { "gh", "auth", "token" },
  max_results = 500,   -- page through until this many (default: one page)
  per_page = 100,      -- page size; every provider caps this at 100
},
```

`max_results` is per provider instance, so a small internal tracker and a large
corporate one can differ. Paging stops early at a short page, and GitHub search
stops before its 1000-result ceiling rather than erroring.

For older tickets, a targeted query usually beats paging:

```vim
:IssueHub search project = PROJ AND updated >= -90d
```

Other things sized for a big tracker:

- `:IssueHub sync` with no argument asks for confirmation above
  `sync.confirm_above` (default 200), because it is one request per issue.
- Cache and index writes skip `fsync` — `.state/` is rebuildable by design, and
  the durability was costing more than it bought.
- A bulk fetch writes the index once rather than once per issue.

### Multiple servers

The config key is an **instance name**, and `type` selects the implementation.
It defaults to the key, so `jira = { … }` needs no `type` — but any number of
instances of the same tracker can coexist:

```lua
providers = {
  jira = {                       -- type defaults to "jira"
    url = "https://your-org.atlassian.net",
    user = "you@example.com",
    token_env = "JIRA_CLOUD_TOKEN",
  },
  jira_internal = {
    type = "jira",               -- a second Jira, self-hosted
    url = "https://jira.internal.example",
    token_env = "JIRA_INTERNAL_TOKEN",
    http = { no_proxy = "*" },   -- reachable directly, unlike the SaaS one
  },
  gitlab_saas = { type = "gitlab", token_env = "GITLAB_COM_TOKEN" },
  gitlab_internal = {
    type = "gitlab",
    url = "https://gitlab.internal.example",
    token_env = "GITLAB_INTERNAL_TOKEN",
  },
}
```

The instance name becomes the URI scheme and the workspace directory, so the
same issue key on two servers never collides:

```
jira://PROJ-123            →  workspace/jira/PROJ-123/
jira_internal://PROJ-123   →  workspace/jira_internal/PROJ-123/
```

Each instance has its own credential, its own default query, and its own network
settings. `:IssueHub open` prompts for the instance when more than one is
configured.

### Issue IDs

GitHub and GitLab IDs are repository-qualified so one workspace can span many
repositories. They are percent-encoded on disk
(`github/owner%2Frepo%23123/`) — which is exactly why paths are RFC 3986 encoded.

GitHub pull requests are included alongside issues; GitHub numbers both in one
sequence per repository, so `owner/repo#123` stays unambiguous. Their status
reads `Open`, `Draft`, `Merged`, or `Closed`.

`closed` is always taken from what the API states, never guessed from a status
label: Jira's `statusCategory`, Redmine's `/issue_statuses.json`, and the
`state` field on GitHub and GitLab.

## Requirements

- Neovim **0.11+** (0.12 recommended)
- `curl` (required)
- `git`, `ripgrep`, `sqlite3` (recommended)
- A Level 1 picker — [snacks.nvim](https://github.com/folke/snacks.nvim),
  [fzf-lua](https://github.com/ibhagwan/fzf-lua), or
  [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — strongly
  recommended; see [Picker tiers](#picker-tiers).

## Install

<details open>
<summary><a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></summary>

```lua
{
  "tya5/issuehub.nvim",
  opts = {
    workspace = "~/notes/issuehub",
    providers = {
      github = {
        -- Reuses your existing `gh` login; no token stored anywhere.
        token_cmd = { "gh", "auth", "token" },
        default_query = "is:issue is:open involves:@me",
      },
    },
  },
}
```

No `cmd` or `event` is needed: `plugin/issuehub.lua` only registers commands and
defers every `require`, so loading it costs practically nothing and lazy.nvim
treats a spec like the one above as eager.

> **If you add `keys`, add `lazy = false` too.**
>
> ```lua
> {
>   "tya5/issuehub.nvim",
>   lazy = false,                     -- ← required once `keys` is present
>   keys = { { "<leader>ji", "<Plug>(IssueHubOpen)", desc = "Issues" } },
>   opts = { ... },
> }
> ```
>
> Specifying `keys` (or `cmd`/`event`/`ft`) switches lazy.nvim into deferred
> mode for the whole plugin, so `:IssueHub` would not exist and
> `:checkhealth issuehub` would report *"No healthcheck found"* until you first
> pressed one of those keys. `lazy = false` avoids that at no real cost, because
> the startup file requires nothing.

<details>
<summary>Full example: LazyVim, GitHub via <code>gh</code>, with keymaps</summary>

```lua
return {
  {
    "tya5/issuehub.nvim",
    lazy = false,
    opts = {
      workspace = "~/notes/issuehub",
      providers = {
        github = {
          token_cmd = { "gh", "auth", "token" },
          default_query = "is:issue is:open involves:@me",
        },
      },
    },
    keys = {
      { "<leader>ji", "<Plug>(IssueHubOpen)", desc = "Issues (issuehub)" },
      { "<leader>jf", "<Plug>(IssueHubFind)", desc = "Find in issue notes" },
      { "<leader>jr", "<Plug>(IssueHubRefresh)", desc = "Refresh issue" },
      { "<leader>jb", "<cmd>IssueHub bookmarks<cr>", desc = "Bookmarked issues" },
      { "<leader>jc", "<cmd>IssueHub changed<cr>", desc = "Changed since last seen" },
    },
  },
  {
    "folke/which-key.nvim",
    optional = true,
    opts = { spec = { { "<leader>j", group = "issues" } } },
  },
}
```

</details>

### After installing

```vim
:checkhealth issuehub
```

Everything should be green except a note that your workspace is not a Git
repository. It works either way, but the whole point is that your notes are
committable:

```sh
git -C ~/notes/issuehub init
```

</details>

<details>
<summary><a href="https://neovim.io/doc/user/pack.html">vim.pack</a> (Neovim 0.12+)</summary>

```lua
vim.pack.add({ "https://github.com/tya5/issuehub.nvim" })
require("issuehub").setup({ workspace = "~/notes/issuehub", ... })
```

</details>

## Configuration

```lua
require("issuehub").setup({
  -- REQUIRED. A Git-managed knowledge base; there is deliberately no default.
  workspace = "~/notes/issuehub",

  index = "auto", -- "auto" | "json" | "sqlite"

  providers = {
    jira = {
      url = "https://your-org.atlassian.net",
      user = "you@example.com",       -- Jira Cloud only
      token_env = "JIRA_TOKEN",       -- or token_cmd / token
      default_query = "assignee = currentUser() AND resolution = Unresolved",
      comment_limit = 20,
      -- Detected from the hostname (*.atlassian.net => cloud). Set explicitly
      -- for Cloud on a vanity domain.
      -- flavor = "cloud",
    },

    redmine = {
      url = "https://redmine.example.com",
      token_env = "REDMINE_API_KEY",
      default_query = { assigned_to_id = "me", status_id = "open" },
    },

    github = {
      -- url defaults to https://api.github.com
      -- Enterprise Server: url = "https://ghe.example.com/api/v3"
      token_env = "GITHUB_TOKEN",
      default_query = "is:open assignee:@me",   -- GitHub search syntax
    },

    gitlab = {
      -- url defaults to https://gitlab.com (self-managed: your instance root)
      token_env = "GITLAB_TOKEN",
      default_query = { scope = "assigned_to_me", state = "opened" },
    },
  },

  ui = { picker = "auto" },           -- "auto"|"snacks"|"fzf"|"telescope"|"select"
  sync = { on_open = "stale", stale_after = 900 },
  export = { dir = nil, default_format = "markdown" },   -- dir defaults to cwd

  backend = "none",                   -- "none" | "a2a" | your own
  backends = {},
  log_level = vim.log.levels.WARN,
})
```

`workspace` is genuinely required — `setup()` reports an error if it is missing,
rather than failing later. Keys belonging to unreleased milestones (`backend`,
`export`) are rejected rather than silently ignored.

### Corporate networks

Behind a proxy, a TLS-inspecting gateway, or both? Everything below is optional —
with no `http` block, curl already honours `http_proxy`, `https_proxy`, and
`no_proxy` from your environment, which is what most managed machines set.

```lua
require("issuehub").setup({
  workspace = "~/notes/issuehub",

  http = {
    -- Proxy. Omit to use the environment; set to override it.
    proxy = "http://proxy.corp.example:8080",
    no_proxy = "localhost,127.0.0.1,.internal.example",

    -- Authenticating proxy. The password is a credential: keep it out of
    -- your config the same way you keep tokens out.
    proxy_user = "DOMAIN\\you",
    proxy_password_env = "PROXY_PASSWORD",     -- or proxy_password_cmd
    proxy_auth = "ntlm",                        -- basic|digest|ntlm|negotiate|anyauth

    -- TLS inspection: trust your organisation's root, do NOT disable checking.
    cacert = "~/certs/corporate-root.pem",

    -- Mutual TLS, if your gateway requires a client certificate.
    client_cert = "~/certs/client.pem",
    client_key = "~/certs/client.key",
    client_key_password_env = "CLIENT_KEY_PASSWORD",

    timeout = 30000,
    retries = 2,
  },
})
```

**Per-provider overrides.** An internal tracker reached directly while SaaS goes
through the proxy is the common mixed case:

```lua
providers = {
  jira = { url = "https://your-org.atlassian.net", token_env = "JIRA_TOKEN" },
  redmine = {
    url = "https://redmine.internal",
    token_env = "REDMINE_API_KEY",
    http = { no_proxy = "*" },   -- bypass the proxy for this host only
  },
}
```

#### TLS interception

If your company inspects TLS, requests fail with a certificate error. There are
two ways out, and they are not equivalent:

```lua
http = { cacert = "~/certs/corporate-root.pem" }   -- correct
http = { ssl_verify = false }                       -- last resort
```

`ssl_verify = false` disables certificate verification **entirely**: your API
tokens travel over a connection nobody is checking. issuehub accepts it, because
some internal CAs genuinely cannot be exported, but it will log a warning and
`:checkhealth issuehub` reports it as an **error** for as long as it is on. Treat
it as a temporary state, not a setup step.

To find your root certificate:

```sh
# macOS: export from the System keychain
security find-certificate -a -c "Your Corp Root" -p \
  /Library/Keychains/System.keychain > ~/certs/corporate-root.pem

# Linux: it is usually already installed
ls /etc/ssl/certs/ca-certificates.crt
```

#### Checking it works

```vim
:checkhealth issuehub
```

The **Network** section shows the effective proxy (with any password stripped),
whether a custom CA is in use, the mTLS state, and `ssl_verify`. Per-provider
overrides are listed separately, since those are easy to forget about.

### Credentials

Never put a token in your config file. Resolution order:

```lua
token = function() ... end                      -- 1. escape hatch
token_cmd = { "op", "read", "op://vault/jira" } -- 2. password manager
token_env = "JIRA_TOKEN"                        -- 3. environment
```

For GitHub, `token_cmd = { "gh", "auth", "token" }` reuses the login you already
have and stores nothing. For GitLab, `glab auth token` does the same.

Tokens are cached in memory for the session only, are passed to curl on **stdin**
(never argv, so `ps` cannot see them), and are unconditionally redacted from the
log file.

## Commands

```vim
:IssueHub open [uri]     " picker over the default query, or open a URI
:IssueHub search <query> " provider-side search (JQL / GitHub qualifiers / ...)
:IssueHub find <text>    " local search; --regex forces the ripgrep path
:IssueHub local          " everything already cached, offline
:IssueHub sync [target]  " re-fetch and report what changed
:IssueHub changed        " issues that moved since you last opened them
:IssueHub collection ... " manage and open collections
:IssueHub export [fmt] [source]
:IssueHub analyze        " analyse via the configured backend
:IssueHub analyses       " analysis history for the current issue
:IssueHub refresh        " re-fetch the current issue buffer
:IssueHub bookmark       " toggle a bookmark on the current issue
:IssueHub bookmarks      " picker over bookmarked issues
:IssueHub reindex        " rebuild the index from cache
:IssueHub provider list
:IssueHub health
```

No keymaps are created. Bind the `<Plug>` maps yourself:

```lua
vim.keymap.set("n", "<leader>ji", "<Plug>(IssueHubOpen)")
vim.keymap.set("n", "<leader>jf", "<Plug>(IssueHubFind)")
vim.keymap.set("n", "<leader>jr", "<Plug>(IssueHubRefresh)")
```

## Picker tiers

| Tier | Backend | |
| ---- | ------- | - |
| **Primary** | snacks.picker | reference implementation |
| **Secondary** | fzf-lua | fully supported |
| **Compatible** | telescope | works; upstream is in maintenance mode |
| **Fallback** | `vim.ui.select` | single column, no preview, no multi-select |

The fallback guarantees issuehub *functions* with zero plugins. It is not a
target for feature parity, and browsing issues through it is genuinely worse.

## The issue buffer

Opening an issue gives you one Markdown buffer: the issue on top (read-only,
from cache) and your own notes below (editable, stored in your workspace).

```markdown
# PROJ-123  Timeout on cache warmup
- Status:   In Progress
- Analysis: 2026-07-19T11-17-00Z (outdated)

## Description                                    read-only
Warmup exceeds 30s when the cache is cold.

## Comments (42)                                  read-only

────────────────────────────── your workspace below
## Memo                                editable → memo.md
Root cause is the cold-cache path.
- [ ] confirm with staging

## Metadata                       editable → metadata.yaml
priority: high
```

The labels on the right and the divider are virtual text — they are markers, not
part of the file. Editing above the divider is reverted, so it is worth seeing
the boundary rather than discovering it.

`:w` writes the three editable sections to their files — and only the ones whose
content actually changed, so you do not get empty commits. Emptying a section
deletes its file rather than leaving a stub.

It is plain Markdown, so Treesitter, folding, `/`, marks, and any markdown
renderer you already use work unmodified. issuehub implements no editor.

**Read-only is advisory.** Neovim has no way to lock part of a buffer, so edits
above the `## Memo` heading are *reverted* with a warning rather than prevented.
Anything you typed in the editable sections is kept.

**metadata.yaml is written back verbatim.** Comments, key order, and spacing
survive exactly as you typed them — issuehub parses that file for search and
export, but never reformats it.

### Two pickers, one shape

`<Plug>(IssueHubOpen)` and `<Plug>(IssueHubFind)` behave identically: the picker
opens straight away and typing filters it. Only the corpus differs.

| | Corpus | Typing filters over |
| --- | --- | --- |
| `IssueHubOpen` | the provider's query, fetched now | ID, status, title, and your notes |
| `IssueHubFind` | everything already local, offline | the same |

Your memo and metadata ride along on each row as hidden match text, so typing
`認証` finds an issue whose *notes* mention it even though nothing on screen
does. Nothing is fetched, and no prompt appears.

Metadata **and the issue's own fields** are folded in as `key:value` tokens, so
you can filter structurally right in the picker — and `status:` behaves exactly
like `priority:`, because when you are filtering you have no reason to care
which of them came from the tracker and which you typed:

```
status:open              from the tracker
state:closed             normalised open/closed, whatever the tracker calls it
provider:github          which instance it came from
assignee:tya5
bookmarked:true
priority:high            from your metadata.yaml
tags:cache               a value inside a YAML list
status:open priority:high   both (most pickers treat a space as AND)
```

The same names work in the exact form:

```vim
:IssueHub find --meta state=open --meta priority=high
:IssueHub find --meta status=in-progress
:IssueHub find --meta labels=cache
```

> Picker filtering is substring matching, so `priority:high` also matches
> `priority:highest`. Use `--meta` when you need an exact comparison — it parses
> the YAML rather than the text, and reaches analysis history and regexes a
> picker filter cannot.
>
> If you write a key that collides with a built-in one — say `status: waiting`
> in your metadata — **yours wins**. The workspace is yours, and a status you set
> deliberately should not be shadowed by the tracker's.

### Searching your notes

```vim
:IssueHub find eviction              " ranked full-text across everything local
:IssueHub find "cache.warm"          " a fixed string, not a pattern
:IssueHub find --regex cache.*       " forces the ripgrep path

:IssueHub find --meta priority=high  " filter by metadata
:IssueHub find --meta owner          " issues where the key is set at all
:IssueHub find --meta tags=cache     " matches a value inside a YAML list
:IssueHub find eviction --meta priority=high    " text AND filter
```

Filters are ANDed, values are case-insensitive, and the same syntax works in the
`<Plug>(IssueHubFind)` prompt — one parser serves both, so they cannot drift.

`find` searches the cached issue **and everything you wrote about it** — memo,
metadata, and analysis history — and tells you which of those matched:

```
  PROJ-123  In Progress  2026-07-19  Timeout on cache warmup   [memo]
  PROJ-140  Open         2026-07-18  Retry storm on failover   [analyses]
```

Two engines, chosen automatically:

| Query | Engine | Why |
| ----- | ------ | --- |
| ASCII, with sqlite3 + FTS5 | SQLite FTS5 | ranked by relevance |
| Non-ASCII (Japanese, Chinese, Thai …) | ripgrep | see below |
| `--regex` | ripgrep | FTS5 cannot do it |
| No FTS5 | ripgrep | |
| Neither available | index substring scan | incomplete; warns |

They are complementary rather than redundant: FTS5 ranks whole documents by
relevance, which suits an accumulating knowledge base; ripgrep finds exact lines
and regexes.

> **Why non-ASCII goes to ripgrep.** FTS5's `unicode61` tokenizer splits on
> whitespace, so a run of Japanese becomes a *single token* —
> `認証まわりの調査メモ` is one term, and searching `認証` matches nothing. The
> `trigram` tokenizer fixes 3-character queries but still fails on 2-character
> ones, which is the most common Japanese word length. ripgrep handles all of
> it, so those queries are routed there. Install ripgrep if you write notes in
> a language without spaces.

### Collections and export

Collections are local, static, cross-provider lists — a sprint, a release, an
investigation. They live in `.issuehub/collections/<slug>.yaml` and are committed
with the rest of your workspace.

```vim
:IssueHub collection add Sprint A   " add the current issue (or picker selection)
:IssueHub collection Sprint A       " open it in the picker
:IssueHub collection list
:IssueHub collection remove Sprint A
```

They are deliberately **static lists, not saved queries**: a list diffs cleanly
in Git, and "why is this issue in here" always has a literal answer.

```vim
:IssueHub export                    " current view, default format
:IssueHub export csv sprint-a       " a collection, as CSV
:IssueHub export json bookmarks
:IssueHub export markdown changed
```

Sources are a collection name or one of `local`, `all`, `bookmarks`, `changed`.
With no source, export acts on **what you were just looking at** — the last view
the picker showed.

Output combines the latest *cached* issue with your workspace overlay:
metadata keys are flattened to `meta.<key>`, multi-value fields join with `; `,
and `fetched_at` is included so staleness travels with the data. Export performs
no network I/O — run `:IssueHub sync` first if freshness matters.

Markdown export keeps memos as prose under a `## Notes` heading rather than
cramming multi-line text into table cells.

Add your own format:

```lua
require("issuehub.core.export").register("xlsx", { ext = "xlsx", write = fn })
```

### Staying current

```vim
:IssueHub sync            " re-fetch everything you have locally
:IssueHub sync jira       " just one provider instance
:IssueHub sync <uri>      " just one issue
:IssueHub changed         " picker over what moved since you last looked
```

Sync reports what actually moved, per issue:

```
issuehub: 3 changed, 27 unchanged
  PROJ-123: status Open → In Progress, assignee, +2 comments
  PROJ-140: description
  12345: status New → Closed
```

**Sync never touches your notes.** It refreshes the cache and nothing else — a
remote edit cannot rewrite what you wrote.

Two different questions are answered separately:

- *What just moved?* — the report above, from comparing the fetched issue against
  the cached one.
- *What moved since I last looked?* — `:IssueHub changed`, and a `Changed:` line
  in the issue header. This is derived from `state.yaml`, so it survives
  restarts, accumulates across syncs, and clears when you actually open the
  issue — not when a sync happens to run.

Sync targets everything cached **plus anything with local notes**, so an issue
you annotated months ago is still tracked even if it fell out of the cache.

### The conversation window

```vim
:IssueHub prompt        " opens a window on the right
```

The prompt is **not** in the issue buffer. It lives in a side window with the
whole conversation for that issue — every past prompt and response, oldest
first, with the next prompt at the bottom:

```markdown
# Conversation — jira://PROJ-123

### 2026-07-19T11:17:00Z  ·  claude-opus-4-8  ·  OUTDATED

> What is the root cause?

The connection pool saturates before the cache fills.

────────────────────────────── next turn
## Prompt              editable → prompt.md
```

`:w` writes `prompt.md`, `:IssueHub analyze` runs it, and the answer appears in
the same window. A prompt is one turn of a conversation and you write the next
one by reading the previous answers — which is awkward when the prompt sits
between memo and metadata and the answers live somewhere else entirely.

### Bookmarks

```vim
:IssueHub bookmark      " toggle, from inside an issue buffer
:IssueHub bookmarks     " picker over everything bookmarked
```

Bookmarks live in `state.yaml` next to your notes, so they are part of what you
commit, not derived state that a reindex can lose.

## AI backends (optional)

**issuehub has no AI of its own.** A Backend is the only channel through which
anything leaves your machine, and the default is `none`: nothing is sent
anywhere unless you configure it.

```lua
backend = "a2a",
backends = {
  a2a = { url = "http://localhost:9100", token_env = "A2A_TOKEN" },
},
```

```vim
:IssueHub analyze        " analyse the current issue, save the result
:IssueHub analyses       " browse this issue's analysis history
```

The request carries the cached issue plus your workspace overlay, and the prompt
comes from the issue's own `prompt.md` when you have written one — otherwise a
sensible default.

### Analysis history and staleness

Every analysis is kept under `analyses/<timestamp>/` with its prompt, its
response, and the issue revision it was made against.

**Staleness is derived, never stored.** An analysis is `current` when the
recorded revision matches the cached issue and `outdated` otherwise — so it
cannot go wrong after a manual edit, a `git revert`, or a sync that happened
while Neovim was closed. The issue header shows it:

```
- Analysis: 2026-07-19T11-17-00Z (outdated)
```

An outdated analysis is also never fed back in as context for a new one, since
that would propagate its staleness.

### Writing your own backend

The interface anticipates more than issue analysis. Requests carry a **kind**,
and a backend advertises which kinds it handles — so an LLM client slots in
without the interface moving:

```lua
require("issuehub.backend").register("my-llm", {
  name = "my-llm",
  setup = function(self, opts) return true end,
  capabilities = function()
    return { kinds = { "analyze", "complete" }, streaming = true, models = { "..." } }
  end,
  discover = function(self, cb) cb(nil, self:capabilities()) end,
  health = function() return true, "ready" end,
  send = function(self, req, opts, cb)
    -- req.kind, req.prompt, req.context.{issue,overlay,selection,documents}
    -- opts.on_chunk(text) for streaming; call cb(nil, { text = ..., model = ... })
  end,
})
```

Free-form completion is reachable through the same interface:

```lua
require("issuehub.backend").complete("Draft a release note.", {}, function(err, res)
  print(res.text)
end)
```

Nothing in issuehub calls `complete()` yet — it exists so an LLM backend can be
dropped in and driven by your own code, or by a future feature, without the
contract changing. Requests of a kind the backend does not advertise are refused
with a clear message rather than sent and misunderstood.

> The bundled A2A backend is written against the JSON-RPC `message/send` shape
> with agent-card discovery, but has **not been exercised against a live agent**.
> Treat it as a starting point and please report mismatches.

## Workspace layout

Only what belongs in Git lives at the root; everything derived is under
`.state/`, which is git-ignored automatically.

```
~/notes/issuehub/
├── .issuehub/collections/     # tracked                     (0.4)
├── .state/                    # NOT tracked: cache, index, locks
├── jira/PROJ-123/
│   ├── memo.md                # your notes
│   ├── metadata.yaml          # free-form key/value
│   ├── prompt.md              # the next prompt (conversation window)
│   ├── state.yaml             # bookmark, last-seen revision
│   └── analyses/
│       └── 2026-07-19T11-17-00Z/  # prompt.md, response.md, metadata.yaml
└── redmine/12345/
```

Issue IDs are RFC 3986 percent-encoded for path safety, so `PROJ-123` stays
exactly that and only the rare `PROJ/123` becomes `PROJ%2F123` — the tree stays
readable in oil.nvim, `git diff`, and `grep`.

## Documentation

```vim
:help issuehub
```

The help file is the reference: every option, command, and public API function,
plus the extension guide. This README is the tour.

## Extending

issuehub is meant to be extended from outside. Four registries are public:

```lua
require("issuehub.provider").register("mytracker", provider)   -- a tracker
require("issuehub.backend").register("my-llm", backend)        -- an agent/model
require("issuehub.core.export").register("xlsx", exporter)     -- a format
-- picker adapters: implement pick(view, opts) + three capability flags
```

A provider converts a remote payload to the canonical Issue and nothing else: no
UI, no workspace access, all I/O async, errors returned rather than thrown.
Backend requests carry a `kind`, so an LLM client slots in without the interface
moving. See `:help issuehub-extending` and §7 / §16 of
[DESIGN.md](DESIGN.md).

### What is public

`:help issuehub-api` lists the public surface. Anything not listed there is
internal and may change without notice — that boundary is what will be frozen
at 1.0.

## Security

issuehub handles API tokens. They never reach argv, a log file, or disk — see
[SECURITY.md](SECURITY.md) for the specifics and for what the cache *does* store
in plain text.

## Contributing

Issues and PRs welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and
[DESIGN.md](DESIGN.md) first — the architecture has a few load-bearing
constraints (no hard dependencies, no cross-provider workflow enum) that a PR can
accidentally break.

```sh
nvim -l spec/runner.lua   # run the specs; no toolchain needed
stylua lua plugin ftplugin spec
```

## License

[MIT](LICENSE) © tya5
