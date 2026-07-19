---@brief Local search: the ripgrep path (§15).
---
--- Complementary to the index, not redundant with it. FTS5 ranks whole documents
--- by relevance; ripgrep finds exact lines and regexes, and reaches text the
--- index does not hold (analysis history, the full cached description). `find`
--- uses whichever is available; `--regex` forces this path.

local repository = require("issuehub.core.repository")
local fs = require("issuehub.util.fs")

local M = {}

---Which overlay file a hit came from, for the "why did this match" column.
local FIELD_OF = {
  ["memo.md"] = "memo",
  ["metadata.yaml"] = "metadata",
  ["prompt.md"] = "prompt",
  ["response.md"] = "analysis",
  ["state.yaml"] = "state",
}

---@return boolean
function M.available()
  return vim.fn.executable("rg") == 1
end

---Map an absolute path inside the Repository back to a URI and a field.
---@param root string
---@param path string
---@return string? uri
---@return string? field
function M.locate(root, path)
  local relative = path:sub(#root + 2)

  -- .state/cache/<provider>/<encoded>.json
  local provider, encoded = relative:match("^%.state/cache/([^/]+)/(.+)%.json$")
  if provider then
    return ("%s://%s"):format(provider, encoded), "issue"
  end

  -- <provider>/<encoded>/<file>  (overlay and analyses)
  local p, e, rest = relative:match("^([^%./][^/]*)/([^/]+)/(.+)$")
  if p then
    local basename = vim.fs.basename(rest)
    return ("%s://%s"):format(p, e), FIELD_OF[basename] or (rest:match("^analyses/") and "analysis" or basename)
  end

  return nil, nil
end

---@class issuehub.SearchHit
---@field uri string
---@field field string     Where it matched: issue, memo, metadata, prompt, analysis.
---@field line string      The matching line, trimmed.

---Run ripgrep across the cache and the Workspace.
---@param pattern string
---@param opts { regex: boolean?, max: integer? }?
---@return issuehub.SearchHit[] hits
---@return string? err
function M.grep(pattern, opts)
  opts = opts or {}

  if not M.available() then
    return {}, "ripgrep (rg) is not installed"
  end

  local root = repository.root()
  if not root or not fs.is_dir(root) then
    return {}, "workspace does not exist yet"
  end

  local cmd = {
    "rg",
    "--json",
    "--smart-case",
    -- `.state/` is both a dot-directory and git-ignored, so ripgrep would skip
    -- it by default — silently excluding every cached issue body from search.
    "--hidden",
    "--no-ignore-vcs",
    "--glob",
    "!.git/",
    "--max-count",
    tostring(opts.max or 5),
    -- Fixed-string unless the caller asked for a regex, so a search for
    -- "cache.warmup" does not silently become a pattern.
    opts.regex and "--regexp" or "--fixed-strings",
    pattern,
    "--",
    root,
  }

  local out = vim.system(cmd, { text = true }):wait()
  -- rg exits 1 when there are simply no matches; that is not an error.
  if out.code ~= 0 and out.code ~= 1 then
    return {}, vim.trim(out.stderr or "ripgrep failed")
  end

  local hits, seen = {}, {}
  for _, line in ipairs(vim.split(out.stdout or "", "\n", { plain = true })) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and event.type == "match" then
        local path = event.data.path and event.data.path.text
        if path then
          local uri, field = M.locate(root, path)
          local key = uri and (uri .. "\30" .. tostring(field))
          if uri and not seen[key] then
            seen[key] = true
            hits[#hits + 1] = {
              uri = uri,
              field = field or "?",
              line = vim.trim((event.data.lines and event.data.lines.text or ""):gsub("%s+", " ")),
            }
          end
        end
      end
    end
  end

  return hits
end

---Search locally and return picker-ready items annotated with what matched.
---@param pattern string
---@param opts { regex: boolean? }?
---@return issuehub.ViewItem[] items
---@return string? err
function M.find(pattern, opts)
  local hits, err = M.grep(pattern, opts)
  if err then
    return {}, err
  end

  local index = require("issuehub.core.index").get()
  local known = {}
  for _, item in ipairs(index:list()) do
    known[item.uri] = item
  end

  local fields_by_uri, order = {}, {}
  for _, hit in ipairs(hits) do
    if not fields_by_uri[hit.uri] then
      fields_by_uri[hit.uri] = {}
      order[#order + 1] = hit.uri
    end
    if not vim.tbl_contains(fields_by_uri[hit.uri], hit.field) then
      table.insert(fields_by_uri[hit.uri], hit.field)
    end
  end

  local items = {}
  for _, uri in ipairs(order) do
    local item = vim.deepcopy(known[uri] or {
      uri = uri,
      id = select(2, require("issuehub.core.issue").parse(uri)) or uri,
      title = "(not cached)",
      status = "",
      closed = false,
      updated_at = "",
      bookmarked = false,
    })
    -- Showing *why* something matched is the point of the ripgrep path.
    table.sort(fields_by_uri[uri])
    item.matched_in = table.concat(fields_by_uri[uri], ",")
    items[#items + 1] = item
  end

  return items
end

return M
