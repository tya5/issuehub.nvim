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

---Ask for a value, then run `fn`. Shared by the subcommands and the <Plug>
---mappings: having the mapping call the API directly is what let it drift into
---searching for an empty string.
---@param prompt string
---@param fn fun(value: string)
local function ask(prompt, fn)
  vim.ui.input({ prompt = prompt }, function(value)
    if value and vim.trim(value) ~= "" then
      fn(value)
    end
  end)
end

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
      return ask("Query: ", function(value)
        require("issuehub").search(value)
      end)
    end
    require("issuehub").search(query)
  end,

  find = function(args)
    -- With no arguments this browses everything and lets the picker filter,
    -- matching `:IssueHub open`'s shape. With arguments it runs the precise
    -- search, which can reach analyses and regexes the picker cannot.
    require("issuehub").find(require("issuehub.core.query").parse(args))
  end,

  ["local"] = function(args)
    require("issuehub").local_issues(args[1], args[2])
  end,

  refresh = function()
    local uri = require("issuehub.ui.buffer").current_uri()
    if not uri then
      return vim.notify("issuehub: not in an issue buffer", vim.log.levels.WARN)
    end
    require("issuehub.ui.buffer").refresh(uri)
  end,

  analyze = function(args)
    require("issuehub").analyze(args[1])
  end,

  prompt = function(args)
    require("issuehub").conversation(args[1])
  end,

  translate = function(args)
    require("issuehub").translate(args[1], args[2])
  end,

  translations = function(args)
    require("issuehub").translations(args[1])
  end,

  analyses = function(args)
    require("issuehub").analyses(args[1])
  end,

  import = function(args)
    local dry = false
    args = vim.tbl_filter(function(arg)
      if arg == "--dry-run" then
        dry = true
        return false
      end
      return true
    end, args)
    require("issuehub").import(args[1], { dry_run = dry })
  end,

  export = function(args)
    -- [format] [source]. The output path comes from `export.dir` (or the cwd)
    -- and the view's own name, so there is no third positional to get wrong.
    require("issuehub").export(args[1], args[2])
  end,

  collection = function(args)
    local action = args[1]
    if action == "add" or action == "remove" or action == "delete" or action == "list" then
      table.remove(args, 1)
    else
      action = nil
    end

    local issuehub = require("issuehub")
    local collections = require("issuehub.core.collection")

    if action == "add" then
      if not args[1] then
        return vim.notify("issuehub: collection add <name>", vim.log.levels.ERROR)
      end
      issuehub.collection_add(table.concat(args, " "))
    elseif action == "remove" then
      issuehub.collection_remove(table.concat(args, " "))
    elseif action == "delete" then
      local name = table.concat(args, " ")
      vim.notify(collections.delete(name) and ("issuehub: deleted '" .. name .. "'") or "issuehub: no such collection")
    elseif action == "list" then
      local slugs = collections.list()
      vim.notify(#slugs > 0 and ("issuehub collections: " .. table.concat(slugs, ", ")) or "issuehub: no collections")
    else
      issuehub.collection(table.concat(args, " "))
    end
  end,

  fetch = function(args)
    local action = args[1]
    local fetch = require("issuehub.core.fetch")

    if action == "stop" then
      local stopped = fetch.cancel()
      return vim.notify(
        stopped > 0 and ("issuehub: stopping %d fetch(es) after the current page"):format(stopped)
          or "issuehub: nothing is fetching"
      )
    end

    if action == "status" then
      local active = fetch.active()
      if #active == 0 then
        return require("issuehub").lists()
      end
      for _, run in ipairs(active) do
        vim.notify(("issuehub: %s — %d issues, %d pages, running"):format(run.provider, run.issues, run.pages))
      end
      return
    end

    if action == "resume" then
      return require("issuehub").fetch_all(args[2], { resume = true })
    end

    require("issuehub").fetch_all(action)
  end,

  sync = function(args)
    require("issuehub").sync(args[1])
  end,

  changed = function()
    require("issuehub").changed()
  end,

  bookmark = function()
    local buffer = require("issuehub.ui.buffer")
    local uri = buffer.current_uri()
    if not uri then
      return vim.notify("issuehub: not in an issue buffer", vim.log.levels.WARN)
    end
    local on = require("issuehub.core.workspace").toggle_bookmark(uri)
    vim.notify(("issuehub: %s %s"):format(on and "bookmarked" or "un-bookmarked", uri))
  end,

  bookmarks = function()
    require("issuehub").bookmarks()
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
  -- Opens the picker straight away and filters as you type, the same shape as
  -- <Plug>(IssueHubOpen). Only the corpus differs: local issues including your
  -- notes, rather than the provider's query.
  require("issuehub").browse()
end, { desc = "issuehub: browse local issues" })

vim.keymap.set("n", "<Plug>(IssueHubPrompt)", function()
  require("issuehub").conversation()
end, { desc = "issuehub: conversation window" })

vim.keymap.set("n", "<Plug>(IssueHubRefresh)", function()
  local uri = require("issuehub.ui.buffer").current_uri()
  if uri then
    require("issuehub.ui.buffer").refresh(uri)
  end
end, { desc = "issuehub: refresh current issue" })
