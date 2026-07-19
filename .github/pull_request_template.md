## What and why

<!-- What changes, and what problem it solves. If it fixes something subtle,
     describe the failure mode — that is the part nobody can reconstruct from
     the diff later. -->

Closes #

## Checklist

- [ ] `nvim -l spec/runner.lua` passes
- [ ] `stylua --check lua plugin ftplugin spec` passes
- [ ] Specs added for new behaviour (providers: against recorded fixtures, not a live API)
- [ ] No new hard dependency
- [ ] No credential reaches argv, a log, or disk
- [ ] No user-facing string names a command that does not exist
- [ ] DESIGN.md / README.md updated if behaviour or interfaces changed
