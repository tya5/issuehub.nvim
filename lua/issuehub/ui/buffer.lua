---@brief Virtual buffer construction (§6).
---
--- In 0.1 the whole buffer is read-only. Editable Memo/Metadata/Prompt regions
--- and BufWriteCmd writeback arrive in 0.2; the section extmarks that will carry
--- the region boundaries are already recorded here.

local cache = require("issuehub.core.cache")
local render = require("issuehub.ui.render")
local log = require("issuehub.util.log")

local M = {}

local ns = vim.api.nvim_create_namespace("issuehub")

---@param uri string
---@return string
local function bufname(uri)
  return "issuehub://" .. uri:gsub("://", "/")
end

---@param uri string
---@return integer? bufnr
local function find_buf(uri)
  local name = bufname(uri)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(-#name) == name then
      return buf
    end
  end
  return nil
end

---@param buf integer
---@param result issuehub.RenderResult
local function paint(buf, result)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for name, range in pairs(result.sections) do
    if range.first <= #result.lines then
      -- right_gravity=false on the start and true on the end, so the marks keep
      -- bracketing the region once 0.2 makes parts of it editable.
      vim.api.nvim_buf_set_extmark(buf, ns, range.first - 1, 0, {
        end_row = math.min(range.last, #result.lines) - 1,
        right_gravity = false,
        end_right_gravity = true,
        -- Retrieved by name in 0.2 to decide which edits to revert.
        hl_group = nil,
      })
      vim.b[buf]["issuehub_section_" .. name] = { range.first, range.last }
    end
  end
end

---@param buf integer
---@param uri string
local function configure(buf, uri)
  vim.api.nvim_buf_set_name(buf, bufname(uri))
  vim.bo[buf].buftype = "acwrite" -- 0.2 attaches BufWriteCmd for the overlay
  vim.bo[buf].filetype = "issuehub"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].issuehub_uri = uri
end

---@param buf integer
---@param issue issuehub.Issue
local function set_vars(buf, issue)
  -- ftplugin's `gx` reads this; without it the mapping silently does nothing.
  vim.b[buf].issuehub_url = issue.url
end

---Render an issue into an arbitrary buffer. Used by picker previews so preview
---and the real buffer can never drift (§9.3).
---@param uri string
---@param buf integer
function M.preview(uri, buf)
  local entry = cache.get(uri)
  if not entry then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "(not cached — open it once to fetch)" })
    return
  end
  local result = render.issue(entry.issue, entry)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
  vim.bo[buf].filetype = "markdown"
end

---Open the virtual buffer for a URI.
---
--- The buffer is painted from cache immediately, then refreshed asynchronously
--- if stale — the window never waits on the network (§10).
---@param uri string
function M.open(uri)
  local entry, err = cache.get(uri)
  if err then
    return vim.notify("issuehub: " .. err, vim.log.levels.ERROR)
  end

  local buf = find_buf(uri)
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    configure(buf, uri)
  end

  if entry then
    paint(buf, render.issue(entry.issue, entry))
    set_vars(buf, entry.issue)
  else
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# " .. uri, "", "_Fetching…_" })
    vim.bo[buf].modifiable = false
  end

  vim.api.nvim_win_set_buf(0, buf)

  local sync = require("issuehub.config").get().sync
  -- A partial entry (from a list query) is refreshed even under "never": there
  -- is genuinely no description to show otherwise.
  local should_refresh = sync.on_open == "always"
    or (sync.on_open == "stale" and cache.is_stale(uri, sync.stale_after))
    or not entry
    or entry.partial

  if should_refresh then
    M.refresh(uri, { silent = entry ~= nil })
  end
end

---Fetch a URI and repaint any buffer showing it.
---@param uri string
---@param opts { silent: boolean? }?
function M.refresh(uri, opts)
  opts = opts or {}
  local provider, id = require("issuehub.provider").resolve(uri)
  if not provider then
    if not opts.silent then
      vim.notify("issuehub: " .. tostring(id), vim.log.levels.ERROR)
    end
    return
  end

  provider:get(id, function(err, issue)
    if err then
      log.warn("refresh failed", uri, err)
      if not opts.silent then
        vim.notify("issuehub: " .. err, vim.log.levels.ERROR)
      end
      return
    end

    cache.put(issue)
    local buf = find_buf(uri)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      paint(buf, render.issue(issue, cache.get(uri)))
      set_vars(buf, issue)
    end
  end)
end

---@return string? uri
function M.current_uri()
  return vim.b[vim.api.nvim_get_current_buf()].issuehub_uri
end

return M
