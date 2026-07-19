---@brief Overlay: the local knowledge attached to an issue (§7).
---
--- Never written back to the provider. Files are stored as the user typed them —
--- writeback is verbatim buffer text — so comments, key order, and formatting in
--- metadata.yaml survive untouched. `parsed()` exists for reading only.

local fs = require("issuehub.util.fs")
local repository = require("issuehub.core.repository")
local yaml = require("issuehub.util.yaml")

local M = {}

---@class issuehub.Overlay
---@field memo string
---@field metadata string    Raw YAML text, as edited.
---@field prompt string

local FILES = {
  memo = "memo.md",
  metadata = "metadata.yaml",
  prompt = "prompt.md",
}

---@param uri string
---@param field string
---@return string? path
function M.path(uri, field)
  local dir = repository.issue_dir(uri)
  if not dir or not FILES[field] then
    return nil
  end
  return vim.fs.joinpath(dir, FILES[field])
end

---Read the overlay. Absent files are empty strings, never nil: the caller is
---rendering a buffer and an empty section is the correct representation of
---"nothing written yet".
---@param uri string
---@return issuehub.Overlay
function M.read(uri)
  local overlay = {}
  for field in pairs(FILES) do
    local path = M.path(uri, field)
    local content = path and fs.read(path) or nil
    -- Trailing newlines are normalized away here and re-added on write, so a
    -- round trip through the buffer does not accumulate blank lines.
    overlay[field] = content and (content:gsub("\n+$", "")) or ""
  end
  return overlay
end

---Write only the fields whose content actually changed.
---
--- Writing unconditionally would touch mtimes and produce empty Git diffs on
--- every `:w`, which matters because this directory is meant to be committed.
---@param uri string
---@param overlay table  Any subset of memo / metadata / prompt.
---@return string[] written  Field names that were written.
---@return string? err
function M.write(uri, overlay)
  local current = M.read(uri)
  local written = {}

  for field, value in pairs(overlay) do
    if FILES[field] and type(value) == "string" then
      local normalized = value:gsub("\n+$", "")
      if normalized ~= current[field] then
        local path = M.path(uri, field)
        if not path then
          return written, ("cannot resolve a path for %s"):format(uri)
        end

        if normalized == "" then
          -- An emptied section removes the file rather than leaving a stub, so
          -- the tree only contains issues that actually have notes.
          if fs.exists(path) then
            vim.uv.fs_unlink(path)
            written[#written + 1] = field
          end
        else
          local ok, err = fs.write(path, normalized .. "\n")
          if not ok then
            return written, err
          end
          written[#written + 1] = field
        end
      end
    end
  end

  return written
end

---Parsed metadata, for search, filtering, and export.
---@param uri string
---@return table
function M.metadata(uri)
  return yaml.parse(M.read(uri).metadata)
end

---The overlay text a picker should match against, as one blob.
---
--- Analyses are excluded deliberately: they are long, and matching a picker
--- query against a page of generated prose produces hits the user cannot see
--- the reason for. `:IssueHub find` still searches them.
---@param uri string
---@return string
function M.searchable(uri)
  local overlay = M.read(uri)
  if overlay.memo == "" and overlay.metadata == "" then
    return ""
  end
  return (overlay.memo .. " " .. overlay.metadata):gsub("%s+", " ")
end

---Whether an issue has any overlay content at all.
---@param uri string
---@return boolean
function M.exists(uri)
  local overlay = M.read(uri)
  return overlay.memo ~= "" or overlay.metadata ~= "" or overlay.prompt ~= ""
end

return M
