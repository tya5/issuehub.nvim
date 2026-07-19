---@brief Backend registry and the request model (§16–§19).
---
--- issuehub has no AI of its own. A Backend is the only channel through which
--- anything leaves for an agent or a model, and it is opt-in: with the default
--- `none` backend, nothing is ever sent anywhere.
---
--- Requests carry a `kind` rather than being a single opaque `send`, so that
--- future capabilities — LLM completion in particular — slot in without breaking
--- the interface. A backend advertises the kinds it supports; core refuses
--- unsupported ones with a clear message instead of sending a request the
--- backend will not understand.

local M = {}

---@class issuehub.BackendCaps
---@field kinds string[]        Request kinds handled, e.g. { "analyze", "complete" }
---@field streaming boolean     Whether `on_chunk` is called incrementally.
---@field models string[]?      Model identifiers the backend can target.
---@field detail string?        Free-form description, shown by :checkhealth.

---@class issuehub.Request
---@field kind string            "analyze" | "complete" | backend-specific
---@field resource string?       Issue URI or collection name this concerns.
---@field prompt string          The instruction.
---@field context issuehub.RequestContext?
---@field metadata table?        Model hints: model, temperature, max_tokens…

---@class issuehub.RequestContext
---@field issue table?           Canonical Issue, trimmed for transport.
---@field overlay table?         memo / metadata / prompt as text.
---@field selection string?      Visual selection, when the caller had one.
---@field documents table[]?     Extra {name, text} pairs, e.g. prior analyses.

---@class issuehub.Response
---@field text string            The complete response.
---@field model string?
---@field raw table?

---@class issuehub.Backend
---@field name string
---@field setup fun(self, opts: table): boolean, string?
---@field capabilities fun(self): issuehub.BackendCaps
---@field discover fun(self, cb: fun(err: string?, caps: issuehub.BackendCaps?))
---@field send fun(self, req: issuehub.Request, opts: table, cb: fun(err: string?, res: issuehub.Response?))
---@field health fun(self): boolean, string

local BUILTIN = {
  none = "issuehub.backend.none",
  a2a = "issuehub.backend.a2a",
}

---@type table<string, issuehub.Backend>
local registry = {}
local instance = nil

---Register a third-party backend — an LLM client, an MCP bridge, a CLI wrapper.
---@param name string
---@param backend issuehub.Backend
function M.register(name, backend)
  registry[name] = backend
  if instance and instance.name == name then
    instance = nil
  end
end

---@return issuehub.Backend? backend
---@return string? err
function M.get()
  if instance then
    return instance
  end

  local config = require("issuehub.config").get()
  local name = config.backend or "none"

  local backend = registry[name]
  if not backend then
    local module = BUILTIN[name]
    if not module then
      return nil, ("unknown backend '%s' (available: %s)"):format(name, table.concat(M.available(), ", "))
    end
    -- Only the selected backend is required, so an unused A2A costs nothing.
    local ok, impl = pcall(require, module)
    if not ok then
      return nil, ("failed to load backend '%s': %s"):format(name, impl)
    end
    backend = impl.new(name)
    registry[name] = backend
  end

  local ok, err = backend:setup((config.backends or {})[name] or {})
  if not ok then
    return nil, err
  end

  instance = backend
  return instance
end

---@return string[]
function M.available()
  local names = vim.tbl_keys(BUILTIN)
  for name in pairs(registry) do
    if not vim.tbl_contains(names, name) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

function M.reset()
  instance = nil
  registry = {}
end

---@param backend issuehub.Backend
---@param kind string
---@return boolean
function M.supports(backend, kind)
  local caps = backend:capabilities()
  return vim.tbl_contains(caps.kinds or {}, kind)
end

---Send a request to the configured backend.
---
---@param req issuehub.Request
---@param opts { on_chunk: fun(text: string)? }?
---@param cb fun(err: string?, res: issuehub.Response?)
function M.send(req, opts, cb)
  opts = opts or {}

  local backend, err = M.get()
  if not backend then
    return cb(err)
  end

  local kinds = backend:capabilities().kinds or {}

  -- A backend advertising no kinds at all is not "incapable of analyze", it is
  -- not set up. Let it explain itself rather than emitting
  -- "does not handle 'analyze' (it handles: )".
  if #kinds > 0 and not vim.tbl_contains(kinds, req.kind) then
    return cb(
      ("backend '%s' does not handle '%s' requests (it handles: %s)"):format(
        backend.name,
        req.kind,
        table.concat(kinds, ", ")
      )
    )
  end

  -- Streaming is optional: a backend that cannot stream simply never calls
  -- on_chunk, and the caller still gets the whole text in the callback.
  backend:send(req, opts, cb)
end

---Free-form completion, for callers that want a model rather than an analysis.
---
---Nothing in issuehub uses this yet — it exists so an LLM backend can be dropped
---in and driven by user code or a future feature without the interface moving.
---@param prompt string
---@param opts { context: issuehub.RequestContext?, metadata: table?, on_chunk: fun(text: string)? }?
---@param cb fun(err: string?, res: issuehub.Response?)
function M.complete(prompt, opts, cb)
  opts = opts or {}
  M.send({
    kind = "complete",
    prompt = prompt,
    context = opts.context,
    metadata = opts.metadata,
  }, { on_chunk = opts.on_chunk }, cb)
end

return M
