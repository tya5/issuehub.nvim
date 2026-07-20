# The correctness ledger

The real cost of this rewrite is not typing — it is silently re-introducing bugs
that are already fixed. Every item below was hit during development, usually by
running the thing rather than by testing. **Port each as a test in the Python
suite.** They are the difference between a port and a regression.

## Credentials

- **Never in argv.** Tokens, proxy passwords, and client-key passphrases reach
  curl through a config file on stdin. `ps` must not see them. In Python, use a
  client that takes auth via headers/session, not a shelled-out argv.
- **Never in logs.** The Lua logger redacts unconditionally: `Authorization`
  headers, `user = "x:secret"`, `token=…`, `api_key=…`. Redaction with a regex
  that captures `(prefix)(secret)` and re-emits only the prefix — a gsub that
  replaced the whole match once ate the `Authorization:` prefix too. Test that a
  known secret does not appear in the log.
- **A literal string secret must be accepted.** An early resolver only accepted
  a function / `*_cmd` / `*_env` and dropped a literal `proxy_password = "..."`.
  curl then prompted for the password interactively, which **hangs a headless
  process**. Resolution order: literal > cmd > env. Also: a proxy user with no
  resolved password must emit `user:` (empty password), not a bare `user`, for
  the same prompt-hang reason.
- **Health reports resolvability, never the value** ("resolved (40 characters)").

## Cross-provider invariants

- **`closed_at` exists only when `status.closed`.** Enforce it in the canonical
  normaliser, not per provider: trackers disagree about clearing their
  resolution timestamp on reopen (Jira `resolutiondate`, Redmine `closed_on` can
  persist), and a status-ordering bug produces the same contradiction. Found
  live on GitHub — a draft PR closed without merging read as open *and* carried
  `closed_at`. An open issue with a resolution timestamp silently corrupts any
  duration analysis built on those two columns, so this is a data-integrity
  invariant, not a tidiness one. Test it parameterised over every provider so a
  fifth one inherits the check.
- **PR/issue state precedence** (GitHub): `merged_at` → closed → draft → open.
  See PROVIDERS.md.

## Timestamps

- Normalise every provider timestamp to `YYYY-MM-DDTHH:MM:SSZ` UTC on ingest.
  Jira Cloud emits `+0900` offsets, Redmine emits `Z`. The index sorts these
  lexicographically, so an un-normalised offset sorts wrong. A string that does
  not parse passes through unchanged (don't crash on junk); empty → `""`.

## Partial cache

- `list`/`search` return issues with **no description or comments**; they are
  cached as `partial: true`. Two invariants:
  1. A partial write must **not** overwrite a complete entry's `description`/
     `comments` — merge, keeping the complete fields. (Symptom when wrong: open
     an issue from the picker and its description is permanently blank.)
  2. A partial entry is **always stale** regardless of `fetched_at`, so opening
     it triggers a real `get`.
  3. **Sync must not compare a partial baseline's absent fields.** `description`
     is empty in a partial, so comparing it reports the entry *filling in* as a
     change — every issue at once, on the first sync after a fetch (measured
     live: 100 changed on the first run, 0 on the second). Since `fetch` is the
     intended way to populate the cache, this makes the feature meaningless the
     first time a user reaches for it. Skip only the fields a partial cannot
     hold (`description`, and the comment delta); keep comparing `status`,
     `assignee`, `title`, and `labels`, which a partial *does* carry — otherwise
     a genuine status change between the list and the sync is silently lost.
     Discarding the whole baseline avoids the false positives and causes that
     second bug; the Lua reference had exactly that weaker behaviour until the
     Python port surfaced it.

## Change detection (sync)

- Compare the watched fields **directly** — `status.name`, `assignee`, `title`,
  `description`, `labels` — not a content hash. The report has to say *what*
  moved, so the comparison happens anyway; a hash is a second mechanism answering
  a weaker question. `updated_at` is used for "have I seen this revision", not
  for detecting change.
- Comment delta uses `raw.comment_total`, not `len(comments)` — the fetched list
  is capped, so its length understates the change. Never report *removed*
  comments as added (clamp at 0).
- A **first sighting is not a change** (old == nil ⇒ no change).
- **Sync never mutates the workspace overlay.** Only the cache and `state.yaml`.
  There is a test asserting exactly this; keep it.

## Sync targets

- Default targets = everything cached **plus** everything with a workspace
  directory (notes), deduplicated. An issue annotated months ago that fell out of
  the cache is still synced. `fetch` is per query; `sync` is per known-issue.

## Changed-since-seen

- Derived from `state.yaml.last_seen_updated_at` vs the cached `updated_at`.
  Survives restarts, accumulates across syncs, and clears when the issue is
  **opened** (touched), not when a sync runs. Mirror the marker into the index
  (`seen_at`) so listing changed issues is a filter, not a directory walk. A
  rebuild must recover `seen_at` from `state.yaml`.

## Search routing

- FTS5's `unicode61` tokeniser splits on whitespace, so a run of Japanese is
  **one token** — `認証まわりの調査メモ` indexed whole, and searching `認証`
  matches nothing (an empty result, not an error — the worst kind). The `trigram`
  tokeniser fixes 3-char queries but not 2-char, the most common Japanese word
  length. **Route non-ASCII queries to ripgrep**, which handles all of it. Also
  ripgrep for `--regex`. FTS5 for ASCII when available; else ripgrep; else a
  substring scan of the index.
- ripgrep must search `.state/` too: it is a dot-dir *and* git-ignored, so
  ripgrep skips it by default — pass `--hidden --no-ignore-vcs` (still exclude
  `.git/`). Symptom when wrong: cached issue bodies are silently unsearchable.
- Search results report **which field matched** (`memo`/`metadata`/`analyses`/
  `issue`). For FTS, per-column attribution via `snippet()` markers is
  **build-dependent** (worked on macOS sqlite3, produced no markers on the CI
  runner). Use `instr()` over the FTS columns instead — exact, portable.

## Filtering

- `--meta k=v` compares case-insensitively and treats spaces/underscores as
  hyphens, so `status=in-progress` and `"status=In Progress"` both match. `--meta
  k` (no value) is a presence test. A list value (`tags: [a,b]`) matches
  `tags=a`. Built-in keys (`status`, `state`, `provider`, `project`, `assignee`,
  `bookmarked`, `labels`) filter alongside metadata; **metadata the user wrote
  wins** over a built-in of the same name.
- `state` is normalised open/closed; `status` is the provider's wording.

## Pagination

- Default is **one page** — never pull a 20k backlog by accident. `max_results`
  opts in.
- Stop at a short page (`< per_page`) without asking for one more; keep partial
  results if a later page errors; GitHub search stops before its 1000 ceiling.
- `fetch` flushes the list cache **per page**, so a killed process keeps its
  progress and `--resume` continues from the persisted cursor.

## Index is derived

- Deleting `.state/` must be safe: `reindex` rebuilds from the cache, and must
  recover `bookmarked` and `seen_at` from `state.yaml` (they are user data, not
  payload). On a normal `put`, never overwrite `bookmarked`/`seen_at` with
  payload — only the payload columns.
- Bulk writes go through one batched transaction, not one process/statement per
  issue (that turned a large sync into thousands of `sqlite3` spawns). Escaping
  is by a single total quote function (quote-doubling, NUL-strip) since the
  sqlite3 CLI has no bind — in Python with the `sqlite3` module, use real bound
  parameters and this whole class of concern disappears; just keep the file/schema
  identical.

## Merged export

- `all` and `provider[/project]` sources export the **union** of cache and
  workspace. An issue known only by its notes (no cache entry) still produces a
  row, with issue columns blank and `memo`/metadata present. A project filter
  can only apply to something with a payload.

## Import (merge)

- **Asymmetric with export on purpose.** Only `memo`, `meta.*`, `bookmarked`
  come back. Issue columns (`title`, `status`, `closed`, dates, `assignee`, …)
  are parsed and thrown away — the tracker owns them, and a two-week-old
  spreadsheet must never overwrite the cache with fiction. A port that
  "helpfully" restores them corrupts the cache in a way sync cannot detect,
  because the file looks freshly written.
- **Absent column ≠ empty cell.** An absent column means "not in this file,
  leave it alone"; an empty cell means "clear it". Collapsing the two wipes
  memos on any partial-column import.
- Metadata merges **key-wise into the existing parsed metadata**, so keys the
  import does not mention survive. The consequence: `metadata.yaml` is normally
  written back verbatim to preserve comments and key order, but an import
  regenerates it from the merged key set, so **comments in that file are lost**.
  Report the affected URIs (`metadata_comments`) rather than losing them
  quietly.
- `bookmarked` is tri-state on the way in: **absent column** = leave it alone,
  `false`/`no`/`0`/empty = **clear the bookmark**, `true`/`yes`/`1` = set it.
  Unrecognised text is the only other "leave it alone". Clearing must reach both
  `state.yaml` and the index. (The Lua side had this wrong: `present and
  to_boolean(x) or nil` collapses `false` into `nil`, so a bookmark could be set
  from a spreadsheet but never removed — and no test observing only true values
  would catch it. Corpus:
  `import_merge_bookmarked_false_clears_bookmark`.)
- Export's flattening is reversed on the way in: a cell containing `; ` becomes
  a list again.
- **The file wins on conflict, with no per-row prompt**, justified only by the
  workspace being Git-managed. Therefore: report every overwrite by URI and
  field, support `--dry-run`, and report whether the workspace is actually a Git
  repo.
- A row whose `uri` is not a valid issue URI is skipped and reported, not
  silently dropped. A file that yields zero importable rows is an error, not a
  no-op success.
- Rows for issues with no local content yet create it — import is not restricted
  to issues you have already annotated.
- The CSV reader must handle everything the writer emits: quoted fields with
  embedded commas, **embedded newlines** (multi-line memos are the common case),
  and doubled quotes. A trailing newline must not produce a final empty record.
- **Round-trip invariant, held in the corpus — conditional on `metadata.yaml`
  being canonical.** Exporting a subject and immediately importing that same
  file back changes nothing — every row `unchanged`, zero `imported` — **when
  the existing `metadata.yaml` is absent, or already in the canonical
  (sorted-key, comment-free) form** the previous bullet describes. That
  precondition is the normal case for a file `import` never touched, but not a
  given in general: `metadata.yaml` is otherwise written back verbatim
  specifically so a human can hand-edit key order and leave comments in it, and
  `import` regenerates the file from the merged key set — sorted, comment-free —
  every time. So a non-canonical `metadata.yaml` legitimately reports a change
  on re-import: `overwritten` on `metadata` when only key order moved, plus
  `metadata_comments` when a comment would be dropped. This is not a defect in
  the invariant — reporting `unchanged` for a write that would silently discard
  a comment or reorder keys would be the actual bug; the invariant holds exactly
  where nothing about the file *would* change, and reports honestly everywhere
  else. Corpus: `import_merge_export_then_import_is_a_no_op`,
  `import_merge_metadata_key_reorder_counts_as_overwrite`,
  `import_merge_metadata_comment_loss_reported`.

## Attachments

- Metadata travels with the Issue; **bytes are fetched only on an explicit
  request**, and are stored under `.state/` (never the workspace). Both rules
  are in ONDISK §Attachments with the reasoning.
- An entry missing any of id / filename / URL is dropped at normalisation:
  listing something that cannot then be downloaded is worse than not listing
  it.
- Corpus-worthy cases, because each is a silent-corruption class rather than a
  visible error: a filename that escapes its directory; two attachments sharing
  a filename; a binary body round-tripped through the response path; an
  interrupted download left in place; an unauthenticated fetch saving a login
  page as a PDF.

## Repository / paths

- Case-collision guard (above, ONDISK §URI). Percent-encode ids verbatim into
  path segments; never hash. `.gitignore` must list `/.state/` or derived data
  gets committed (health warns if not).
- Writes are atomic (temp + rename). Cache/index/list writes skip fsync (derived,
  rebuildable); overlay/state writes keep it (user data). The atomicity is from
  rename, not fsync, so a killed process never leaves a half-file.

## Collections

- v2 directory layout with pre-v2 file fallback and migrate-on-write (ONDISK
  §Collections). `list()` must not show a migrated collection twice.

## Derived staleness (nvim-owned, but don't break it)

- `analyses/<stamp>/metadata.yaml.issue_updated_at` vs cached `updated_at`
  decides current/outdated. The CLI must not rewrite these files. It *does* index
  the prose into FTS on `reindex`.
- `translations/<lang>.md` frontmatter works identically (ONDISK §Translations),
  with the same rule: derive, never store. Reading and re-writing a translation
  must leave `issue_updated_at` alone, or a hand-edit would silently mark a stale
  translation current.

## Overlay section boundaries are files, not headings

The plugin renders memo/metadata/prompt as `##` sections of one buffer, and the
first implementation split the buffer back apart by scanning for those headings.
That is wrong: a user writing `## Metadata` *inside* a memo — completely
legitimate Markdown — truncated their own note. The plugin now anchors each
region with extmarks; the transferable rule for any implementation is that
**overlay content is opaque text delimited by file boundaries**, never by
markers occurring within it. Nothing in a memo may be interpreted.
