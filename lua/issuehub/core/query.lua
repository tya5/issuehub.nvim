---@brief Parsing for `:IssueHub find` (§15).
---
--- One parser, used by the subcommand and by the `Find:` prompt, so the two
--- entry points cannot drift the way they did once before.

local M = {}

---@class issuehub.FindQuery
---@field pattern string          Free text; may be empty when only filtering.
---@field regex boolean
---@field meta issuehub.MetaFilter[]

---@class issuehub.MetaFilter
---@field key string
---@field value string?           nil means "the key is present at all".

---Split on whitespace, keeping quoted runs together.
---@param input string
---@return string[]
local function tokenize(input)
  local tokens = {}
  local i = 1
  while i <= #input do
    local char = input:sub(i, i)
    if char:match("%s") then
      i = i + 1
    elseif char == '"' or char == "'" then
      local close = input:find(char, i + 1, true)
      if close then
        tokens[#tokens + 1] = input:sub(i + 1, close - 1)
        i = close + 1
      else
        tokens[#tokens + 1] = input:sub(i + 1)
        break
      end
    else
      local next_space = input:find("%s", i) or (#input + 1)
      tokens[#tokens + 1] = input:sub(i, next_space - 1)
      i = next_space
    end
  end
  return tokens
end

---@param input string|string[]
---@return issuehub.FindQuery
function M.parse(input)
  local tokens = type(input) == "table" and input or tokenize(input)

  local query = { pattern = "", regex = false, meta = {} }
  local words = {}
  local i = 1

  while i <= #tokens do
    local token = tokens[i]

    if token == "--regex" then
      query.regex = true
    elseif token == "--meta" then
      -- `--meta priority=high`, or `--meta priority = high` after the prompt
      -- helpfully split it; both are what a person actually types.
      local rest = tokens[i + 1]
      if rest then
        i = i + 1
        if rest == "=" then
          rest = (tokens[i + 1] or "")
          i = i + 1
        end
        local key, value = rest:match("^([^=]+)=(.*)$")
        if not key then
          key = rest
          if tokens[i + 1] == "=" then
            value = tokens[i + 2] or ""
            i = i + 2
          end
        end
        query.meta[#query.meta + 1] = {
          key = vim.trim(key),
          value = value and vim.trim(value) ~= "" and vim.trim(value) or nil,
        }
      end
    elseif token:match("^%-%-meta=") then
      local pair = token:sub(8)
      local key, value = pair:match("^([^=]+)=(.*)$")
      query.meta[#query.meta + 1] = { key = key or pair, value = value ~= "" and value or nil }
    else
      words[#words + 1] = token
    end

    i = i + 1
  end

  query.pattern = table.concat(words, " ")
  return query
end

---@param actual any     A parsed metadata value: scalar, or a list.
---@param expected string
---@return boolean
local function value_matches(actual, expected)
  local want = expected:lower()

  if type(actual) == "table" then
    -- `tags: [timeout, cache]` matches `--meta tags=cache`.
    for _, item in ipairs(actual) do
      if tostring(item):lower() == want then
        return true
      end
    end
    return false
  end

  return tostring(actual):lower() == want
end

---Whether an issue's metadata satisfies every filter.
---@param uri string
---@param filters issuehub.MetaFilter[]
---@return boolean
function M.matches_meta(uri, filters)
  if #filters == 0 then
    return true
  end

  local metadata = require("issuehub.core.overlay").metadata(uri)
  for _, filter in ipairs(filters) do
    local actual = metadata[filter.key]
    if actual == nil or actual == "" then
      return false
    end
    if filter.value and not value_matches(actual, filter.value) then
      return false
    end
  end
  return true
end

---Human-readable form, for picker titles and messages.
---@param query issuehub.FindQuery
---@return string
function M.describe(query)
  local parts = {}
  if query.pattern ~= "" then
    parts[#parts + 1] = query.pattern
  end
  for _, filter in ipairs(query.meta) do
    parts[#parts + 1] = filter.value and ("%s=%s"):format(filter.key, filter.value) or ("%s?"):format(filter.key)
  end
  return table.concat(parts, " ")
end

return M
