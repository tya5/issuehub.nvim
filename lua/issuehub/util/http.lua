---@brief Default HttpClient: vim.system() + curl.
---
--- Why curl and not vim.net.request(): as of Neovim 0.12 vim.net.request() is
--- GET-only with no header or body support, so it cannot make an authenticated
--- API call. The complete version lands in 0.13. Until then curl is the only
--- option that does not introduce a hard dependency (§1.3, §8).
---
--- Credentials NEVER appear in argv. Everything sensitive goes into a curl
--- config file fed on stdin, so `ps` cannot see it.

local log = require("issuehub.util.log")

local M = {}

---@class issuehub.HttpRequest
---@field method string?             -- default "GET"
---@field url string
---@field query table<string,any>?
---@field headers table<string,string>?
---@field body table|string?         -- table is JSON-encoded
---@field auth issuehub.HttpAuth?
---@field net issuehub.HttpNet?      -- proxy / TLS settings; defaults to config.net()
---@field timeout integer?           -- ms, default 30000
---@field retries integer?           -- default 2

---@class issuehub.HttpAuth
---@field basic string?              -- "user:token", handed to curl's `user =`
---@field bearer string?

---@class issuehub.HttpNet   Corporate network settings; see config.net().
---@field proxy string?
---@field no_proxy string?
---@field proxy_user string?
---@field proxy_password string?
---@field proxy_auth string?
---@field cacert string?
---@field capath string?
---@field ssl_verify boolean?
---@field client_cert string?
---@field client_key string?
---@field client_key_password string?
---@field timeout integer?
---@field retries integer?

---@class issuehub.HttpResponse
---@field status integer
---@field body string
---@field headers table<string,string>
---@field json fun(): table?, string?

local MAX_CONCURRENT = 6
local active = 0
local queue = {}

--- curl config files use C-style escapes inside double-quoted values.
---@param s string
---@return string
local function cq(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

---@param url string
---@param query table?
---@return string
local function with_query(url, query)
  if not query or vim.tbl_isempty(query) then
    return url
  end
  local parts = {}
  for k, v in pairs(query) do
    if type(v) == "table" then
      v = table.concat(v, ",")
    elseif type(v) == "boolean" then
      v = tostring(v)
    end
    parts[#parts + 1] = ("%s=%s"):format(vim.uri_encode(tostring(k)), vim.uri_encode(tostring(v)))
  end
  return url .. (url:find("?", 1, true) and "&" or "?") .. table.concat(parts, "&")
end

---Parse the header dump curl wrote with -D. Only the final response block is
---kept, so redirects and 100-continue do not leak through.
---@param raw string
---@return table<string,string>
local function parse_headers(raw)
  local headers = {}
  for line in raw:gmatch("[^\r\n]+") do
    if line:match("^HTTP/") then
      headers = {} -- new response block; discard the previous one
    else
      local k, v = line:match("^([%w%-]+):%s*(.*)$")
      if k then
        headers[k:lower()] = v
      end
    end
  end
  return headers
end

---Build the curl config file contents for a request.
---
---EVERYTHING sensitive goes here rather than into argv, because argv is visible
---to any user on the machine via `ps`. That covers the API token, the proxy
---password, and the client-key passphrase alike.
---
---Exposed (underscore-prefixed) so specs can assert on it without spawning curl.
---@param req issuehub.HttpRequest
---@return string
function M._build_config(req)
  local conf = {}
  local net = req.net or {}

  for k, v in pairs(req.headers or {}) do
    conf[#conf + 1] = "header = " .. cq(("%s: %s"):format(k, v))
  end

  if req.auth then
    if req.auth.basic then
      conf[#conf + 1] = "user = " .. cq(req.auth.basic)
    elseif req.auth.bearer then
      conf[#conf + 1] = "header = " .. cq("Authorization: Bearer " .. req.auth.bearer)
    end
  end

  -- Proxy. Omitting `proxy` entirely leaves curl to honour http_proxy /
  -- https_proxy / no_proxy from the environment, which is what most corporate
  -- machines already set.
  if net.proxy then
    conf[#conf + 1] = "proxy = " .. cq(net.proxy)
  end
  if net.no_proxy then
    conf[#conf + 1] = "noproxy = " .. cq(net.no_proxy)
  end
  if net.proxy_user then
    -- Always emit the "user:password" form, with an empty password when none
    -- resolved. Passing a bare user makes curl prompt on the terminal, which
    -- hangs a headless Neovim instead of failing.
    conf[#conf + 1] = "proxy-user = " .. cq(net.proxy_user .. ":" .. (net.proxy_password or ""))
  end
  if net.proxy_auth then
    -- Bare flags in a curl config file are just the option name on a line.
    conf[#conf + 1] = "proxy-" .. net.proxy_auth
  end

  -- TLS.
  if net.cacert then
    conf[#conf + 1] = "cacert = " .. cq(net.cacert)
  end
  if net.capath then
    conf[#conf + 1] = "capath = " .. cq(net.capath)
  end
  if net.ssl_verify == false then
    conf[#conf + 1] = "insecure"
  end
  if net.client_cert then
    conf[#conf + 1] = "cert = " .. cq(net.client_cert)
  end
  if net.client_key then
    conf[#conf + 1] = "key = " .. cq(net.client_key)
  end
  if net.client_key_password then
    conf[#conf + 1] = "pass = " .. cq(net.client_key_password)
  end

  local body = req.body
  if type(body) == "table" then
    body = vim.json.encode(body)
    conf[#conf + 1] = "header = " .. cq("Content-Type: application/json")
  end
  if body then
    conf[#conf + 1] = "data-binary = " .. cq(body)
  end

  return table.concat(conf, "\n") .. "\n"
end

---@param res issuehub.HttpResponse
local function attach_json(res)
  res.json = function()
    if res.body == "" then
      return nil, "empty response body"
    end
    local ok, decoded = pcall(vim.json.decode, res.body, { luanil = { object = true, array = true } })
    if not ok then
      return nil, "invalid JSON response: " .. tostring(decoded)
    end
    return decoded
  end
end

local function pump()
  while active < MAX_CONCURRENT and #queue > 0 do
    local job = table.remove(queue, 1)
    active = active + 1
    job()
  end
end

local function release()
  active = active - 1
  pump()
end

---@param req issuehub.HttpRequest
---@param attempt integer
---@param cb fun(err: string?, res: issuehub.HttpResponse?)
local function execute(req, attempt, cb)
  local method = (req.method or "GET"):upper()
  local url = with_query(req.url, req.query)
  local net = req.net or {}
  local timeout = req.timeout or net.timeout or 30000
  local hdr_file = vim.fn.tempname()

  local conf = M._build_config(req)

  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--location",
    "--request",
    method,
    "--max-time",
    tostring(math.ceil(timeout / 1000)),
    "--dump-header",
    hdr_file,
    "--write-out",
    "\n%{http_code}",
    "--config",
    "-", -- read the config above from stdin
    url,
  }

  log.debug("http", method, url)

  local ok, err = pcall(vim.system, cmd, { stdin = conf, text = true }, function(out)
    -- vim.system's on_exit runs in a fast event context; every consumer-facing
    -- callback is scheduled here so no caller has to remember.
    vim.schedule(function()
      local headers = {}
      local raw = vim.uv.fs_stat(hdr_file) and (require("issuehub.util.fs").read(hdr_file) or "") or ""
      if raw ~= "" then
        headers = parse_headers(raw)
      end
      vim.uv.fs_unlink(hdr_file)

      local stdout = out.stdout or ""
      local body_text, code = stdout:match("^(.*)\n(%d+)$")
      local status = tonumber(code) or 0

      if out.code ~= 0 and status == 0 then
        local msg = vim.trim(out.stderr or "")
        release()
        return cb(("curl failed (exit %d): %s"):format(out.code, msg ~= "" and msg or "unknown error"))
      end

      local retriable = status == 429 or (status >= 500 and status < 600)
      local max_retries = req.retries or net.retries or 2
      if retriable and attempt <= max_retries then
        local delay = tonumber(headers["retry-after"])
        delay = delay and delay * 1000 or math.min(1000 * 2 ^ (attempt - 1), 8000)
        log.warn(("http %d, retry %d/%d in %dms: %s"):format(status, attempt, max_retries, delay, url))
        release()
        -- Re-enter execute() directly with an incremented attempt. Going back
        -- through M.request() would reset attempt to 1 and retry forever.
        return vim.defer_fn(function()
          queue[#queue + 1] = function()
            execute(req, attempt + 1, cb)
          end
          pump()
        end, delay)
      end

      local res = { status = status, body = body_text or stdout, headers = headers }
      attach_json(res)
      release()

      if status >= 400 then
        return cb(("HTTP %d: %s"):format(status, vim.trim((res.body or ""):sub(1, 300))), res)
      end
      cb(nil, res)
    end)
  end)

  if not ok then
    vim.uv.fs_unlink(hdr_file)
    release()
    vim.schedule(function()
      cb("failed to spawn curl: " .. tostring(err))
    end)
  end
end

---@param req issuehub.HttpRequest
---@param cb fun(err: string?, res: issuehub.HttpResponse?)
function M.request(req, cb)
  -- Providers pass `net` explicitly; anything else picks up the global block so
  -- corporate proxy settings apply to every request without each call site
  -- remembering to thread them through.
  if req.net == nil then
    local ok, config = pcall(require, "issuehub.config")
    req.net = ok and config.net(nil) or {}
  end

  queue[#queue + 1] = function()
    execute(req, 1, cb)
  end
  pump()
end

---Fetch a URL straight to a file.
---
--- Separate from `request()` rather than an option on it, because the response
--- must never become a Lua string: attachments are binary, and `execute()`
--- reads stdout with `text = true` and splits the trailing status code off the
--- body. Both would corrupt a PNG. Here curl writes the bytes itself and only
--- the status code comes back through stdout.
---
--- Writes to `<dest>.part` and renames on success, so an interrupted download
--- never leaves a truncated file that looks complete — the same
--- temp-then-rename rule the workspace writes follow.
---@param req issuehub.HttpRequest
---@param dest string             Absolute path to write.
---@param opts { max_size: integer? }?
---@param cb fun(err: string?, path: string?)
function M.download(req, dest, opts, cb)
  opts = opts or {}
  if req.net == nil then
    local ok, config = pcall(require, "issuehub.config")
    req.net = ok and config.net(nil) or {}
  end

  queue[#queue + 1] = function()
    local net = req.net or {}
    local timeout = req.timeout or net.timeout or 300000
    local part = dest .. ".part"
    local conf = M._build_config(req)

    local cmd = {
      "curl",
      "--silent",
      "--show-error",
      "--fail",
      "--location",
      "--max-time",
      tostring(math.ceil(timeout / 1000)),
      "--output",
      part,
      "--write-out",
      "%{http_code}",
    }
    if opts.max_size and opts.max_size > 0 then
      -- Refuses before transferring when the server declares a size; aborts
      -- mid-transfer otherwise. Either way the .part file is discarded below.
      vim.list_extend(cmd, { "--max-filesize", tostring(opts.max_size) })
    end
    -- The config (credentials, proxy, TLS) is read from stdin, never argv.
    vim.list_extend(cmd, { "--config", "-", req.url })

    log.debug("download", req.url, "->", dest)

    local ok, err = pcall(vim.system, cmd, { stdin = conf, text = true }, function(out)
      vim.schedule(function()
        release()
        local status = tonumber(vim.trim(out.stdout or "")) or 0

        if out.code ~= 0 or status >= 400 then
          vim.uv.fs_unlink(part)
          local msg = vim.trim(out.stderr or "")
          if out.code == 63 then
            msg = ("file is larger than the %d byte limit"):format(opts.max_size or 0)
          elseif status >= 400 then
            msg = ("HTTP %d"):format(status)
          end
          return cb(("download failed: %s"):format(msg ~= "" and msg or ("curl exit " .. out.code)))
        end

        local ok_rename, rerr = vim.uv.fs_rename(part, dest)
        if not ok_rename then
          vim.uv.fs_unlink(part)
          return cb(("could not move the download into place: %s"):format(tostring(rerr)))
        end
        cb(nil, dest)
      end)
    end)

    if not ok then
      release()
      vim.schedule(function()
        cb("failed to spawn curl: " .. tostring(err))
      end)
    end
  end
  pump()
end

---Whether curl is usable. Reported by :checkhealth.
---@return boolean ok
---@return string msg
function M.probe()
  if vim.fn.executable("curl") == 0 then
    return false, "curl not found in PATH"
  end
  local out = vim.system({ "curl", "--version" }, { text = true }):wait()
  local first = vim.split(out.stdout or "", "\n")[1] or "curl"
  return true, first
end

return M
