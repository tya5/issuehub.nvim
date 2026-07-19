---@brief Logging with unconditional credential redaction.
local M = {}

local levels = vim.log.levels

---Each pattern captures (keep, secret). gsub replaces the WHOLE match, so the
---leading context has to be captured and re-emitted rather than assumed intact.
local REDACT = {
  "([Aa]uthorization:%s*%a+%s+)([^\r\n\"]+)",
  "([Aa]uthorization:%s*)([^\r\n\"]+)",
  "(user%s*=%s*\"[^:\"]*:)([^\"]*)",
  "([Tt]oken[\"']?%s*[:=]%s*[\"']?)([%w%-%._~%+/=]+)",
  "([Aa]pi[_%-]?[Kk]ey[\"']?%s*[:=]%s*[\"']?)([%w%-%._~%+/=]+)",
}

---Strip anything that looks like a secret. Applied to every logged string,
---with no opt-out: a log file is not worth a leaked token.
---@param s string
---@return string
function M.redact(s)
  for _, pat in ipairs(REDACT) do
    s = s:gsub(pat, function(keep, secret)
      if #secret == 0 then
        return nil
      end
      return keep .. "<redacted>"
    end)
  end
  return s
end

local function logfile()
  return vim.fs.joinpath(vim.fn.stdpath("log") --[[@as string]], "issuehub.log")
end

local function level()
  local ok, config = pcall(require, "issuehub.config")
  if ok and config.get then
    return config.get().log_level
  end
  return levels.WARN
end

local function write(lvl, name, msg)
  if lvl < level() then
    return
  end
  local line = string.format("%s [%s] %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), name, M.redact(msg))
  local fd = vim.uv.fs_open(logfile(), "a", 420) -- 0644
  if fd then
    vim.uv.fs_write(fd, line)
    vim.uv.fs_close(fd)
  end
end

---@param ... any
local function fmt(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[#parts + 1] = type(v) == "string" and v or vim.inspect(v)
  end
  return table.concat(parts, " ")
end

function M.debug(...)
  write(levels.DEBUG, "DEBUG", fmt(...))
end

function M.info(...)
  write(levels.INFO, "INFO", fmt(...))
end

function M.warn(...)
  write(levels.WARN, "WARN", fmt(...))
end

function M.error(...)
  write(levels.ERROR, "ERROR", fmt(...))
end

function M.path()
  return logfile()
end

return M
