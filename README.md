# issuehub.nvim

[![CI](https://github.com/tya5/issuehub.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/tya5/issuehub.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Neovim 0.11+](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)

An **Issue Workspace** for Neovim: browse issue trackers through one UI, and pair
every issue with a local, Git-managed workspace of notes, metadata, and analysis.

> **Status: 0.1.0 — early.**
>
> **Works today:** four providers — Jira, Redmine, GitHub, GitLab — plus
> caching, the local index (JSON or SQLite+FTS5), the picker across all four UI
> backends, local search, and a read-only issue buffer.
>
> **Not yet:** the Workspace overlay — memo / metadata / prompt (0.2) — sync
> (0.3), collections and export (0.4), and AI backends (0.5).
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

| Provider | Hosts | Auth | ID form |
| -------- | ----- | ---- | ------- |
| `jira` | Cloud and Server/DC | API token (Basic) or PAT (Bearer) | `PROJ-123` |
| `redmine` | self-hosted | `X-Redmine-API-Key` | `12345` |
| `github` | github.com and Enterprise Server | PAT (Bearer) | `owner/repo#123` |
| `gitlab` | gitlab.com and self-managed | `PRIVATE-TOKEN` | `group/project#12` |

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

## Workspace layout

Only what belongs in Git lives at the root; everything derived is under
`.state/`, which is git-ignored automatically.

```
~/notes/issuehub/
├── .issuehub/collections/     # tracked
├── .state/                    # NOT tracked: cache, index, locks
├── jira/PROJ-123/
│   ├── memo.md                # 0.2
│   ├── metadata.yaml          # 0.2
│   └── analyses/              # 0.5
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
