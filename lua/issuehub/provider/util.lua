---@brief Shared plumbing for HTTP-backed providers.
---
--- Extracted once there were four providers repeating the same request/auth
--- boilerplate. It deliberately holds no knowledge of any specific API — each
--- provider still owns its own endpoints, payload mapping, and `closed`
--- derivation.

local config = require("issuehub.config")

local M = {}

---@class issuehub.ProviderCtx
---@field name string          Provider name, used for credential lookup.
---@field base string          Base URL, no trailing slash.
---@field http table           Injectable transport (specs substitute a fake).
---@field auth fun(token: string): table  Returns { auth = … } or { headers = … }.

---Normalize a configured URL: strip trailing slashes so path joins are safe.
---@param url string
---@return string
function M.base_url(url)
  return (url:gsub("/+$", ""))
end

---Issue a request, resolving the credential first.
---
--- Credentials are resolved per call rather than cached on the provider so a
--- rotated token takes effect without a restart; config.token() memoizes for the
--- session, so this is not a repeated subprocess spawn.
---@param ctx issuehub.ProviderCtx
---@param path string
---@param opts { method: string?, query: table?, body: table|string?, headers: table? }?
---@param cb fun(err: string?, body: table?, res: table?)
function M.call(ctx, path, opts, cb)
  opts = opts or {}

  local token, terr = config.token(ctx.name)
  if not token then
    return cb(terr)
  end

  local credentials = ctx.auth(token)
  local headers =
    vim.tbl_extend("force", { Accept = "application/json" }, opts.headers or {}, credentials.headers or {})

  ctx.http.request({
    method = opts.method or "GET",
    url = ctx.base .. path,
    query = opts.query,
    body = opts.body,
    auth = credentials.auth,
    headers = headers,
  }, function(err, res)
    if err then
      return cb(err, nil, res)
    end
    local body, jerr = res:json()
    if not body then
      return cb(jerr, nil, res)
    end
    cb(nil, body, res)
  end)
end

---Percent-encode a value for use in a single URL path segment.
---
--- Distinct from issue.encode_id: that one produces a *storage* key, this one
--- produces a URL. They coincide today but are not the same concern.
---@param value string
---@return string
function M.path_segment(value)
  return (value:gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(string.byte(c))
  end))
end

---Standard health line for a configured provider.
---@param ctx issuehub.ProviderCtx
---@param detail string?
---@return boolean ok
---@return string msg
function M.health(ctx, detail)
  local ok, msg = config.token_status(ctx.name)
  if not ok then
    return false, msg
  end
  return true, ("%s%s, credential %s"):format(ctx.base, detail and (" " .. detail) or "", msg)
end

return M
