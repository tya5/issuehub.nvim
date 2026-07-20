---@brief Stored translations of an issue, one per language.
---
--- A translation is a *derived* artifact, like an analysis: produced from the
--- issue at a particular revision by a Backend, on the user's request. So it
--- carries the same staleness rule — `current` iff the revision it was made from
--- still matches the cached issue — and the same storage placement: in the
--- tracked workspace, not `.state/`. It is expensive to regenerate, worth
--- committing, and the user may well hand-correct a clumsy machine translation.
---
--- One file per language (`translations/ja.md`) rather than a directory per
--- language: unlike analyses there is no history to keep, and a single file is
--- something you can open and edit.

local cache = require("issuehub.core.cache")
local fs = require("issuehub.util.fs")
local repository = require("issuehub.core.repository")
local yaml = require("issuehub.util.yaml")

local M = {}

---@class issuehub.Translation
---@field lang string
---@field title string
---@field body string
---@field created_at string
---@field backend string?
---@field model string?
---@field issue_updated_at string?
---@field status "current"|"outdated"|"unknown"

---Language tags become filenames, so they are validated rather than trusted.
---
--- BCP-47-shaped and nothing else: letters, digits, and a hyphen separator
--- (`ja`, `pt-BR`, `zh-Hans`). Anything else — a slash, a dot, `..` — would
--- escape the translations directory.
---@param lang string?
---@return string? normalized
---@return string? err
function M.normalize_lang(lang)
  if type(lang) ~= "string" then
    return nil, "a language tag is required, e.g. ja"
  end
  local trimmed = vim.trim(lang)
  if not trimmed:match("^%a%a+[%w%-]*$") or #trimmed > 32 then
    return nil, ("not a language tag: %q (expected something like ja, en, pt-BR)"):format(lang)
  end
  return trimmed
end

---@param uri string
---@return string? dir
function M.dir(uri)
  local subject = repository.subject_dir(uri)
  return subject and vim.fs.joinpath(subject, "translations") or nil
end

---@param uri string
---@param lang string
---@return string? path
---@return string? err
function M.path(uri, lang)
  local normalized, err = M.normalize_lang(lang)
  if not normalized then
    return nil, err
  end
  local dir = M.dir(uri)
  if not dir then
    return nil, ("cannot resolve a path for %s"):format(tostring(uri))
  end
  return vim.fs.joinpath(dir, normalized .. ".md")
end

---Whether a translation still describes the issue as it is now.
---
--- Derived, never stored — identical to analysis staleness, and for the same
--- reason: a stored flag cannot become correct again after a `git revert`.
---@param uri string
---@param issue_updated_at string?
---@return "current"|"outdated"|"unknown"
function M.status(uri, issue_updated_at)
  if not issue_updated_at or issue_updated_at == "" then
    return "unknown"
  end
  local entry = cache.get(uri)
  if not entry or not entry.issue then
    return "unknown"
  end
  return entry.issue.updated_at == issue_updated_at and "current" or "outdated"
end

---@param text string
---@return table frontmatter
---@return string body
local function split_frontmatter(text)
  local fence, rest = text:match("^%-%-%-\n(.-)\n%-%-%-\n?(.*)$")
  if not fence then
    return {}, text
  end
  return yaml.parse(fence), rest
end

---@param uri string
---@param lang string
---@return issuehub.Translation?
function M.get(uri, lang)
  local path = M.path(uri, lang)
  if not path or not fs.exists(path) then
    return nil
  end

  local meta, body = split_frontmatter(fs.read(path) or "")
  return {
    lang = select(1, M.normalize_lang(lang)) or lang,
    title = meta.title or "",
    body = (body:gsub("^%s*\n", ""):gsub("%s+$", "")),
    created_at = meta.created_at or "",
    backend = meta.backend,
    model = meta.model,
    issue_updated_at = meta.issue_updated_at,
    status = M.status(uri, meta.issue_updated_at),
  }
end

---Languages this issue has been translated into, sorted.
---@param uri string
---@return string[]
function M.languages(uri)
  local dir = M.dir(uri)
  if not dir or not fs.is_dir(dir) then
    return {}
  end
  local langs = {}
  for _, name in ipairs(fs.list(dir)) do
    local lang = name:match("^(.+)%.md$")
    if lang and M.normalize_lang(lang) then
      langs[#langs + 1] = lang
    end
  end
  table.sort(langs)
  return langs
end

---@param uri string
---@param lang string
---@param data { title: string?, body: string, backend: string?, model: string? }
---@return boolean ok
---@return string? err
function M.save(uri, lang, data)
  local path, err = M.path(uri, lang)
  if not path then
    return false, err
  end

  local entry = cache.get(uri)
  local meta = {
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    backend = data.backend or "unknown",
    model = data.model,
    title = data.title,
    -- The revision this describes. Everything about staleness derives from it.
    issue_updated_at = entry and entry.issue and entry.issue.updated_at or nil,
  }

  local content = ("---\n%s---\n\n%s\n"):format(yaml.encode(meta), vim.trim(data.body or ""))
  local ok, werr = fs.write(path, content)
  if not ok then
    return false, werr
  end

  -- Keep it findable: translations are prose the user accumulated, which is
  -- exactly what the full-text index is for.
  if entry and entry.issue then
    require("issuehub.core.index").get():put(entry.issue)
  end
  return true
end

---@param uri string
---@param lang string
---@return boolean deleted
function M.delete(uri, lang)
  local path = M.path(uri, lang)
  if not path or not fs.exists(path) then
    return false
  end
  vim.uv.fs_unlink(path)
  return true
end

---All translated prose for an issue, for full-text indexing.
---@param uri string
---@return string
function M.searchable_text(uri)
  local chunks = {}
  for _, lang in ipairs(M.languages(uri)) do
    local translation = M.get(uri, lang)
    if translation then
      chunks[#chunks + 1] = translation.title
      chunks[#chunks + 1] = translation.body
    end
  end
  return table.concat(chunks, "\n\n")
end

---The request a Backend receives for a translation.
---@param uri string
---@param lang string
---@param opts { include_comments: boolean? }?
---@return issuehub.Request?
---@return string? err
function M.request(uri, lang, opts)
  opts = opts or {}
  local normalized, err = M.normalize_lang(lang)
  if not normalized then
    return nil, err
  end

  local entry = cache.get(uri)
  if not entry or not entry.issue then
    return nil, ("%s is not cached — open it once first"):format(uri)
  end
  local issue = entry.issue

  local documents = {
    { name = "Title", text = issue.title },
    { name = "Description", text = issue.description },
  }
  if opts.include_comments then
    for _, comment in ipairs(issue.comments or {}) do
      documents[#documents + 1] = {
        name = ("Comment by %s"):format(comment.author or "unknown"),
        text = comment.body or "",
      }
    end
  end

  return {
    kind = "translate",
    resource = uri,
    prompt = ("Translate this issue into %s. Keep code, identifiers, URLs, and issue keys unchanged. "):format(
      normalized
    ) .. "Return the translated title on the first line, then a blank line, then the translated body.",
    context = { issue = issue, documents = documents },
    metadata = { target_language = normalized },
  }
end

---Split a backend reply into title and body.
---
--- The prompt asks for "title, blank line, body", but a model may just return
--- prose. Falling back to "no title, all body" keeps a usable translation
--- instead of discarding the reply.
---@param text string
---@return string title
---@return string body
function M.split_reply(text)
  local title, body = (text or ""):match("^%s*(.-)\n%s*\n(.*)$")
  if title and vim.trim(title) ~= "" and not title:find("\n") then
    return vim.trim(title), vim.trim(body)
  end
  return "", vim.trim(text or "")
end

return M
