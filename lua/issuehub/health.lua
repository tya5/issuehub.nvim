---@brief :checkhealth issuehub (§19).
local M = {}

local h = vim.health

local function check_neovim()
  h.start("Neovim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11+ is required", { "Upgrade Neovim" })
  end
end

local function check_binaries()
  h.start("External tools")

  local ok, msg = require("issuehub.util.http").probe()
  if ok then
    h.ok(msg)
  else
    h.error(msg, { "curl is required for every provider request" })
  end

  if vim.fn.executable("git") == 1 then
    h.ok("git found")
  else
    h.warn("git not found", { "The Workspace is designed to be Git-managed" })
  end

  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep found")
  else
    h.warn("ripgrep not found", { "`:IssueHub find` falls back to a slower scan" })
  end

  if vim.fn.executable("sqlite3") == 1 then
    h.ok("sqlite3 found")
  else
    h.info("sqlite3 not found — the json index backend will be used")
  end
end

local function check_network()
  h.start("Network")

  local config = require("issuehub.config")
  local net = config.net(nil)

  h.info(config.net_summary(nil))

  if net.ssl_verify == false then
    h.error("TLS certificate verification is DISABLED (http.ssl_verify = false)", {
      "Every request is vulnerable to interception, including your API tokens.",
      "Prefer trusting your organisation's root CA instead:",
      "  http = { cacert = '/path/to/corporate-root.pem' }",
    })
  elseif net.cacert or net.capath then
    h.ok("using a custom CA bundle with verification enabled")
  end

  if net.proxy_user and not net.proxy_password then
    h.warn("http.proxy_user is set but no password resolved", {
      "Set proxy_password_env, proxy_password_cmd, or proxy_password.",
    })
  end

  if net.client_cert then
    if net.client_key then
      h.ok("client certificate configured (mTLS)")
    else
      h.error("http.client_cert is set without http.client_key")
    end
  end

  -- A per-provider override is easy to forget about; list any that differ.
  for name in pairs(config.get().providers) do
    local p = config.get().providers[name]
    if type(p.http) == "table" and not vim.tbl_isempty(p.http) then
      h.info(("%s overrides network settings: %s"):format(name, config.net_summary(name)))
    end
  end
end

local function check_workspace()
  h.start("Workspace")

  local config = require("issuehub.config")
  if not config.is_setup() then
    h.warn("setup() has not been called")
  end

  local workspace = config.get().workspace
  if not workspace then
    h.error("`workspace` is not configured", {
      "Set it in setup(): require('issuehub').setup({ workspace = '~/notes/issuehub' })",
    })
    return
  end

  local fs = require("issuehub.util.fs")
  if not fs.is_dir(workspace) then
    h.warn("workspace does not exist yet: " .. workspace, { "It is created on first use" })
    return
  end
  h.ok("workspace: " .. workspace)

  local repository = require("issuehub.core.repository")
  local version = repository.version()
  if version and version ~= repository.layout_version() then
    h.warn(("Repository layout v%s, plugin expects v%s"):format(version, repository.layout_version()))
  end

  if fs.is_dir(vim.fs.joinpath(workspace, ".git")) then
    h.ok("workspace is a git repository")

    -- .state/ holds cache, index, and locks; committing it would be noise at
    -- best and a leak of issue content at worst.
    local gitignore = fs.read(vim.fs.joinpath(workspace, ".gitignore")) or ""
    if gitignore:find("%.state") then
      h.ok(".state/ is git-ignored")
    else
      h.warn(".state/ is not listed in .gitignore", { "Add `/.state/` to avoid committing derived data" })
    end
  else
    h.info("workspace is not a git repository (recommended, not required)")
  end
end

local function check_index()
  h.start("Index")
  local index = require("issuehub.core.index").get()
  local ok, msg = index:health()
  if ok then
    h.ok(msg)
  else
    h.warn(msg)
  end
end

local function check_providers()
  h.start("Providers")

  local providers = require("issuehub.provider")
  local names = providers.configured_names()
  if #names == 0 then
    h.warn("no providers configured")
    return
  end

  for _, name in ipairs(names) do
    local provider, err = providers.get(name)
    if not provider then
      h.error(("%s: %s"):format(name, tostring(err)))
    else
      -- Reports whether the credential resolves, never what it is.
      local ok, msg = provider:health()
      if ok then
        h.ok(("%s: %s"):format(name, msg))
      else
        h.error(("%s: %s"):format(name, msg))
      end
    end
  end
end

local function check_ui()
  h.start("UI backends")

  local picker = require("issuehub.ui.picker")
  local detected = picker.detected()
  local active = picker.get()

  h.info("detected: " .. table.concat(detected, ", "))
  if active.name == "select" then
    h.warn("using the vim.ui.select fallback", {
      "Single column, no preview, no multi-select.",
      "Install snacks.nvim, fzf-lua, or telescope.nvim for the full experience.",
    })
  else
    local caps = active.caps
    h.ok(
      ("active picker: %s (preview=%s multi_select=%s actions=%s)"):format(
        active.name,
        caps.preview,
        caps.multi_select,
        caps.actions
      )
    )
  end
end

function M.check()
  check_neovim()
  check_binaries()
  check_network()
  check_workspace()
  check_index()
  check_providers()
  check_ui()
end

return M
