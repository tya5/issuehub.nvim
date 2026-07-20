---@brief Attachment files: listed from the cache, fetched only when asked.
---
--- Two rules shape this module, both chosen deliberately:
---
--- **Attachments are cache, not workspace.** They live under `.state/`, which is
--- git-ignored and declared rebuildable. Binaries cannot be removed from Git
--- history once committed, and a screenshot pasted into a ticket is often more
--- sensitive than the ticket text — so this is the one part of an issue that
--- never becomes a tracked file. Deleting `.state/` stays safe: the metadata
--- comes back with the next sync and the bytes can be re-fetched.
---
--- **Nothing is fetched implicitly.** `sync` records that an attachment exists;
--- only an explicit request downloads it. On a twenty-thousand-issue tracker,
--- transferring every attachment during a sync is not a slow feature, it is a
--- different product.

local fs = require("issuehub.util.fs")
local issue_mod = require("issuehub.core.issue")
local repository = require("issuehub.core.repository")

local M = {}

---@class issuehub.StoredAttachment : issuehub.Attachment
---@field path string        Where it would live, whether or not it is there.
---@field downloaded boolean
---@field bytes integer?     Actual size on disk, once downloaded.

---Make a tracker-supplied filename safe to use as one path segment.
---
--- The filename comes from a remote system and lands on the filesystem, so this
--- is a path-traversal guard first and cosmetics second: an attachment named
--- `../../../.ssh/authorized_keys` must not escape, and one named `.bashrc`
--- must not hide. Everything is reduced to a single segment; if nothing usable
--- survives, the caller gets nil rather than a guessed name.
---@param name string?
---@return string? safe
function M.safe_filename(name)
  if type(name) ~= "string" then
    return nil
  end
  -- Both separators, because a Windows-authored name reaches a Unix client.
  local base = name:gsub("\\", "/"):match("([^/]*)$") or ""
  base = base:gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if base == "" or base == "." or base == ".." then
    return nil
  end
  -- A leading dot would hide the file from the very listing the user is about
  -- to look at.
  base = base:gsub("^%.+", "")
  if base == "" then
    return nil
  end
  return #base > 120 and base:sub(1, 120) or base
end

---Directory holding one issue's downloaded attachments.
---@param uri string
---@return string? dir
---@return string? err
function M.dir(uri)
  local provider, id = issue_mod.parse(uri)
  if not provider then
    return nil, ("not a valid issue URI: %s"):format(tostring(uri))
  end
  return repository.state("attachments", provider, issue_mod.encode_id(id))
end

---Where one attachment is stored.
---
--- The attachment id becomes a directory of its own, so two attachments that
--- share a filename — a tracker routinely holds three `screenshot.png` — do not
--- collide, and the human-readable name is still what you see.
---@param uri string
---@param att issuehub.Attachment
---@return string? path
---@return string? err
function M.path(uri, att)
  local dir, err = M.dir(uri)
  if not dir then
    return nil, err
  end
  local name = M.safe_filename(att.filename)
  if not name then
    return nil, ("unusable attachment filename: %q"):format(tostring(att.filename))
  end
  return vim.fs.joinpath(dir, issue_mod.encode_id(tostring(att.id)), name)
end

---What the tracker says this issue has, plus what is already on disk.
---@param uri string
---@return issuehub.StoredAttachment[]
function M.list(uri)
  local entry = require("issuehub.core.cache").get(uri)
  if not entry then
    return {}
  end

  local out = {}
  for _, att in ipairs(entry.issue.attachments or {}) do
    local path = M.path(uri, att)
    if path then
      local stat = vim.uv.fs_stat(path)
      local stored = vim.tbl_extend("force", att, {
        path = path,
        downloaded = stat ~= nil,
        bytes = stat and stat.size or nil,
      })
      out[#out + 1] = stored
    end
  end
  return out
end

---@param uri string
---@param id string
---@return issuehub.StoredAttachment?
function M.get(uri, id)
  for _, att in ipairs(M.list(uri)) do
    if att.id == tostring(id) then
      return att
    end
  end
  return nil
end

---Fetch one attachment's bytes.
---
--- The URL is fetched with the owning provider's credentials: an attachment
--- link is as protected as the issue it hangs off, and an unauthenticated GET
--- would quietly return a login page that then sits on disk pretending to be a
--- PDF.
---@param uri string
---@param att issuehub.StoredAttachment
---@param cb fun(err: string?, path: string?)
function M.fetch(uri, att, cb)
  if att.downloaded then
    return cb(nil, att.path)
  end

  local provider, perr = require("issuehub.provider").get(select(1, issue_mod.parse(uri)))
  if not provider then
    return cb(perr)
  end
  if not provider.attachment_request then
    return cb(("%s does not support attachments"):format(provider.name))
  end

  local req, rerr = provider:attachment_request(att)
  if not req then
    return cb(rerr or "could not build the download request")
  end

  local path = att.path
  local ok, derr = fs.mkdirp(vim.fs.dirname(path))
  if not ok then
    return cb(derr)
  end

  local max_size = require("issuehub.config").get().attachments.max_size
  require("issuehub.util.http").download(req, path, { max_size = max_size }, cb)
end

---Drop every downloaded file for an issue. The metadata is untouched — this is
---a cache, and reclaiming it must never look like losing data.
---@param uri string
---@return integer removed
function M.purge(uri)
  local dir = M.dir(uri)
  if not dir or not fs.is_dir(dir) then
    return 0
  end
  local removed = 0
  for _, att in ipairs(M.list(uri)) do
    if att.downloaded then
      removed = removed + 1
    end
  end
  vim.fn.delete(dir, "rf")
  return removed
end

---@param bytes integer?
---@return string
function M.human_size(bytes)
  if not bytes then
    return "?"
  end
  local units = { "B", "KB", "MB", "GB" }
  local n, i = bytes, 1
  while n >= 1024 and i < #units do
    n, i = n / 1024, i + 1
  end
  return i == 1 and ("%d %s"):format(n, units[i]) or ("%.1f %s"):format(n, units[i])
end

return M
