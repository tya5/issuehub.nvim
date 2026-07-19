---@brief Minimal YAML subset (§12).
---
--- Deliberately not a full YAML implementation. It covers what hand-written
--- metadata actually contains: scalars, lists of scalars, and one level of
--- nesting.
---
--- Round-trip fidelity is NOT this module's job. Overlay files are written back
--- verbatim from the buffer text the user edited, so unknown keys, comments,
--- ordering, and formatting survive untouched. Parsing exists only for reading —
--- filtering, search, and export.

local M = {}

---@param value string
---@return any
local function scalar(value)
  value = vim.trim(value)

  if value == "" or value == "~" or value == "null" then
    return nil
  end
  if value == "true" then
    return true
  end
  if value == "false" then
    return false
  end

  -- Quoted: take verbatim, so "true" and "123" stay strings.
  local quoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
  if quoted then
    return quoted
  end

  local number = tonumber(value)
  if number then
    return number
  end

  -- Strip a trailing comment, but only when it is clearly one.
  local without_comment = value:match("^(.-)%s+#.*$")
  return vim.trim(without_comment or value)
end

---@param text string?
---@return table
function M.parse(text)
  local out = {}
  if not text or text == "" then
    return out
  end

  local current_key, current_list, current_map = nil, nil, nil

  for _, line in ipairs(vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })) do
    local indent = #(line:match("^(%s*)") or "")
    local trimmed = vim.trim(line)

    if trimmed == "" or trimmed:match("^#") or trimmed == "---" then
      goto continue
    end

    local item = trimmed:match("^%-%s*(.*)$")
    if item and indent > 0 and current_key then
      current_list = current_list or {}
      current_list[#current_list + 1] = scalar(item)
      out[current_key] = current_list
      goto continue
    end

    local key, value = trimmed:match("^([%w%._%-]+):%s*(.*)$")
    if key then
      if indent > 0 and current_key then
        -- One level of nesting: `parent:` followed by indented `key: value`.
        current_map = current_map or {}
        current_map[key] = scalar(value)
        out[current_key] = current_map
      else
        current_key, current_list, current_map = key, nil, nil
        if value ~= "" then
          out[key] = scalar(value)
          current_key = nil
        else
          -- Value may be a list or map on the following lines; if nothing
          -- follows, it stays an empty string rather than vanishing.
          out[key] = ""
        end
      end
    end

    ::continue::
  end

  return out
end

---@param value any
---@return string
local function emit_scalar(value)
  if type(value) == "boolean" or type(value) == "number" then
    return tostring(value)
  end
  local s = tostring(value)
  -- Quote anything that would otherwise parse back as a different type or
  -- break the line structure.
  if s == "" or s:match("^[%d%.%-]+$") or s == "true" or s == "false" or s:match("[:#]") or s ~= vim.trim(s) then
    return '"' .. s:gsub('"', '\\"') .. '"'
  end
  return s
end

---Serialize a flat-ish table. Keys are sorted so machine-written files (such as
---state.yaml) produce stable diffs in Git.
---@param tbl table
---@return string
function M.encode(tbl)
  local keys = vim.tbl_keys(tbl)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local lines = {}
  for _, key in ipairs(keys) do
    local value = tbl[key]
    if type(value) == "table" then
      if vim.islist(value) then
        lines[#lines + 1] = key .. ":"
        for _, item in ipairs(value) do
          lines[#lines + 1] = "  - " .. emit_scalar(item)
        end
      else
        lines[#lines + 1] = key .. ":"
        local sub = vim.tbl_keys(value)
        table.sort(sub)
        for _, k in ipairs(sub) do
          lines[#lines + 1] = "  " .. k .. ": " .. emit_scalar(value[k])
        end
      end
    elseif value ~= nil then
      lines[#lines + 1] = key .. ": " .. emit_scalar(value)
    end
  end

  return table.concat(lines, "\n") .. "\n"
end

return M
