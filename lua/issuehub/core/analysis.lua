---@brief Analysis history (§11, §12).
---
--- Every analysis is kept: prompt, response, and the revision of the issue it
--- was made against. Staleness is DERIVED from that revision, never stored as a
--- mutable flag — so it cannot go wrong after a manual edit, a Git revert, or a
--- sync that happened while Neovim was closed.

local cache = require("issuehub.core.cache")
local fs = require("issuehub.util.fs")
local overlay = require("issuehub.core.overlay")
local repository = require("issuehub.core.repository")
local yaml = require("issuehub.util.yaml")

local M = {}

---@class issuehub.Analysis
---@field uri string
---@field stamp string          Directory name: YYYY-MM-DDTHH-MM-SSZ
---@field prompt string
---@field response string
---@field created_at string
---@field backend string?
---@field model string?
---@field issue_updated_at string?
---@field status "current"|"outdated"|"unknown"

---Colons are illegal in Windows filenames and awkward in shells, so the time
---component uses dashes. Still sorts lexicographically.
---@return string
function M.stamp()
  return os.date("!%Y-%m-%dT%H-%M-%SZ") --[[@as string]]
end

---@param uri string
---@return string? path
function M.dir(uri)
  local dir = repository.subject_dir(uri)
  return dir and vim.fs.joinpath(dir, "analyses") or nil
end

---@param uri string
---@param stamp string
---@return string? path
local function entry_dir(uri, stamp)
  local dir = M.dir(uri)
  return dir and vim.fs.joinpath(dir, stamp) or nil
end

---Whether an analysis still describes the issue as it is now.
---
--- Derived, never stored: comparing the recorded revision against the cached one
--- means the answer is always consistent with what is actually on disk.
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

---@param uri string
---@param stamp string
---@return issuehub.Analysis?
function M.get(uri, stamp)
  local dir = entry_dir(uri, stamp)
  if not dir or not fs.is_dir(dir) then
    return nil
  end

  local meta = yaml.parse(fs.read(vim.fs.joinpath(dir, "metadata.yaml")) or "")
  return {
    uri = uri,
    stamp = stamp,
    prompt = (fs.read(vim.fs.joinpath(dir, "prompt.md")) or ""):gsub("\n+$", ""),
    response = (fs.read(vim.fs.joinpath(dir, "response.md")) or ""):gsub("\n+$", ""),
    created_at = meta.created_at or stamp,
    backend = meta.backend,
    model = meta.model,
    issue_updated_at = meta.issue_updated_at,
    status = M.status(uri, meta.issue_updated_at),
  }
end

---Newest first.
---@param uri string
---@return issuehub.Analysis[]
function M.list(uri)
  local dir = M.dir(uri)
  if not dir or not fs.is_dir(dir) then
    return {}
  end

  local stamps = {}
  for _, name in ipairs(fs.list(dir)) do
    if fs.is_dir(vim.fs.joinpath(dir, name)) then
      stamps[#stamps + 1] = name
    end
  end
  table.sort(stamps, function(a, b)
    return a > b
  end)

  local out = {}
  for _, stamp in ipairs(stamps) do
    local analysis = M.get(uri, stamp)
    if analysis then
      out[#out + 1] = analysis
    end
  end
  return out
end

---@param uri string
---@return issuehub.Analysis?
function M.latest(uri)
  return M.list(uri)[1]
end

---@param uri string
---@param data { prompt: string, response: string, backend: string?, model: string? }
---@return string? stamp
---@return string? err
function M.save(uri, data)
  local stamp = M.stamp()
  local dir = entry_dir(uri, stamp)
  if not dir then
    return nil, ("cannot resolve a path for %s"):format(uri)
  end

  local entry = cache.get(uri)
  local metadata = {
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    backend = data.backend or "unknown",
    model = data.model,
    -- The revision this describes. Everything about staleness derives from it.
    issue_updated_at = entry and entry.issue and entry.issue.updated_at or nil,
    prompt_source = data.prompt_source or "workspace",
  }

  local ok, err = fs.write(vim.fs.joinpath(dir, "prompt.md"), data.prompt .. "\n")
  if not ok then
    return nil, err
  end
  ok, err = fs.write(vim.fs.joinpath(dir, "response.md"), data.response .. "\n")
  if not ok then
    return nil, err
  end
  ok, err = fs.write(vim.fs.joinpath(dir, "metadata.yaml"), yaml.encode(metadata))
  if not ok then
    return nil, err
  end

  -- Re-index so the new analysis is searchable immediately (§15).
  if entry and entry.issue then
    require("issuehub.core.index").get():put(entry.issue)
  end

  return stamp
end

---All analysis prose for an issue, for full-text indexing.
---
---Prompts are included as well as responses: "what did I ask about this" is a
---reasonable thing to search for later.
---@param uri string
---@return string
function M.searchable_text(uri)
  local chunks = {}
  for _, entry in ipairs(M.list(uri)) do
    chunks[#chunks + 1] = entry.prompt
    chunks[#chunks + 1] = entry.response
  end
  return table.concat(chunks, "\n\n")
end

---Build the request context for an issue: the cached issue plus the overlay.
---@param uri string
---@param opts { selection: string?, include_history: boolean? }?
---@return issuehub.RequestContext
function M.context(uri, opts)
  opts = opts or {}
  local entry = cache.get(uri)

  local documents = {}
  if opts.include_history then
    -- Only the most recent, and only when still current: feeding an outdated
    -- analysis back in propagates its staleness.
    local previous = M.latest(uri)
    if previous and previous.status == "current" then
      documents[#documents + 1] = { name = "Previous analysis", text = previous.response }
    end
  end

  return {
    issue = entry and entry.issue or nil,
    overlay = overlay.read(uri),
    selection = opts.selection,
    documents = documents,
  }
end

---The prompt to send: the issue's own prompt.md, or a default.
---@param uri string
---@return string prompt
---@return string source  "workspace" | "default"
function M.prompt_for(uri)
  local written = overlay.read(uri).prompt
  if written ~= "" then
    return written, "workspace"
  end
  return "Summarise this issue, identify the likely root cause, and list what to check next.", "default"
end

return M
