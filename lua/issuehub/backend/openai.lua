---@brief OpenAI-compatible chat-completions backend.
---
--- Talks to any endpoint that speaks `POST /chat/completions` in the OpenAI
--- shape — OpenAI itself, Azure OpenAI, a corporate gateway, a local
--- llama.cpp/vLLM/Ollama server. That covers most "we have an internal LLM"
--- setups, and it rides the same curl transport as every provider, so there is
--- no new dependency and it works wherever curl does (Windows included).
---
--- Non-streaming: one request, the whole reply. Streaming (SSE) can be added
--- behind the same `on_chunk` contract later without changing callers.

local config = require("issuehub.config")
local log = require("issuehub.util.log")

local M = {}

local OpenAI = {}
OpenAI.__index = OpenAI

---@param name string?
function M.new(name)
  return setmetatable({
    name = name or "openai",
    http = require("issuehub.util.http"),
  }, OpenAI)
end

---@param opts table
---@return boolean ok
---@return string? err
function OpenAI:setup(opts)
  self.opts = opts or {}
  if type(self.opts.url) ~= "string" or self.opts.url == "" then
    return false, "backends." .. self.name .. ".url is required, e.g. https://gateway.corp/v1"
  end
  if type(self.opts.model) ~= "string" or self.opts.model == "" then
    return false, "backends." .. self.name .. ".model is required, e.g. gpt-4o-mini"
  end

  local base = self.opts.url:gsub("/+$", "")
  -- Accept either the API base (".../v1") or the full endpoint, so a user who
  -- pastes the whole URL from their gateway docs is not surprised.
  self.endpoint = base:match("/chat/completions$") and base or (base .. "/chat/completions")
  self.timeout = self.opts.timeout or 120000 -- model calls are slow
  return true
end

---@return issuehub.BackendCaps
function OpenAI:capabilities()
  return {
    -- The kinds are shaped by the prompt, not the API, so this endpoint handles
    -- all three the same way.
    kinds = { "analyze", "complete", "translate" },
    streaming = false,
    models = { self.opts and self.opts.model or "?" },
    detail = self.opts and ("model " .. tostring(self.opts.model)) or "not configured",
  }
end

---No discovery step; capabilities are static. Kept so the Backend interface is
---uniform.
---@param cb fun(err: string?, caps: issuehub.BackendCaps?)
function OpenAI:discover(cb)
  cb(nil, self:capabilities())
end

---Resolve auth and any endpoint-specific header/query, from the curl config on
---stdin — never argv.
---@return table auth
---@return table headers
---@return table? query
function OpenAI:_credentials()
  local headers = { ["Content-Type"] = "application/json" }
  local auth = nil

  local token, terr = config.secret(self.opts, "token", "backends." .. self.name)
  if token then
    if self.opts.api_key_header then
      -- Azure and some gateways use a named key header (e.g. "api-key") rather
      -- than Bearer.
      headers[self.opts.api_key_header] = token
    else
      auth = { bearer = token }
    end
  elseif self.opts.token or self.opts.token_cmd or self.opts.token_env then
    -- A key was configured but did not resolve (dead command, unset env).
    -- Sending the request unauthenticated anyway turns that into a mystery 401
    -- from the gateway; the warning names the actual cause.
    log.warn("openai: api key configured but unresolved —", terr)
  end

  -- Passthrough for anything the endpoint needs that this backend does not model
  -- — Azure's `api-version`, a gateway's routing header.
  for key, value in pairs(self.opts.headers or {}) do
    headers[key] = value
  end
  return auth, headers, self.opts.query
end

---@param req issuehub.Request
---@return table[] messages
local function messages_of(req, system)
  local msgs = {}
  if system and system ~= "" then
    msgs[#msgs + 1] = { role = "system", content = system }
  end
  msgs[#msgs + 1] = { role = "user", content = require("issuehub.backend.message").render(req) }
  return msgs
end

---@param body table
---@return string? text
local function extract_text(body)
  local choice = body and body.choices and body.choices[1]
  local message = choice and choice.message
  if message and type(message.content) == "string" and message.content ~= "" then
    return message.content
  end
  return nil
end

---@param req issuehub.Request
---@param opts table
---@param cb fun(err: string?, res: issuehub.Response?)
function OpenAI:send(req, opts, cb)
  local auth, headers, query = self:_credentials()
  local meta = req.metadata or {}
  local model = meta.model or self.opts.model

  local payload = {
    model = model,
    messages = messages_of(req, meta.system or self.opts.system),
    stream = false,
  }
  -- Only send tuning knobs when set, so a stricter endpoint does not reject an
  -- explicit null it never asked for — and so a reasoning model (GPT-5 family,
  -- o-series) that only accepts its default temperature is not handed one.
  payload.temperature = meta.temperature or self.opts.temperature
  -- Newer OpenAI models renamed the output cap to `max_completion_tokens` and
  -- reject the old `max_tokens`; send whichever the caller set, never both.
  payload.max_completion_tokens = meta.max_completion_tokens or self.opts.max_completion_tokens
  if not payload.max_completion_tokens then
    payload.max_tokens = meta.max_tokens or self.opts.max_tokens
  end
  for key, value in pairs(self.opts.params or {}) do
    payload[key] = value
  end

  log.debug("openai send", req.kind, req.resource or "-", "model", model)

  self.http.request({
    method = "POST",
    url = self.endpoint,
    query = query,
    body = payload,
    headers = headers,
    auth = auth,
    net = config.net(nil),
    timeout = self.timeout,
  }, function(err, res)
    if err then
      -- The body of an OpenAI error is itself JSON with a useful message; surface
      -- it rather than the bare "HTTP 400".
      local detail = res and res.body and res:json()
      if detail and detail.error and detail.error.message then
        return cb(("%s: %s"):format(self.name, detail.error.message))
      end
      return cb(err)
    end

    local body, jerr = res:json()
    if not body then
      return cb(jerr)
    end
    if body.error then
      return cb(("%s: %s"):format(self.name, body.error.message or vim.inspect(body.error)))
    end

    local reply = extract_text(body)
    if not reply then
      return cb(self.name .. " returned no message content")
    end

    if opts.on_chunk then
      -- Non-streaming: one chunk, so callers use a single path.
      opts.on_chunk(reply)
    end
    cb(nil, { text = reply, model = body.model or model, raw = body })
  end)
end

---@return boolean ok
---@return string msg
function OpenAI:health()
  if not self.endpoint then
    return false, "not configured"
  end
  -- Report that the key resolves, never its value — same rule as a provider
  -- credential.
  local has_token = self.opts.token or self.opts.token_cmd or self.opts.token_env
  local token_note = "no key set"
  if has_token then
    local token, terr = config.secret(self.opts, "token", "backends." .. self.name)
    token_note = token and ("key resolved (%d chars)"):format(#token) or ("key unresolved: " .. tostring(terr))
  end
  return true, ("%s, model %s, %s"):format(self.endpoint, self.opts.model, token_note)
end

return M
