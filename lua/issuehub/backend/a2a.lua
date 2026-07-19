---@brief A2A backend (§18). Loaded only when selected.
---
--- Message-only by design: A2A's Task lifecycle is optional, and a single
--- `message/send` round trip is enough for "analyse this issue". Task support can
--- be added later without changing the Backend interface.
---
--- NOTE: this is written against the A2A JSON-RPC shape (agent card discovery
--- plus `message/send`) but has not been exercised against a live agent. Treat it
--- as a starting point and please report mismatches.

local config = require("issuehub.config")
local log = require("issuehub.util.log")

local M = {}

local A2A = {}
A2A.__index = A2A

---@param name string?
function M.new(name)
  return setmetatable({
    name = name or "a2a",
    http = require("issuehub.util.http"),
    caps = nil,
    card = nil,
  }, A2A)
end

---@param opts table
---@return boolean ok
---@return string? err
function A2A:setup(opts)
  self.opts = opts or {}
  if type(self.opts.url) ~= "string" or self.opts.url == "" then
    return false, "backends.a2a.url is required, e.g. http://localhost:9100"
  end
  self.base = self.opts.url:gsub("/+$", "")
  self.timeout = self.opts.timeout or 120000 -- model calls are slow
  return true
end

---@return table
function A2A:_request_opts()
  local headers = { ["Content-Type"] = "application/json" }
  local opts = { headers = headers, net = config.net(nil), timeout = self.timeout }

  -- Optional bearer, for agents behind auth.
  local backends = config.get().backends or {}
  local settings = backends[self.name] or {}
  if settings.token_env or settings.token_cmd or settings.token then
    local token = config.secret(settings, "token", "backends." .. self.name)
    if token then
      opts.auth = { bearer = token }
    end
  end
  return opts
end

---@return issuehub.BackendCaps
function A2A:capabilities()
  -- Before discovery completes, assume the baseline every A2A agent supports.
  return self.caps or { kinds = { "analyze", "complete" }, streaming = false, detail = "not yet discovered" }
end

---Fetch the agent card. Optional: `send` works without it, and this only
---sharpens what :checkhealth reports.
---@param cb fun(err: string?, caps: issuehub.BackendCaps?)
function A2A:discover(cb)
  local opts = self:_request_opts()
  self.http.request({
    method = "GET",
    url = self.base .. "/.well-known/agent-card.json",
    headers = opts.headers,
    auth = opts.auth,
    net = opts.net,
    timeout = 10000,
  }, function(err, res)
    if err then
      return cb(err)
    end
    local card = res:json()
    self.card = card

    local streaming = false
    if card and card.capabilities then
      streaming = card.capabilities.streaming == true
    end

    self.caps = {
      kinds = { "analyze", "complete" },
      streaming = streaming,
      detail = card and (card.name or card.description) or "agent card returned no name",
    }
    cb(nil, self.caps)
  end)
end

---Render a request as the single text part A2A carries.
---
--- The Workspace is included as labelled sections rather than raw JSON, because
--- the receiver is a model and prose survives better than a serialized table.
---@param req issuehub.Request
---@return string
function M.render(req)
  local parts = {}

  local context = req.context or {}
  local issue = context.issue
  if issue then
    parts[#parts + 1] = ("# %s  %s"):format(issue.id or "", issue.title or "")
    parts[#parts + 1] = ("Status: %s\nAssignee: %s\nURL: %s"):format(
      issue.status and issue.status.name or "?",
      issue.assignee or "-",
      issue.url or "-"
    )
    if issue.description and issue.description ~= "" then
      parts[#parts + 1] = "## Description\n\n" .. issue.description
    end
    if issue.comments and #issue.comments > 0 then
      local comments = {}
      for _, comment in ipairs(issue.comments) do
        comments[#comments + 1] = ("- %s: %s"):format(comment.author or "?", comment.body or "")
      end
      parts[#parts + 1] = "## Comments\n\n" .. table.concat(comments, "\n")
    end
  end

  local overlay = context.overlay
  if overlay then
    if overlay.memo and overlay.memo ~= "" then
      parts[#parts + 1] = "## Memo\n\n" .. overlay.memo
    end
    if overlay.metadata and overlay.metadata ~= "" then
      parts[#parts + 1] = "## Metadata\n\n```yaml\n" .. overlay.metadata .. "\n```"
    end
  end

  for _, document in ipairs(context.documents or {}) do
    parts[#parts + 1] = ("## %s\n\n%s"):format(document.name, document.text)
  end

  if context.selection and context.selection ~= "" then
    parts[#parts + 1] = "## Selection\n\n" .. context.selection
  end

  parts[#parts + 1] = "## Task\n\n" .. req.prompt
  return table.concat(parts, "\n\n")
end

---@param body table
---@return string? text
local function extract_text(body)
  local result = body and body.result
  if not result then
    return nil
  end

  -- A message reply, or a task whose final artifact carries the text.
  local candidates = {}
  if result.parts then
    candidates[#candidates + 1] = result.parts
  end
  if result.message and result.message.parts then
    candidates[#candidates + 1] = result.message.parts
  end
  if result.status and result.status.message and result.status.message.parts then
    candidates[#candidates + 1] = result.status.message.parts
  end
  for _, artifact in ipairs(result.artifacts or {}) do
    if artifact.parts then
      candidates[#candidates + 1] = artifact.parts
    end
  end

  local chunks = {}
  for _, parts in ipairs(candidates) do
    for _, part in ipairs(parts) do
      if part.text and part.text ~= "" then
        chunks[#chunks + 1] = part.text
      end
    end
  end

  if #chunks == 0 then
    return nil
  end
  return table.concat(chunks, "\n")
end

---@param req issuehub.Request
---@param opts table
---@param cb fun(err: string?, res: issuehub.Response?)
function A2A:send(req, opts, cb)
  local request_opts = self:_request_opts()
  local text = M.render(req)

  local payload = {
    jsonrpc = "2.0",
    id = tostring(vim.uv.hrtime()),
    method = "message/send",
    params = {
      message = {
        role = "user",
        messageId = tostring(vim.uv.hrtime()),
        parts = { { kind = "text", text = text } },
      },
      metadata = req.metadata,
    },
  }

  log.debug("a2a send", req.kind, req.resource or "-")

  self.http.request({
    method = "POST",
    url = self.base .. "/",
    body = payload,
    headers = request_opts.headers,
    auth = request_opts.auth,
    net = request_opts.net,
    timeout = self.timeout,
  }, function(err, res)
    if err then
      return cb(err)
    end

    local body, jerr = res:json()
    if not body then
      return cb(jerr)
    end
    if body.error then
      return cb(("a2a error %s: %s"):format(tostring(body.error.code), tostring(body.error.message)))
    end

    local reply = extract_text(body)
    if not reply then
      return cb("a2a returned no text part")
    end

    if opts.on_chunk then
      -- Non-streaming: deliver it as a single chunk so callers can use one path.
      opts.on_chunk(reply)
    end

    cb(nil, {
      text = reply,
      model = (req.metadata or {}).model or (self.card and self.card.name),
      raw = body,
    })
  end)
end

---@return boolean ok
---@return string msg
function A2A:health()
  if not self.base then
    return false, "backends.a2a.url is not configured"
  end
  local caps = self:capabilities()
  return true, ("%s (%s)"):format(self.base, caps.detail or "unverified")
end

return M
