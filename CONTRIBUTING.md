# Contributing

Thanks for taking a look. issuehub.nvim is pre-1.0 and the architecture is still
settling, so **please open an issue before starting anything substantial** — the
answer may be "that belongs in a provider" or "that's already scheduled for 0.3",
and it is better to find that out before you write the code.

Read [DESIGN.md](DESIGN.md) first. It is the contract, not a sketch.

## Running the tests

No toolchain required:

```sh
nvim -l spec/runner.lua
```

This uses a minimal busted-compatible harness (`spec/runner.lua`) so the suite
runs anywhere Neovim does. CI runs the same specs under real busted + nlua across
Neovim 0.11, stable, and nightly — if you have the toolchain, `busted` works too.

Formatting and linting:

```sh
stylua lua plugin ftplugin spec
luacheck lua plugin ftplugin
```

## The rules that actually matter

These are the ones a PR gets sent back for.

**1. No hard dependencies.** `dependencies = {}` is a design guarantee, not an
oversight. Every integration is a runtime `pcall(require, ...)`. If you find
yourself wanting to add a dependency, that is a signal the feature belongs behind
an adapter — or in a different plugin.

**2. Credentials never touch argv, logs, or disk.** Tokens go to curl on stdin
via `--config -`, are cached in memory for the session only, and are redacted by
`util/log.lua` unconditionally. If you add a code path that handles a
credential, add a spec proving it does not leak.

**3. Only `core/repository.lua` knows about paths.** Everything else speaks in
URIs. This is what lets the on-disk layout change without breaking the API.

**4. Providers are UI-free and workspace-unaware.** A provider converts a remote
payload to a canonical Issue and nothing else: no `vim.notify`, no file access,
all I/O async, errors *returned* rather than thrown.

**5. The core interprets only `status.closed`.** Do not reintroduce a
cross-provider workflow enum. "In Review" means different things at different
organizations; see §4.1 for why that boundary is where it is.

**6. Every list-shaped operation takes a `View`, never a picker.** This is what
keeps export, analysis, and collections independent of which picker is installed.

**7. Do not ship a config key that does nothing.** Keys for unimplemented
milestones are *rejected* by validation, not silently accepted. A setting that
appears to work but does not is worse than a missing feature.

**8. No user-facing string may name a command that does not exist.** Check
against the subcommand table in `plugin/issuehub.lua`.

## Adding a provider

Implement the interface in DESIGN.md §7 and register it:

```lua
require("issuehub.provider").register("github", my_provider)
```

Test it against **recorded fixtures**, never a live API — `provider.http` is
injectable for exactly this reason (see `spec/jira_spec.lua`). A provider PR
without fixtures will not be merged, because nobody else can run it.

Providers may live in this repo or in your own; the interface is public either
way, and there is no advantage to being in-tree.

## Adding a picker backend

Implement `pick(view, opts)` plus the three capability flags (`preview`,
`multi_select`, `actions`) — see §9.2. Declare only those three. Flags the core
does not branch on are adapter-internal presentation, and adding them just
creates fields future adapters have to fill in for no reason.

## Commit messages

Conventional-ish (`feat:`, `fix:`, `docs:`, `refactor:`). Explain *why* in the
body. If you fixed something subtle, say what the failure mode was — that is the
part nobody can reconstruct from the diff later.

## Reporting bugs

Please include the output of `:checkhealth issuehub`. It reports your picker
backend, index backend, tool availability, and whether credentials resolve —
**without printing any credential** — which answers most of the first round of
questions.
