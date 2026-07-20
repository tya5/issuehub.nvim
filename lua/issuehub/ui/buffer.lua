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

  -- Where the editable region begins. Extmarks are authoritative and survive a
  -- memo that merely *contains* a line like "## Metadata"; the text scan is the
  -- fallback for a buffer whose marks were lost.
  local first_heading = math.huge
  if state.marks then
    for _, id in pairs(state.marks) do
      local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
      if mark and mark[1] then
        first_heading = math.min(first_heading, mark[1])
      end
    end
  end

  if first_heading == math.huge then
    if not ranges then
      -- No marks AND no parseable headings: the buffer can no longer be mapped
      -- back onto files, so restore rather than guess.
      return restore(state.last_good, ("section headings must stay intact (%s) — reverted"):format(err))
    end
    for _, range in pairs(ranges) do
      first_heading = math.min(first_heading, range.first - 1)
    end
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

---@param uri string
---@return table
local function render_opts(uri)
  local state = workspace.state(uri)
  return {
    changed_since_seen = workspace.changed_since_seen(uri),
    seen_at = state.last_seen_updated_at,
    -- Whether the newest analysis still describes the issue as it is now.
    analysis = require("issuehub.core.analysis").latest(uri),
  }
end

---What each section is, shown at the end of its heading.
---
--- Read-only and editable regions rendered identically, which is a poor way to
--- learn the difference — the first feedback was an edit being reverted.
local SECTION_LABEL = {
  description = { text = "read-only", hl = "IssueHubReadOnly" },
  comments = { text = "read-only", hl = "IssueHubReadOnly" },
  memo = { text = "editable → memo.md", hl = "IssueHubEditable" },
  metadata = { text = "editable → metadata.yaml", hl = "IssueHubEditable" },
}

---@param buf integer
---@param result issuehub.RenderResult
---@return table<string, integer> marks  field -> extmark id over its CONTENT
local function decorate(buf, result)
  local marks = {}
  local first_editable = math.huge
  for name, range in pairs(result.sections) do
    local label = SECTION_LABEL[name]
    if label and label.hl == "IssueHubEditable" then
      first_editable = math.min(first_editable, range.first)
    end
  end

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

      -- A second mark over the section's CONTENT only (everything below the
      -- heading). Writeback reads these instead of re-scanning the text for
      -- headings, so a line like "## Metadata" typed inside a memo is just
      -- text. Extmarks move with the user's edits, which is what makes this
      -- work at all.
      if SECTION_LABEL[name] and SECTION_LABEL[name].hl == "IssueHubEditable" then
        local content_start = math.min(range.first + 1, #result.lines)
        local content_end = math.max(math.min(range.last, #result.lines), content_start)
        marks[name] = vim.api.nvim_buf_set_extmark(buf, ns, content_start - 1, 0, {
          end_row = content_end - 1,
          right_gravity = false,
          end_right_gravity = true,
        })
      end

      local label = SECTION_LABEL[name]
      if label then
        vim.api.nvim_buf_set_extmark(buf, ns, range.first - 1, 0, {
          virt_text = { { "  " .. label.text, label.hl } },
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      end
    end
  end

  -- One divider where the issue ends and your workspace begins, so the boundary
  -- is visible without reading the labels.
  if first_editable < math.huge and first_editable <= #result.lines then
    vim.api.nvim_buf_set_extmark(buf, ns, first_editable - 1, 0, {
      virt_lines_above = true,
      virt_lines = { { { ("─"):rep(30) .. " your workspace below ", "IssueHubDivider" } } },
    })
  end

  return marks
end

---Read the editable regions back from their extmarks.
---
--- Preferred over scanning the buffer for headings: the headings are ordinary
--- Markdown, so a memo containing the line "## Metadata" made the text scan see
--- a duplicate and refuse to save — permanently, once such a memo existed on
--- disk (editing the workspace outside Neovim is a supported workflow).
---@param buf integer
---@return table<string, string>? content  nil when the marks are unusable.
local function extract_by_marks(buf)
  local state = tracked[buf]
  if not state or not state.marks then
    return nil
  end

  local lines = lines_of(buf)
  local content = {}
  for _, spec in ipairs(render.SECTIONS) do
    local id = state.marks[spec.field]
    if not id then
      return nil
    end
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    if not mark or not mark[1] then
      return nil
    end
    local first = mark[1] + 1
    local last = (mark[3] and mark[3].end_row or mark[1]) + 1
    local body = {}
    for i = first, math.min(last, #lines) do
      body[#body + 1] = lines[i] or ""
    end
    content[spec.field] = (table.concat(body, "\n"):gsub("^%s*\n", ""):gsub("%s+$", ""))
  end
  return content
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
  local marks = decorate(buf, result)

  tracked[buf] = tracked[buf] or {}
  tracked[buf].marks = marks
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

  -- Extmarks first; the text scan is only a fallback for a buffer whose marks
  -- were lost (reload, :edit!).
  local content = extract_by_marks(buf)
  if not content then
    local err
    content, err = render.extract(lines_of(buf))
    if not content then
      vim.notify("issuehub: cannot save — " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
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

---Preview content for a URI, as lines.
---
--- Uses the same renderer as the real buffer, so preview and buffer cannot
--- drift (§9.3). Returning lines rather than writing to a buffer is deliberate:
--- picker previews have incompatible contracts — snacks hands you a preview
--- object, telescope hands you a bufnr — and only the adapter knows which.
---@param uri string
---@return string[]
function M.preview_lines(uri)
  local entry = cache.get(uri)
  if not entry then
    return { "(not cached — open it once to fetch)" }
  end
  return render.issue(entry.issue, entry, overlay_mod.read(uri), render_opts(uri)).lines
end

---Render a preview into a buffer, for pickers that hand out a bufnr.
---@param uri string
---@param buf integer
function M.preview(uri, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.preview_lines(uri))
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
    -- render_opts BEFORE touch(): the "changed since you last opened it" line
    -- has to reflect the state on arrival, not after we mark it seen.
    paint(buf, render.issue(entry.issue, entry, overlay_mod.read(uri), render_opts(uri)), uri)
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
      paint(buf, render.issue(issue, cache.get(uri), pending or overlay_mod.read(uri), render_opts(uri)), uri)
      set_vars(buf, issue)
      if pending then
        vim.bo[buf].modified = true
      end
    end
  end)
end

---Re-render a URI from cache, if a buffer is showing it. Used after a sync.
---@param uri string
function M.repaint(uri)
  local buf = find_buf(uri)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local entry = cache.get(uri)
  if not entry then
    return
  end
  -- Unsaved edits win over what is on disk.
  local pending = vim.bo[buf].modified and render.extract(lines_of(buf)) or nil
  paint(buf, render.issue(entry.issue, entry, pending or overlay_mod.read(uri), render_opts(uri)), uri)
  if pending then
    vim.bo[buf].modified = true
  end
end

---Open the conversation window beside the current issue.
---@param uri string?
---@param opts table?
function M.conversation(uri, opts)
  require("issuehub.ui.conversation").open(uri or M.current_uri(), opts)
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
