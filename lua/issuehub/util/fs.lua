---@brief Filesystem helpers. All writes are atomic (tmp + fsync + rename).
local M = {}

local uv = vim.uv

---@param path string
---@return boolean
function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

---@param path string
---@return boolean
function M.is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---@param path string
---@return boolean ok
---@return string? err
function M.mkdirp(path)
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok then
    return false, tostring(err)
  end
  return true
end

---@param path string
---@return string? content
---@return string? err
function M.read(path)
  local fd, oerr = uv.fs_open(path, "r", 420)
  if not fd then
    return nil, oerr
  end
  local st = uv.fs_fstat(fd)
  if not st then
    uv.fs_close(fd)
    return nil, "fstat failed: " .. path
  end
  local data = uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  return data
end

---Write atomically: a reader either sees the old file or the new one, never a
---partial write. Matters because the Repository is Git-managed and may be read
---by other tools at any moment.
---
--- `opts.sync = false` skips the fsync. The rename still makes the write
--- atomic; fsync only adds durability across a power cut, which is worth paying
--- for user-authored notes and pointless for `.state/`, which is declared
--- rebuildable and safe to delete. At a few thousand files the difference is
--- minutes.
---@param path string
---@param content string
---@param opts { sync: boolean? }?
---@return boolean ok
---@return string? err
function M.write(path, content, opts)
  local dir = vim.fs.dirname(path)
  local ok, merr = M.mkdirp(dir)
  if not ok then
    return false, merr
  end

  local tmp = path .. ".tmp"
  local fd, oerr = uv.fs_open(tmp, "w", 420)
  if not fd then
    return false, oerr
  end

  local durable = not (opts and opts.sync == false)
  local wok, werr = pcall(function()
    assert(uv.fs_write(fd, content))
    if durable then
      assert(uv.fs_fsync(fd))
    end
  end)
  uv.fs_close(fd)

  if not wok then
    uv.fs_unlink(tmp)
    return false, tostring(werr)
  end

  local rok, rerr = uv.fs_rename(tmp, path)
  if not rok then
    uv.fs_unlink(tmp)
    return false, rerr
  end
  return true
end

---@param path string
---@param value any
---@param opts { sync: boolean? }?
---@return boolean ok
---@return string? err
function M.write_json(path, value, opts)
  return M.write(path, vim.json.encode(value), opts)
end

---@param path string
---@return table? value
---@return string? err
function M.read_json(path)
  local content, err = M.read(path)
  if not content then
    return nil, err
  end
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok then
    return nil, ("invalid JSON in %s: %s"):format(path, decoded)
  end
  return decoded
end

---@param dir string
---@return string[] names
function M.list(dir)
  local out = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    out[#out + 1] = name
  end
  return out
end

---Expand "~" and environment variables, then normalize.
---@param path string
---@return string
function M.expand(path)
  return vim.fs.normalize(vim.fn.expand(path))
end

return M
