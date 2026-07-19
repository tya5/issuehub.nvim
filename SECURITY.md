# Security Policy

## Reporting a vulnerability

Please report security issues privately via
[GitHub Security Advisories](https://github.com/tya5/issuehub.nvim/security/advisories/new)
rather than a public issue.

This plugin is pre-1.0 and maintained on a best-effort basis; expect an initial
response within a couple of weeks.

## What this plugin does with your credentials

issuehub handles API tokens for issue trackers, so the handling is stated
explicitly:

- Tokens are **never written to disk** by issuehub. They are resolved at use time
  from `token_env`, `token_cmd`, or a `token` function, and cached in memory for
  the session only.
- Tokens are **never passed in argv**. They reach curl through a config file on
  **stdin** (`--config -`), so they are not visible to `ps` or other users on a
  shared machine.
- **Proxy passwords and client-key passphrases** are treated exactly like API
  tokens: resolved from an env var or a command, delivered on stdin, never in
  argv. `:checkhealth` strips credentials from the proxy URL before showing it.
- Tokens are **redacted from the log file unconditionally**, with no opt-out
  (`lua/issuehub/util/log.lua`). Redaction is covered by specs.
- `:checkhealth issuehub` reports whether a credential *resolves*, never its
  value or any prefix of it.

If you find a path where a credential reaches disk, argv, a log, or a buffer,
that is a vulnerability — please report it.

## TLS verification

`http.ssl_verify = false` disables certificate verification for every request,
which means API tokens travel over a connection nobody is authenticating. It
exists because some corporate CAs cannot be exported, but:

- it logs a warning at `setup()`,
- `:checkhealth issuehub` reports it as an **error** while it is enabled,
- and the supported alternative is `http.cacert`, which keeps verification on
  while trusting your organisation's root.

If you are running with it enabled, treat it as an open issue, not a setting.

## Things worth knowing

- **The cache and index are not encrypted.** `.state/` under your workspace holds
  full issue content in plain JSON (and SQLite, if enabled). If your tracker
  contains sensitive data, the workspace directory is as sensitive as the tracker
  and should be protected accordingly — including before you push it anywhere.
- **`.state/` is git-ignored automatically**, but the Workspace itself is
  designed to be committed. Review what you commit; your notes about an issue may
  be more sensitive than the issue.
- **`token_cmd` executes a command you configure.** It is not sandboxed. Do not
  point it at anything you would not run yourself.
- The SQLite index backend shells out to the `sqlite3` CLI and escapes values by
  interpolation rather than parameter binding (the CLI has no binding facility).
  Values come only from provider payloads today; see the caveat in
  `lua/issuehub/core/index/sqlite.lua`.

## Supported versions

Pre-1.0: only the latest release receives fixes.
