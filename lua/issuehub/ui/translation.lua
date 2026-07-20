---@brief Translation viewer.
---
--- Read-only Markdown, like the analysis viewer: the translation is generated
--- output, and the issue buffer above it stays the place you write. Editing a
--- clumsy translation is still possible — it is a plain file in your workspace
--- (`translations/<lang>.md`), which `gf` from the header will open.

local translation = require("issuehub.core.translation")

local M = {}

---@param uri string
---@param lang string
---@return string
local function bufname(uri, lang)
  return ("issuehub://%s/translations/%s"):format(uri:gsub("://", "/"), lang)
end

---@param entry issuehub.Translation
---@param uri string
---@return string[]
function M.render(entry, uri)
  local lines = {
    ("# %s"):format(entry.title ~= "" and entry.title or ("(%s)"):format(entry.lang)),
    "",
    ("- Language: %s"):format(entry.lang),
    ("- Issue:    %s"):format(uri),
    ("- Created:  %s"):format(entry.created_at ~= "" and entry.created_at or "?"),
    ("- Backend:  %s%s"):format(entry.backend or "?", entry.model and (" / " .. entry.model) or ""),
  }

  if entry.status == "outdated" then
    -- Derived from the recorded revision, so this cannot itself be stale.
    lines[#lines + 1] = ("- Status:   OUTDATED — the issue moved since this was translated (was %s)"):format(
      entry.issue_updated_at or "?"
    )
  elseif entry.status == "current" then
    lines[#lines + 1] = "- Status:   current"
  else
    lines[#lines + 1] = "- Status:   unknown (issue not cached)"
  end

  local path = translation.path(uri, entry.lang)
  if path then
    lines[#lines + 1] = ("- File:     %s"):format(path)
  end

  vim.list_extend(lines, { "", "---", "" })
  vim.list_extend(lines, vim.split(entry.body, "\n", { plain = true }))
  return lines
end

---@param uri string
---@param lang string
function M.open(uri, lang)
  local entry = translation.get(uri, lang)
  if not entry then
    return vim.notify(
      ("issuehub: no %s translation for %s — `:IssueHub translate %s`"):format(lang, uri, lang),
      vim.log.levels.INFO
    )
  end

  local name = bufname(uri, entry.lang)
  local buf
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(candidate) and vim.api.nvim_buf_get_name(candidate):sub(-#name) == name then
      buf = candidate
      break
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.render(entry, uri))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].issuehub_uri = uri
  vim.b[buf].issuehub_translation = entry.lang

  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

---Pick a language, then open it.
---@param uri string
function M.select(uri)
  local langs = translation.languages(uri)
  if #langs == 0 then
    return vim.notify(
      ("issuehub: no translations for %s yet — `:IssueHub translate <lang>`"):format(uri),
      vim.log.levels.INFO
    )
  end
  if #langs == 1 then
    return M.open(uri, langs[1])
  end

  vim.ui.select(langs, {
    prompt = "Translation",
    format_item = function(lang)
      local entry = translation.get(uri, lang)
      return ("%s  [%s]"):format(lang, entry and entry.status or "?")
    end,
  }, function(lang)
    if lang then
      M.open(uri, lang)
    end
  end)
end

return M
