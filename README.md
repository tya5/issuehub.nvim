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
> local search, bookmarks, and an issue buffer with editable memo / metadata /
> prompt written back to your Git-managed workspace.
>
> **Not yet:** sync and change detection (0.3), collections and export (0.4),
> and AI backends (0.5).
>
> The public API may break between minor versions until 1.0.
> See [DESIGN.md](DESIGN.md).

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
      jira = {
        url = "https://your-org.atlassian.net",
        user = "you@example.com",   -- Jira Cloud only
        token_env = "JIRA_TOKEN",
      },
    },
  },
}
```

No `cmd` or `event` is needed: `plugin/issuehub.lua` only registers commands and
defers every `require`, so the plugin lazy-loads itself.

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

Tokens are cached in memory for the session only, are passed to curl on **stdin**
(never argv, so `ps` cannot see them), and are unconditionally redacted from the
log file.

## Commands

```vim
:IssueHub open [uri]     " picker over the default query, or open a URI
:IssueHub search <query> " provider-side search (JQL / GitHub qualifiers / ...)
:IssueHub find <text>    " local search across the index
:IssueHub local          " everything already cached, offline
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
# PROJ-123  Timeout on cache warmup        <- read-only
- Status:   In Progress
- Assignee: tetsuya

## Description                             <- read-only
Warmup exceeds 30s when the cache is cold.

## Comments (42)                           <- read-only, folded

## Memo                                    <- editable -> memo.md
Root cause is the cold-cache path.
- [ ] confirm with staging

## Metadata                                <- editable -> metadata.yaml
priority: high
tags:
  - timeout

## Prompt                                  <- editable -> prompt.md
Summarise the likely root cause.
```

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

### Bookmarks

```vim
:IssueHub bookmark      " toggle, from inside an issue buffer
:IssueHub bookmarks     " picker over everything bookmarked
```

Bookmarks live in `state.yaml` next to your notes, so they are part of what you
commit, not derived state that a reindex can lose.

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
│   ├── prompt.md              # analysis prompt
│   ├── state.yaml             # bookmark, last-seen revision
│   └── analyses/                                            # (0.5)
└── redmine/12345/
```

Issue IDs are RFC 3986 percent-encoded for path safety, so `PROJ-123` stays
exactly that and only the rare `PROJ/123` becomes `PROJ%2F123` — the tree stays
readable in oil.nvim, `git diff`, and `grep`.

## Extending

```lua
require("issuehub.provider").register("github", my_provider)
```

A provider converts a remote payload to the canonical Issue and nothing else: no
UI, no workspace access, all I/O async, errors returned rather than thrown. See
§7 and §16 of [DESIGN.md](DESIGN.md).

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
