---@brief The default backend: no AI, no network, no surprises.
---
--- issuehub ships with this selected. Nothing leaves your machine unless you
--- deliberately configure a different backend.

local M = {}

local None = {}
None.__index = None

---@param name string?
function M.new(name)
  return setmetatable({ name = name or "none" }, None)
end

function None:setup()
  return true
end

---@return issuehub.BackendCaps
function None:capabilities()
  return { kinds = {}, streaming = false, detail = "no backend configured" }
end

---@param cb fun(err: string?, caps: issuehub.BackendCaps?)
function None:discover(cb)
  cb(nil, self:capabilities())
end

---@param cb fun(err: string?, res: issuehub.Response?)
function None:send(_, _, cb)
  cb(
    "no backend configured — set `backend = 'a2a'` (and `backends.a2a.url`), "
      .. "or register your own with require('issuehub.backend').register()"
  )
end

---@return boolean ok
---@return string msg
function None:health()
  return true, "none (AI features disabled; nothing is sent anywhere)"
end

return M
