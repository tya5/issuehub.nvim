---Shared spec helpers. Providers are tested against recorded fixtures, never a
---live API (§20).
local M = {}

---Fake transport matching the HttpClient interface.
---
---`responses` is keyed by a trailing portion of the request path, so specs can
---key on "/issues/123" without writing the host.
---
---Matching is suffix-first and only then substring. A plain longest-substring
---match would resolve ".../issues/123/comments" to the ".../issues/123" entry,
---since the issue path is a prefix of its own sub-resources.
---@param responses table<string, table>
---@return table
function M.fake_http(responses)
  local calls = {}
  return {
    calls = calls,
    ---Last request whose URL contains `needle`.
    find_call = function(needle)
      local found
      for _, call in ipairs(calls) do
        if call.url:find(needle, 1, true) then
          found = call
        end
      end
      return found
    end,
    request = function(req, cb)
      calls[#calls + 1] = req

      local body, best = nil, -1
      for key, value in pairs(responses) do
        if req.url:sub(-#key) == key and #key > best then
          body, best = value, #key
        end
      end
      if body == nil then
        for key, value in pairs(responses) do
          if req.url:find(key, 1, true) and #key > best then
            body, best = value, #key
          end
        end
      end
      body = body or {}

      cb(nil, {
        status = 200,
        body = vim.json.encode(body),
        headers = {},
        json = function()
          return body
        end,
      })
    end,
  }
end

---Configure issuehub with a throwaway workspace and one provider.
---@param name string
---@param provider_opts table
function M.configure(name, provider_opts)
  local config = require("issuehub.config")
  config.setup({
    workspace = vim.fn.tempname(),
    providers = { [name] = provider_opts },
  })
  require("issuehub.core.index").reset()
  return config.get().providers[name]
end

---Run an async provider call that completes synchronously under the fake
---transport, and return its result.
---@param fn fun(cb: fun(err: string?, value: any))
---@return any value
---@return string? err
function M.sync(fn)
  local result, error_message, done = nil, nil, false
  fn(function(err, value)
    error_message, result, done = err, value, true
  end)
  assert(done, "callback was never invoked")
  return result, error_message
end

return M
