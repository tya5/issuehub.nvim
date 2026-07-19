rockspec_format = "3.0"
package = "issuehub.nvim"
version = "scm-1"

source = {
  url = "git+https://github.com/tya5/issuehub.nvim",
}

description = {
  summary = "An Issue Workspace for Neovim: issue trackers plus the knowledge you build around them.",
  detailed = [[
    issuehub.nvim unifies issue trackers behind one Neovim UI and pairs each
    issue with a local, Git-managed workspace of notes, metadata, and analysis.
    Jira, Redmine, GitHub, and GitLab are supported.
    It has no hard dependencies: pickers, git, diff, and markdown rendering are
    all delegated to whatever the user already has installed.
  ]],
  labels = { "neovim", "jira", "redmine", "issues" },
  homepage = "https://github.com/tya5/issuehub.nvim",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1",
}

test_dependencies = {
  "nlua",
}

build = {
  type = "builtin",
  copy_directories = { "doc", "plugin", "ftplugin" },
}
