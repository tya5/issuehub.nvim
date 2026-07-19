---@brief Virtual buffer: composition, read-only enforcement, writeback (§6, §9).
---
--- The buffer is Issue (read-only, from cache) + Overlay (editable, from the
--- Workspace) rendered as one Markdown document. Only Memo, Metadata, and Prompt
--- are writable; `:w` extracts those three regions and writes the files whose
--- content actually changed.

local cache = require("issuehub.core.cache")
local overlay_mod = require("issuehub.core.overlay")
local workspace = require("issuehub.core.workspace")
local render = require("issuehub.ui.render")
local log = require("issuehub.util.log")

local M = {}

local ns = vim.api.nvim_create_namespace("issuehub")
local augroup = vim.api.nvim_create_augroup("issuehub_buffer", { clear = true })

---Per-buffer state that must not live in buffer variables, because it holds
---the full line list used to restore read-only edits.
---@type table<integer, { uri: string, readonly: string[], last_good: string[], warned_at: integer }>
local tracked = {}

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
---@return string[]
local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---Warn at most once a second: a single keystroke can fire TextChangedI
---repeatedly, and a storm of identical notifications is worse than the edit.
---@param buf integer
---@param message string
local function warn_once(buf, message)
  local state = tracked[buf]
  local now = vim.uv.now()
  if state and state.warned_at and now - state.warned_at < 1000 then
    return
  end
  if state then
    state.warned_at = now
  end
  vim.notify("issuehub: " .. message, vim.log.levels.WARN)
end

---Restore the read-only prefix if it was edited.
---
--- Neovim has no per-region lock, so this is advisory by design (§6): the edit
--- is reverted rather than prevented. Fighting the user harder than this
--- produces a worse experience than the occasional revert.
---@param buf integer
local function enforce_readonly(buf)
  local state = tracked[buf]
  if not state then
    return
  end

  local current = lines_of(buf)
  local ranges, err = render.parse_sections(current)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local function restore(all_lines, message)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(cursor[1], #all_lines), cursor[2] })
    warn_once(buf, message)
  end

  if not ranges then
    -- A section heading was destroyed; without it the buffer can no longer be
    -- mapped back onto files, so the whole thing goes back to the last good
    -- state rather than guessing.
    return restore(state.last_good, ("section headings must stay intact (%s) — reverted"):format(err))
  end

  local first_heading = math.huge
  for _, range in pairs(ranges) do
    first_heading = math.min(first_heading, range.first - 1)
  end

  local prefix_ok = (first_heading - 1) == #state.readonly
  if prefix_ok then
    for i = 1, #state.readonly do
      if current[i] ~= state.readonly[i] then
        prefix_ok = false
        break
      end
    end
  end

  if not prefix_ok then
    -- Keep whatever the user typed in the editable regions; only the read-only
    -- prefix is rewound.
    local rebuilt = vim.list_extend({}, state.readonly)
    for i = first_heading, #current do
      rebuilt[#rebuilt + 1] = current[i]
    end
    return restore(rebuilt, "the issue section is read-only — reverted")
  end

  state.last_good = current
end

---@param buf integer
---@param result issuehub.RenderResult
---@param uri string
local function paint(buf, result, uri)
  local view = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_buf(view) == buf and vim.api.nvim_win_get_cursor(view) or nil

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
  vim.bo[buf].modified = false

  if cursor then
    pcall(vim.api.nvim_win_set_cursor, view, { math.min(cursor[1], #result.lines), cursor[2] })
  end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for name, range in pairs(result.sections) do
    if range.first <= #result.lines and range.last >= range.first then
      -- right_gravity=false on the start and true on the end, so the marks keep
      -- bracketing a region as the user types inside it.
      vim.api.nvim_buf_set_extmark(buf, ns, range.first - 1, 0, {
        end_row = math.min(range.last, #result.lines) - 1,
        right_gravity = false,
        end_right_gravity = true,
      })
      vim.b[buf]["issuehub_section_" .. name] = { range.first, range.last }
    end
  end

  tracked[buf] = tracked[buf] or {}
  tracked[buf].uri = uri
  tracked[buf].readonly = vim.list_slice(result.lines, 1, result.readonly_until)
  tracked[buf].last_good = result.lines
end

---Write the editable regions back. Bound to BufWriteCmd.
---@param buf integer
---@return boolean ok
function M.save(buf)
  local state = tracked[buf]
  if not state then
    return false
  end

  local content, err = render.extract(lines_of(buf))
  if not content then
    vim.notify("issuehub: cannot save — " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local written, werr = overlay_mod.write(state.uri, content)
  if werr then
    vim.notify("issuehub: save failed — " .. werr, vim.log.levels.ERROR)
    return false
  end

  vim.bo[buf].modified = false

  if #written == 0 then
    vim.notify("issuehub: no changes", vim.log.levels.INFO)
  else
    table.sort(written)
    vim.notify(("issuehub: wrote %s"):format(table.concat(written, ", ")))
    -- The index mirrors overlay text for search; keep it in step.
    local entry = cache.get(state.uri)
    if entry and entry.issue then
      require("issuehub.core.index").get():put(entry.issue)
    end
  end

  return true
end

---@param buf integer
---@param uri string
local function configure(buf, uri)
  vim.api.nvim_buf_set_name(buf, bufname(uri))
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "issuehub"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].issuehub_uri = uri

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = buf,
    callback = function()
      M.save(buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = buf,
    callback = function()
      enforce_readonly(buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = buf,
    callback = function()
      tracked[buf] = nil
    end,
  })
end

---@param buf integer
---@param issue issuehub.Issue
local function set_vars(buf, issue)
  -- ftplugin's `gx` reads this; without it the mapping silently does nothing.
  vim.b[buf].issuehub_url = issue.url
end

---Render an issue into an arbitrary buffer, for picker previews. Uses the same
---renderer as the real buffer, so the two cannot drift (§9.3).
---@param uri string
---@param buf integer
function M.preview(uri, buf)
  local entry = cache.get(uri)
  if not entry then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "(not cached — open it once to fetch)" })
    return
  end
  local result = render.issue(entry.issue, entry, overlay_mod.read(uri))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
  vim.bo[buf].filetype = "markdown"
end

---Open the virtual buffer for a URI.
---@param uri string
function M.open(uri)
  local entry, err = cache.get(uri)
  if err then
    return vim.notify("issuehub: " .. err, vim.log.levels.ERROR)
  end

  local buf = find_buf(uri)
  if not buf then
    buf = vim.api.nvim_create_buf(true, false)
    configure(buf, uri)
  end

  if entry then
    paint(buf, render.issue(entry.issue, entry, overlay_mod.read(uri)), uri)
    set_vars(buf, entry.issue)
  else
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# " .. uri, "", "_Fetching…_" })
    vim.bo[buf].modified = false
  end

  vim.api.nvim_win_set_buf(0, buf)

  if entry then
    workspace.touch(uri)
  end

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

  provider:get(id, function(gerr, issue)
    if gerr then
      log.warn("refresh failed", uri, gerr)
      if not opts.silent then
        vim.notify("issuehub: " .. gerr, vim.log.levels.ERROR)
      end
      return
    end

    cache.put(issue)
    local buf = find_buf(uri)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      -- Unsaved edits must survive a background refresh: re-render with what is
      -- currently in the buffer, not with what is on disk.
      local pending = vim.bo[buf].modified and render.extract(lines_of(buf)) or nil
      paint(buf, render.issue(issue, cache.get(uri), pending or overlay_mod.read(uri)), uri)
      set_vars(buf, issue)
      if pending then
        vim.bo[buf].modified = true
      end
    end
  end)
end

---@return string? uri
function M.current_uri()
  return vim.b[vim.api.nvim_get_current_buf()].issuehub_uri
end

---Exposed for specs.
---@param buf integer
function M._enforce(buf)
  enforce_readonly(buf)
end

return M
