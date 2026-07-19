-- Auto-sourced at startup. Per §2 this file may ONLY declare commands, <Plug>
-- mappings, and highlight groups, and must never require() the implementation
-- at the top level. Deferring every require inside the callbacks is what makes
-- the plugin self-lazy-loading: users do not need `cmd =` in their lazy.nvim
-- spec, and startup cost stays at zero until a command actually runs.

if vim.g.loaded_issuehub then
  return
end
vim.g.loaded_issuehub = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("issuehub.nvim requires Neovim 0.11+", vim.log.levels.ERROR)
  return
end

-- Highlight groups are defined here, not in setup(), so they exist even for a
-- user who never calls setup() (§1.4).
require("issuehub.ui.highlight").setup()

---@type table<string, fun(args: string[])>
local subcommands = {
  open = function(args)
    if args[1] then
      require("issuehub").open_uri(args[1])
    else
      require("issuehub").open()
    end
  end,

  search = function(args)
    local query = table.concat(args, " ")
    if query == "" then
      return vim.ui.input({ prompt = "Query: " }, function(value)
        if value and value ~= "" then
          require("issuehub").search(value)
        end
      end)
    end
    require("issuehub").search(query)
  end,

  find = function(args)
    local pattern = table.concat(args, " ")
    if pattern == "" then
      return vim.ui.input({ prompt = "Find: " }, function(value)
        if value and value ~= "" then
          require("issuehub").find(value)
        end
      end)
    end
    require("issuehub").find(pattern)
  end,

  ["local"] = function()
    require("issuehub").local_issues()
  end,

  refresh = function()
    local uri = require("issuehub.ui.buffer").current_uri()
    if not uri then
      return vim.notify("issuehub: not in an issue buffer", vim.log.levels.WARN)
    end
    require("issuehub.ui.buffer").refresh(uri)
  end,

  reindex = function()
    require("issuehub").reindex()
  end,

  provider = function(args)
    local providers = require("issuehub.provider")
    local action = args[1] or "list"
    if action == "list" then
      local names = providers.configured_names()
      if #names == 0 then
        return vim.notify("issuehub: no providers configured")
      end
      vim.notify("issuehub providers: " .. table.concat(names, ", "))
    elseif action == "health" then
      vim.cmd("checkhealth issuehub")
    else
      vim.notify("issuehub: unknown provider action " .. action, vim.log.levels.ERROR)
    end
  end,

  health = function()
    vim.cmd("checkhealth issuehub")
  end,
}

vim.api.nvim_create_user_command("IssueHub", function(opts)
  local args = opts.fargs
  local name = table.remove(args, 1) or "open"
  local handler = subcommands[name]
  if not handler then
    return vim.notify(
      ("issuehub: unknown subcommand '%s' (try: %s)"):format(name, table.concat(vim.tbl_keys(subcommands), ", ")),
      vim.log.levels.ERROR
    )
  end
  handler(args)
end, {
  nargs = "*",
  desc = "issuehub.nvim",
  complete = function(lead, line)
    -- Only complete the subcommand itself; arguments are free-form (JQL,
    -- patterns, URIs) and guessing at them would get in the way.
    if line:match("^%s*IssueHub%s+%S+%s") then
      return {}
    end
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, vim.tbl_keys(subcommands))
  end,
})

-- No default keymaps are created (§2). These exist for users to bind.
vim.keymap.set("n", "<Plug>(IssueHubOpen)", function()
  require("issuehub").open()
end, { desc = "issuehub: open picker" })

vim.keymap.set("n", "<Plug>(IssueHubFind)", function()
  require("issuehub").find("")
end, { desc = "issuehub: local search" })

vim.keymap.set("n", "<Plug>(IssueHubRefresh)", function()
  local uri = require("issuehub.ui.buffer").current_uri()
  if uri then
    require("issuehub.ui.buffer").refresh(uri)
  end
end, { desc = "issuehub: refresh current issue" })
