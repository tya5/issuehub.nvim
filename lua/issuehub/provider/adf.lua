---@brief Minimal Atlassian Document Format → Markdown converter (§23.2).
---
--- Deliberately a subset. Jira Cloud returns rich JSON for descriptions and
--- comments; chasing complete ADF fidelity is unbounded work for a read-only
--- view. Unsupported nodes render as a visible marker rather than vanishing, and
--- the untouched payload always remains in `issue.raw`.

local M = {}

local convert

---@param marks table[]?
---@param text string
---@return string
local function apply_marks(marks, text)
  for _, mark in ipairs(marks or {}) do
    local t = mark.type
    if t == "strong" then
      text = "**" .. text .. "**"
    elseif t == "em" then
      text = "*" .. text .. "*"
    elseif t == "code" then
      text = "`" .. text .. "`"
    elseif t == "strike" then
      text = "~~" .. text .. "~~"
    elseif t == "link" and mark.attrs and mark.attrs.href then
      text = ("[%s](%s)"):format(text, mark.attrs.href)
    end
  end
  return text
end

---@param nodes table[]?
---@param sep string?
---@return string
local function convert_all(nodes, sep)
  local parts = {}
  for _, node in ipairs(nodes or {}) do
    parts[#parts + 1] = convert(node)
  end
  return table.concat(parts, sep or "")
end

---@param node table
---@param depth integer?
---@return string
function convert(node, depth)
  depth = depth or 0
  local t = node.type
  local attrs = node.attrs or {}

  if t == "doc" then
    return convert_all(node.content, "\n\n")
  elseif t == "paragraph" then
    return convert_all(node.content)
  elseif t == "text" then
    return apply_marks(node.marks, node.text or "")
  elseif t == "hardBreak" then
    return "\n"
  elseif t == "heading" then
    return ("%s %s"):format(("#"):rep(attrs.level or 1), convert_all(node.content))
  elseif t == "codeBlock" then
    return ("```%s\n%s\n```"):format(attrs.language or "", convert_all(node.content))
  elseif t == "blockquote" then
    local inner = convert_all(node.content, "\n\n")
    return (inner:gsub("[^\n]+", function(line)
      return "> " .. line
    end))
  elseif t == "rule" then
    return "---"
  elseif t == "bulletList" or t == "orderedList" then
    local lines = {}
    for i, item in ipairs(node.content or {}) do
      local marker = t == "bulletList" and "- " or (i .. ". ")
      local body = convert(item, depth + 1)
      lines[#lines + 1] = ("  "):rep(depth) .. marker .. body
    end
    return table.concat(lines, "\n")
  elseif t == "listItem" then
    return convert_all(node.content, "\n")
  elseif t == "mention" then
    return "@" .. (attrs.text or attrs.displayName or "unknown"):gsub("^@", "")
  elseif t == "emoji" then
    return attrs.text or attrs.shortName or ""
  elseif t == "inlineCard" then
    return attrs.url or "[card]"
  elseif t == "mediaSingle" or t == "mediaGroup" then
    return "[media]"
  elseif t == "table" then
    local rows = {}
    for i, row in ipairs(node.content or {}) do
      local cells = {}
      for _, cell in ipairs(row.content or {}) do
        cells[#cells + 1] = convert_all(cell.content):gsub("\n", " ")
      end
      rows[#rows + 1] = "| " .. table.concat(cells, " | ") .. " |"
      if i == 1 then
        rows[#rows + 1] = "|" .. (" --- |"):rep(#cells)
      end
    end
    return table.concat(rows, "\n")
  end

  return ("[Unsupported ADF node: %s]"):format(tostring(t))
end

---Convert an ADF document to Markdown. Plain strings pass through untouched,
---so this is safe to call on Jira Server payloads too.
---@param doc table|string|nil
---@return string
function M.to_markdown(doc)
  if doc == nil then
    return ""
  end
  if type(doc) == "string" then
    return doc
  end
  if type(doc) ~= "table" or not doc.type then
    return ""
  end
  local ok, out = pcall(convert, doc)
  if not ok then
    return "[ADF conversion failed]"
  end
  return vim.trim(out)
end

return M
