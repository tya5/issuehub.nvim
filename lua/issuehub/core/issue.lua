---@brief Canonical Issue model and URI grammar (§4).
local M = {}

---Characters unsafe in a path segment or a URI. Encoded per RFC 3986.
local UNSAFE = "[^%w%-%._~]"

---@param id string
---@return string
function M.encode_id(id)
  return (id:gsub(UNSAFE, function(c)
    return ("%%%02X"):format(string.byte(c))
  end))
end

---@param encoded string
---@return string
function M.decode_id(encoded)
  return (encoded:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@param provider string
---@param id string
---@return string uri
function M.uri(provider, id)
  return ("%s://%s"):format(provider, M.encode_id(id))
end

---@param uri string
---@return string? provider
---@return string? id  Decoded back to the provider's own form.
function M.parse(uri)
  local provider, encoded = uri:match("^([%w%-_]+)://(.+)$")
  if not provider then
    return nil, nil
  end
  return provider, M.decode_id(encoded)
end

---@param uri string
---@return boolean
function M.is_uri(uri)
  return type(uri) == "string" and M.parse(uri) ~= nil
end

---Normalize an ISO 8601 timestamp to UTC "YYYY-MM-DDTHH:MM:SSZ".
---Providers are inconsistent here (Jira emits +0900 offsets, Redmine emits Z),
---and the index sorts these lexicographically, so normalization is required.
---@param ts string?
---@return string
function M.timestamp(ts)
  if not ts or ts == "" then
    return ""
  end
  local y, mo, d, h, mi, s = ts:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if not y then
    return ts
  end

  local offset = 0
  local sign, oh, om = ts:match("([%+%-])(%d%d):?(%d%d)$")
  if sign then
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end

  -- os.time() interprets the table as local time, so correct by the local
  -- offset as well to land on a true UTC instant.
  local local_epoch = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  local local_offset = os.difftime(local_epoch, os.time(os.date("!*t", local_epoch) --[[@as osdateparam]]))
  return os.date("!%Y-%m-%dT%H:%M:%SZ", local_epoch + local_offset - offset) --[[@as string]]
end

---@param status issuehub.Status?
---@return issuehub.Status
function M.status(status)
  status = status or {}
  return {
    id = tostring(status.id or "unknown"),
    name = tostring(status.name or status.id or "Unknown"),
    closed = status.closed == true,
  }
end

---Fill in every field so downstream code never has to nil-check.
---@param issue table
---@return issuehub.Issue
function M.normalize(issue)
  return {
    uri = issue.uri or M.uri(issue.provider, issue.id),
    provider = issue.provider,
    -- Providers supply this; there is no cross-tracker way to infer it, and
    -- guessing from the id would be wrong for at least one of them.
    project = issue.project,
    id = tostring(issue.id),
    title = issue.title or "",
    description = issue.description or "",
    status = M.status(issue.status),
    assignee = issue.assignee,
    reporter = issue.reporter,
    labels = issue.labels or {},
    url = issue.url,
    comments = issue.comments or {},
    created_at = M.timestamp(issue.created_at),
    updated_at = M.timestamp(issue.updated_at),
    -- Only meaningful once closed; nil is the honest value while open, and an
    -- empty cell is what a spreadsheet wants for "not yet".
    closed_at = issue.closed_at and M.timestamp(issue.closed_at) or nil,
    raw = issue.raw or {},
  }
end

---Project an Issue down to the flat shape the picker and index consume (§9.3).
---@param issue issuehub.Issue
---@param bookmarked boolean?
---@return issuehub.ViewItem
function M.to_item(issue, bookmarked)
  return {
    uri = issue.uri,
    id = issue.id,
    project = issue.project,
    title = issue.title,
    status = issue.status.name,
    closed = issue.status.closed,
    assignee = issue.assignee,
    updated_at = issue.updated_at,
    bookmarked = bookmarked == true,
  }
end

return M
