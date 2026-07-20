# Providers

Each provider converts a remote payload to the canonical Issue (ONDISK §Issue)
and nothing else: no UI, no workspace access, all I/O async/returned-not-thrown.
Source: `lua/issuehub/provider/*.lua`. `provider/util.lua` holds the shared
request/pagination/limits plumbing; `provider/adf.lua` is the Jira ADF→Markdown
converter.

## Cross-cutting

**Instances vs types.** The config key is an *instance name*; `type` selects the
implementation and defaults to the key. `providers.jira` and
`providers.jira_internal = { type = "jira" }` are two independent instances. The
instance name is the URI scheme, the credential key, the network key, and the
workspace directory — so `jira://PROJ-1` and `jira_internal://PROJ-1` never
collide. A provider must **stamp the instance name** (not a hardcoded string)
as `provider` on every Issue.

**`closed` is never guessed from the status label.** Each provider reads a field
the API states outright. This is the single most important cross-provider rule.

**Auth goes in the curl config on stdin**, never argv. The Lua `HttpClient`
(`util/http.lua`) writes a curl `--config -` file. In Python you will use a real
HTTP client, but keep the invariant: no secret in argv or logs.

**Pagination** (`util/paginate` + `util/limits`): `limits(opts)` returns
`(max, per_page)` where `per_page = min(opts.per_page or 100, 100)` and
`max = opts.max_results or per_page` (so the default is **one page**). Each
provider exposes a single-page `page(query, cursor, cb)`; the loop stops at
`max`, at a short page (`#items < per_page`), or when the provider returns a nil
next-cursor. A page error keeps earlier pages (partial success). See
CORRECTNESS §Pagination.

**Comments** are capped (`comment_limit`, default 20) at fetch time, and the
provider stashes the true total in `raw.comment_total` so sync can report
`+N comments` correctly.

**`created_at` / `updated_at`** are normalised to UTC on ingest (CORRECTNESS
§Timestamps). `closed_at` is set only when closed.

## Jira

- **Flavor**: Cloud (`*.atlassian.net`) vs Server/DC, auto-detected from the
  hostname, overridable with `flavor`. Detection is a hostname heuristic, **not**
  a `/serverInfo` probe — auth style and REST version must be known before the
  first request, and a probe would itself need them.
- **REST base**: Cloud `/rest/api/3`, Server `/rest/api/2`.
- **Auth**: Cloud = HTTP Basic with `user:token` (email + API token). Server/DC =
  Bearer PAT. (`user` present + cloud ⇒ basic; else bearer.)
- **List/search**: JQL, passed through untranslated. Endpoint: Cloud
  `/search/jql`, Server `/search`. Fields requested:
  `summary,description,status,assignee,reporter,labels,created,updated,resolutiondate,project`.
- **Pagination**: Cloud uses an opaque `nextPageToken` (absent ⇒ last page);
  Server uses `startAt` (increment by page size).
- **Project**: `fields.project.key`, falling back to the key prefix
  (`PROJ-123` → `PROJ`).
- **`closed`**: `fields.status.statusCategory.key == "done"`.
- **`closed_at`**: `fields.resolutiondate`.
- **Description & comment bodies are ADF** (Atlassian Document Format, rich JSON)
  on Cloud, wiki-markup text on Server. Port `provider/adf.lua`: a Markdown-
  subset converter over the node types that actually appear (paragraph, text +
  marks, heading, lists, listItem, codeBlock, blockquote, link, mention, rule,
  hardBreak, table, emoji, inlineCard, media). Unknown node ⇒
  `[Unsupported ADF node: <type>]`. A plain string passes through unchanged, so
  the same call covers Server.
- **Comments**: separate call `/issue/<id>/comment?maxResults=<limit>&orderBy=-created`;
  `raw.comment_total = body.total`.
- **`get`**: `/issue/<id>?fields=<FIELDS>` then the comment call.

## Redmine

- **Auth**: `X-Redmine-API-Key` header.
- **Base**: the configured `url`; API paths end `.json`.
- **List**: `/issues.json` with the query as params (a table, or a
  `k=v&k=v` string parsed to one); default `{ assigned_to_id = "me", status_id = "open" }`.
- **Search**: `/search.json?q=…&issues=1&limit=100`, then re-`get` each hit
  (search returns thin records).
- **Pagination**: `offset`/`limit`.
- **`get`**: `/issues/<id>.json?include=journals`.
- **Project**: `raw.project.identifier` (or `.name`). **Redmine ids carry no
  project**, so it must come from the payload.
- **`closed`**: prefer per-issue `status.is_closed` when present; otherwise look
  it up in a map fetched **once per session** from `/issue_statuses.json`
  (`{ id → is_closed }`). Status *names* are per-instance configurable, so a
  name table would be wrong — this is exactly the guessing the core forbids.
- **`closed_at`**: `raw.closed_on`.
- **Comments**: journal entries with a non-empty `notes`; entries without a note
  are field-change audit records, not comments — skip them. Newest N kept.
- **Labels**: synthesised from `tracker.name` and `priority.name`.

## GitHub (github.com and Enterprise Server)

- **Auth**: Bearer PAT. Headers: `Accept: application/vnd.github+json`,
  `X-GitHub-Api-Version: 2022-11-28`.
- **Base**: `https://api.github.com` (default), or `https://ghe.example.com/api/v3`
  for Enterprise. Note the API host differs from the web host; `web_url` is
  derived for `html_url`-style links.
- **ID form**: repository-qualified `owner/repo#123`. **Pull requests are
  included** — GitHub numbers issues and PRs in one sequence per repo, so the id
  stays unambiguous.
- **List**: `/issues?filter=assigned&state=open` (spans all visible repos).
  **Search**: `/search/issues?q=<qualifiers>` — passed through untranslated.
- **Pagination**: `page`/`per_page`. **GitHub search refuses past 1000 results
  (422)** — stop before `(page-1)*per_page >= 1000` rather than surfacing the
  error.
- **Project**: the repository `owner/repo`, taken from `repository.full_name` or
  `repository_url` or `html_url`.
- **`closed`/status name**: issues → Open / Closed / `Closed (not planned)` (from
  `state_reason == "not_planned"`). PRs → Open / Draft / Merged / Closed.
- **PR state precedence is load-bearing — check in this order:**
  `merged_at` → `state == "closed"` → `draft` → open. **Draft is a SUB-state of
  open, not a state of its own.** Testing `draft` first reports a draft closed
  without merging as open while it still carries `closed_at` — an issue that
  contradicts itself. This wording previously said only "Draft open", which
  permitted exactly that bug; it was found against live data (cli/cli) and
  existed in the Lua reference implementation too.
- **`closed_at`**: `merged_at` (PR) else `closed_at`.
- **Comments**: `/repos/<repo>/issues/<n>/comments` — fetch the **last** page
  (`page = ceil(total/limit)`) to get the newest; `raw.comment_total = raw.comments`.

## GitLab (gitlab.com and self-managed)

- **Auth**: `PRIVATE-TOKEN` header.
- **Base**: `<root>/api/v4`.
- **ID form**: project-qualified `group/project#iid`, using the per-project
  `iid` (what the UI shows), not the global id.
- **List**: `/issues?scope=assigned_to_me&state=opened` (default).
  **Search**: `/issues?search=…&scope=all`.
- **Pagination**: `page`/`per_page`.
- **Project**: from `references.full` (`group/project#12` → `group/project`) or
  parsed from `web_url`.
- **`closed`**: `state == "closed"`; name normalised to Open/Closed (GitLab says
  "opened").
- **`closed_at`**: `raw.closed_at`.
- **Comments**: `/projects/<url-encoded-path>/issues/<iid>/notes` — the project
  path is URL-encoded into one segment (`group%2Fproject`). **Drop `system`
  notes** (audit trail). Newest N, rendered oldest-first.

## Attachments

Two shapes, and the difference is not cosmetic:

- **Jira** — `fields.attachment[]`, requested by adding `attachment` to the
  `fields` list (metadata only, no transfer). Use `content`, **not** `self`:
  the latter is the metadata resource. Carries `size` and `mimeType`.
- **Redmine** — `attachments[]`, but **only when `include=attachments` is
  passed**; without it the array is simply absent, which is indistinguishable
  from an issue that has none. Use `content_url`, `filesize`, `content_type`.
- **GitHub and GitLab have no attachment API.** An upload is a Markdown link in
  the issue body, so the body text is the only record. Consequences to preserve
  rather than paper over: size and MIME are **unknown** (nil, not guessed), and
  a hand-written link to an unrelated file on the same host is
  indistinguishable from an upload.
  - GitHub hosts: `github.com/user-attachments/assets/…`,
    `github.com/<owner>/<repo>/files/<n>/…`, `*.githubusercontent.com`.
    Asset URLs carry no filename — fall back to the link text.
  - GitLab: `/uploads/<secret>/<filename>`, written **project-relative**.
    Resolving it needs the project path from the issue's `web_url`; when that
    is unavailable, drop the attachment rather than emit a URL that would
    download the wrong project's file.
  - The URL is the only stable identity, so derive the id from it (a truncated
    hash) — it names a directory, so it must be stable across runs.
- A GitHub asset on a private repository redirects to a signed storage URL on
  another host. curl drops the Authorization header across hosts by design (it
  must not leak the token to a CDN); the signature carries the authorisation
  instead. Do not defeat this.

## Config field reference (per provider instance)

`url`, `user` (jira cloud), `token` / `token_cmd` / `token_env`, `default_query`,
`projects[]`, `default_project`, `comment_limit`, `max_results`, `per_page`,
`flavor` (jira), `web_url` (github enterprise), `http` (per-instance network
override). `url` is required for `jira`/`redmine`; `github`/`gitlab` default to
their SaaS hosts.
