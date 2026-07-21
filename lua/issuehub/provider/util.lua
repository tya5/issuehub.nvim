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
---@field opts table?          The provider's config, for Basic-auth detection.

---Normalize a configured URL: strip trailing slashes so path joins are safe.
---@param url string
---@return string
function M.base_url(url)
  return (url:gsub("/+$", ""))
end

---Resolve a provider's credential: HTTP Basic when username + password are
---configured, otherwise the provider's token shape.
---
--- Basic is what a self-hosted Jira or Redmine that never issues tokens
--- requires. When both a password and a token are configured, Basic wins —
--- someone who set a username and password meant to use them.
---@param ctx issuehub.ProviderCtx
---@return table? credential  { auth = …, headers = … }
---@return string? err
function M.credential(ctx)
  local opts = ctx.opts or {}
  if opts.user and config.password_configured(ctx.name) then
    local auth, err = config.basic_auth(ctx.name)
    if not auth then
      return nil, err or "basic auth password unresolved"
    end
    return { auth = auth }
  end
  local token, terr = config.token(ctx.name)
  if not token then
    return nil, terr
  end
  return ctx.auth(token)
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

  local credentials, terr = M.credential(ctx)
  if not credentials then
    return cb(terr)
  end

  local headers =
    vim.tbl_extend("force", { Accept = "application/json" }, opts.headers or {}, credentials.headers or {})

  ctx.http.request({
    method = opts.method or "GET",
    url = ctx.base .. path,
    query = opts.query,
    body = opts.body,
    auth = credentials.auth,
    headers = headers,
    -- Per-provider proxy/TLS overrides layered on the global block, so an
    -- internal tracker reached directly and a SaaS one behind the corporate
    -- proxy can coexist.
    net = config.net(ctx.name),
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

---Extract attachments from Markdown link syntax.
---
--- GitHub and GitLab have no attachment API: an upload becomes a link in the
--- issue body or a comment, and that link is the only record of it. So the body
--- is where the list has to come from, with two consequences worth stating —
--- **size and MIME type are unknown** (nil, not guessed), and a link the user
--- typed by hand to an unrelated file on the same host is indistinguishable
--- from an upload. `matches` decides what counts.
---@param texts string[]                       Description and comment bodies.
---@param matches fun(url: string): string?    Returns the absolute URL, or nil to skip.
---@return table[]
function M.markdown_attachments(texts, matches)
  local out, seen = {}, {}

  for _, text in ipairs(texts) do
    -- Both ![alt](url) and [label](url); the leading ! is not captured, so one
    -- pattern covers images and file links alike.
    for label, url in tostring(text or ""):gmatch("%[([^%]]*)%]%(([^%s%)]+)%)") do
      local resolved = matches(url)
      if resolved and not seen[resolved] then
        seen[resolved] = true
        -- Prefer a filename from the URL; fall back to the link text, which is
        -- what GitHub shows for its opaque asset URLs.
        local tail = resolved:gsub("[?#].*$", ""):match("([^/]+)$") or ""
        local filename = tail:match("%.%w+$") and tail or nil
        if not filename and label ~= "" then
          filename = label
        end
        out[#out + 1] = {
          -- The URL is the only stable identity available; a hash of it keeps
          -- the id short and filesystem-safe. Truncated because it names a
          -- directory, not because collisions are acceptable elsewhere.
          id = vim.fn.sha256(resolved):sub(1, 12),
          filename = filename or ("attachment-" .. vim.fn.sha256(resolved):sub(1, 8)),
          url = resolved,
        }
      end
    end
  end

  return out
end

---Build the request that fetches an attachment's bytes.
---
--- Same credentials and the same proxy/TLS block as any other call: an
--- attachment link is exactly as protected as the issue it hangs off, and an
--- unauthenticated GET against a private tracker returns a login page that
--- would then sit on disk pretending to be a PDF.
---@param ctx issuehub.ProviderCtx
---@param url string
---@return issuehub.HttpRequest?
---@return string? err
function M.attachment_request(ctx, url)
  local credentials, terr = M.credential(ctx)
  if not credentials then
    return nil, terr
  end
  return {
    url = url,
    auth = credentials.auth,
    headers = credentials.headers,
    net = config.net(ctx.name),
  }
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

---Follow pages until `max` results, an empty page, or the end.
---
--- Providers page differently — offsets, page numbers, opaque cursors — so this
--- owns only the loop and the stopping rules, and each provider supplies one
--- page. Pages are fetched in sequence rather than in parallel because the
--- cursor for page N+1 generally comes from page N.
---@param opts { max: integer, per_page: integer, fetch: fun(cursor: any, cb: fun(err: string?, items: table[]?, next_cursor: any)) }
---@param cb fun(err: string?, items: table[]?)
function M.paginate(opts, cb)
  local collected = {}
  local guard = 0

  local function step(cursor)
    guard = guard + 1
    if guard > 100 then
      -- A provider that never stops handing out cursors must not spin forever.
      return cb(nil, collected)
    end

    opts.fetch(cursor, function(err, items, next_cursor)
      if err then
        -- Partial results beat none: a rate limit on page 4 should still give
        -- you pages 1 to 3.
        if #collected > 0 then
          return cb(nil, collected)
        end
        return cb(err)
      end

      items = items or {}
      for _, item in ipairs(items) do
        collected[#collected + 1] = item
        if #collected >= opts.max then
          return cb(nil, collected)
        end
      end

      if #items == 0 or next_cursor == nil or #items < opts.per_page then
        return cb(nil, collected)
      end
      step(next_cursor)
    end)
  end

  step(nil)
end

---How many results a provider should gather, and how many per request.
---@param opts table   Provider config.
---@return integer max
---@return integer per_page
function M.limits(opts)
  local per_page = math.min(opts.per_page or 100, 100)
  return opts.max_results or per_page, per_page
end

---Standard health line for a configured provider.
---@param ctx issuehub.ProviderCtx
---@param detail string?
---@return boolean ok
---@return string msg
function M.health(ctx, detail)
  local ok, msg = config.credential_status(ctx.name)
  if not ok then
    return false, msg
  end
  return true, ("%s%s, credential %s"):format(ctx.base, detail and (" " .. detail) or "", msg)
end

return M
