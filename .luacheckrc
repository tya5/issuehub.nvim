-- Lua 5.1 is the ceiling: Neovim's LuaJIT does not go higher.
std = "luajit"
cache = true

read_globals = {
  "vim",
  -- busted
  "describe",
  "it",
  "before_each",
  "after_each",
  "assert",
  "setup",
  "teardown",
}

globals = {
  "vim.g",
  "vim.b",
  "vim.bo",
  "vim.wo",
  "vim.env",
}

ignore = {
  "212", -- unused argument
  "631", -- line too long (stylua owns formatting)
  "122", -- specs stub vim.notify to assert on user-facing messages
}
