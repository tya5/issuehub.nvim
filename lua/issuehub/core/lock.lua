---@brief Cross-process mutual exclusion for the workspace.
---
--- One workspace is written by this plugin, by the `issuehub` CLI, and by a
--- human with a text editor — concurrently, by design. Without a protocol, a
--- read-modify-write on either side silently drops the other's update. This is
--- that protocol, and it is a **shared on-disk contract**: the CLI implements
--- the same one, so both sides must match byte for byte
--- (`handoff/ONDISK.md` §Locking).
---
--- Two independent mechanisms, both needed:
---
--- 1. **The lock**, `O_CREAT | O_EXCL` on a file under `.state/lock/`, Git's
---    `index.lock` in miniature. It binds every writer that honours it.
--- 2. **The optimistic content check** — re-read the file immediately before
---    writing and refuse if it moved. This is what covers the writer that
---    structurally cannot take a lock: a text editor. A lock alone would leave
---    hand-edits unprotected, which is the case a notes tool can least afford.
---
--- Nothing here ever removes a lock it does not own, however old it looks. See
--- `M.acquire` for why that is a decision rather than a gap.

local fs = require("issuehub.util.fs")
local repository = require("issuehub.core.repository")

local M = {}

---How long to wait for a contended lock. Long enough for any single write,
---short enough that a genuinely stuck lock surfaces as an error rather than a
---hang.
M.timeout = 10000
M.poll = 50

---Locks this process currently holds, by path.
---
--- Reference-counted, because acquisition nests: `import` takes a subject lock
--- and then calls `overlay.write`, which takes the same one. Without
--- re-entrancy that is not contention, it is this process waiting ten seconds
--- for itself and then failing.
---@type table<string, { count: integer, fd: integer }>
local held = {}

---@param subject string   Issue URI or "collection:<slug>".
---@return string? name
local function subject_name(subject)
  local dir = repository.subject_dir(subject)
  local root = repository.root()
  if not dir or not root then
    return nil
  end
  -- The subject's own directory path, relative to the root, flattened. Keeps
  -- the lock file readable, which is the point of a name a human may have to
  -- reason about at 2am.
  local relative = dir:sub(#root + 2)
  return (relative:gsub("/", "_"))
end

---Path of the lock file for one lockable thing.
---@param kind "subject"|"cache"|"lists"
---@param name string
---@return string? path
---@return string? err
function M.path(kind, name)
  if kind == "subject" then
    local flat = subject_name(name)
    if not flat then
      return nil, ("not a lockable subject: %s"):format(tostring(name))
    end
    return repository.state("lock", "subject", flat .. ".lock")
  end
  return repository.state("lock", kind, name .. ".lock")
end

---@param path string
---@return table? payload
local function read_owner(path)
  local text = fs.read(path)
  if not text or text == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  return ok and type(decoded) == "table" and decoded or nil
end

---Describe who holds a lock, for a human deciding what to do about it.
---
--- Every part of this is diagnostic text. None of it feeds an automatic
--- decision, because every liveness signal available here is wrong in exactly
--- the case where acting on it would do the most damage.
---@param path string
---@return string
local function describe_owner(path)
  local owner = read_owner(path)
  if not owner then
    return ("held by an unreadable lock file at %s"):format(path)
  end

  local parts = {
    ("held by %s (pid %s) on %s since %s"):format(
      owner.operation or "an unknown operation",
      tostring(owner.pid or "?"),
      tostring(owner.hostname or "?"),
      tostring(owner.acquired_at or "?")
    ),
  }

  -- A pid means nothing across hosts, and can be reused after a crash even on
  -- this one — so this is offered as evidence, not as a verdict.
  if owner.hostname == vim.uv.os_gethostname() and type(owner.pid) == "number" and owner.pid > 0 then
    -- uv.kill reports failure by RETURNING nil, it does not raise — so pcall
    -- alone succeeds for a pid that does not exist, and every stale lock would
    -- be described as live. The return value is the signal.
    local ok, alive = pcall(vim.uv.kill, owner.pid, 0)
    parts[#parts + 1] = (ok and alive ~= nil) and "that process still appears to be running"
      or "no such process on this host — it may have crashed"
  end

  parts[#parts + 1] = ("if you are sure nothing else is running, remove %s"):format(path)
  return table.concat(parts, "; ")
end

---Take a lock, waiting for it if someone else has it.
---
--- **Never breaks a lock automatically**, no matter how old. Auto-breaking
--- needs a liveness check, and each one available is unreliable precisely when
--- it matters: a pid is meaningless on shared storage written from another
--- machine, pids are reused, and a lock that looks stale is often just a slow
--- import still running. Breaking that one silently reintroduces the lost
--- update this whole module exists to prevent, which is strictly worse than an
--- error a human clears by hand.
---@param kind "subject"|"cache"|"lists"
---@param name string
---@param operation string   Names the call site, e.g. "overlay.write".
---@param opts { timeout: integer? }?
---@return table? handle
---@return string? err
function M.acquire(kind, name, operation, opts)
  opts = opts or {}
  local path, perr = M.path(kind, name)
  if not path then
    return nil, perr
  end

  if held[path] then
    held[path].count = held[path].count + 1
    return { path = path, reentrant = true }
  end

  local payload = vim.json.encode({
    pid = vim.uv.os_getpid(),
    hostname = vim.uv.os_gethostname(),
    acquired_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    operation = operation,
  })

  -- uv.now() is the cached loop time; without a refresh the deadline can be
  -- computed from a stamp taken before a long busy stretch.
  vim.uv.update_time()
  local deadline = vim.uv.now() + (opts.timeout or M.timeout)
  while true do
    local fd, _, errname = vim.uv.fs_open(path, "wx", 420)
    if fd then
      vim.uv.fs_write(fd, payload)
      vim.uv.fs_close(fd)
      held[path] = { count = 1 }
      return { path = path }
    end

    if errname == "ENOENT" then
      -- `.state/` is derived and deletable at any moment; recreating it is
      -- ordinary, not an error — and NOT contention. Retry fs_open immediately
      -- in this same iteration: falling through to the deadline/poll check
      -- below would treat "the directory didn't exist yet" as if it were a
      -- held lock, which is a different bug (the very first acquisition in a
      -- fresh workspace would spuriously report "locked by another process"
      -- under a short timeout, and silently eat one poll interval even under
      -- the default one). Found by a test using timeout=0 against a lock
      -- whose directory had never been created — reproduced with a single,
      -- uncontended listcache.merge call and nothing else running.
      local ok = fs.mkdirp(vim.fs.dirname(path))
      if not ok then
        return nil, ("could not create the lock directory for %s"):format(path)
      end
    elseif errname ~= "EEXIST" then
      return nil, ("could not take the lock %s: %s"):format(path, tostring(errname))
    else
      -- Genuine contention: another writer holds the file. Only THIS branch
      -- may give up on timeout or consume a poll interval.
      if vim.uv.now() >= deadline then
        return nil, ("%s is locked by another process — %s"):format(name, describe_owner(path))
      end
      -- vim.wait keeps the event loop alive while we poll — redraws, timers,
      -- and LSP keep running. uv.sleep would freeze the whole editor for up to
      -- the full timeout on a contended lock, which is exactly the kind of
      -- stall this plugin promises not to cause; it remains only as the
      -- fallback for fast-event contexts, where vim.wait is not allowed.
      if vim.in_fast_event() then
        vim.uv.sleep(M.poll)
      else
        vim.wait(M.poll)
      end
      vim.uv.update_time()
    end
  end
end

---@param handle table?
function M.release(handle)
  if not handle or not handle.path then
    return
  end
  local entry = held[handle.path]
  if not entry then
    return
  end
  entry.count = entry.count - 1
  if entry.count <= 0 then
    held[handle.path] = nil
    vim.uv.fs_unlink(handle.path)
  end
end

---Run `fn` holding a lock, releasing it however `fn` ends.
---
--- The release must survive an error in `fn`, or one failed write leaves a lock
--- file that blocks every later one until a human deletes it.
---@generic T
---@param kind "subject"|"cache"|"lists"
---@param name string
---@param operation string
---@param fn fun(): T
---@return T? result
---@return string? err
function M.with(kind, name, operation, fn)
  local handle, err = M.acquire(kind, name, operation)
  if not handle then
    return nil, err
  end

  local ok, result, rerr = pcall(fn)
  M.release(handle)

  if not ok then
    return nil, tostring(result)
  end
  return result, rerr
end

---The optimistic half: has this file moved since we read it?
---
--- `expected` is the content at read time; nil means "we expected no file".
--- Refuses rather than merging, because the safe merge of two hand-edits does
--- not exist and guessing at one loses text either way.
---@param path string
---@param expected string?
---@return boolean unchanged
---@return string? err
function M.unchanged(path, expected)
  local current = fs.read(path)
  if current == expected then
    return true
  end
  -- Normalised the same way overlay reads normalise, so a trailing newline is
  -- not reported as somebody else's edit.
  if current and expected and vim.trim(current) == vim.trim(expected) then
    return true
  end
  if current == nil then
    return false, ("%s was deleted by something else while you were editing it"):format(path)
  end
  return false,
    ("%s changed on disk since it was read — reload it and reapply your change (nothing was written)"):format(path)
end

---Drop this process's memory of held locks. For specs.
function M.reset()
  for path in pairs(held) do
    vim.uv.fs_unlink(path)
  end
  held = {}
end

return M
