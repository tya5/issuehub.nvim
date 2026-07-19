-- Minimal busted-compatible harness for local runs: `nvim -l spec/runner.lua`.
--
-- CI uses real busted + nlua (see .github/workflows/ci.yml). This exists so the
-- suite can be run without a luarocks toolchain installed, and implements only
-- the subset of the busted API the specs actually use.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local passed, failed, failures = 0, 0, {}
local stack, before_stack = {}, {}

local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  return vim.deep_equal(a, b)
end

local function fail(msg)
  error(msg, 2)
end

_G.assert = setmetatable({
  equals = function(expected, actual)
    if expected ~= actual then
      fail(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
    end
  end,
  same = function(expected, actual)
    if not deep_equal(expected, actual) then
      fail(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
    end
  end,
  is_true = function(v)
    if v ~= true then
      fail("expected true, got " .. vim.inspect(v))
    end
  end,
  is_false = function(v)
    if v ~= false then
      fail("expected false, got " .. vim.inspect(v))
    end
  end,
  is_nil = function(v)
    if v ~= nil then
      fail("expected nil, got " .. vim.inspect(v))
    end
  end,
  truthy = function(v)
    if not v then
      fail("expected truthy, got " .. vim.inspect(v))
    end
  end,
}, {
  __call = function(_, v, msg)
    if not v then
      fail(msg or "assertion failed")
    end
    return v
  end,
})

function _G.describe(name, fn)
  table.insert(stack, name)
  table.insert(before_stack, {})
  fn()
  table.remove(before_stack)
  table.remove(stack)
end

function _G.before_each(fn)
  table.insert(before_stack[#before_stack], fn)
end

function _G.it(name, fn)
  local label = table.concat(stack, " ") .. " > " .. name
  local ok, err = pcall(function()
    for _, group in ipairs(before_stack) do
      for _, hook in ipairs(group) do
        hook()
      end
    end
    fn()
  end)
  if ok then
    passed = passed + 1
    io.write("  ok   " .. label .. "\n")
  else
    failed = failed + 1
    failures[#failures + 1] = label .. "\n       " .. tostring(err)
    io.write("  FAIL " .. label .. "\n")
  end
end

local files = vim.fn.glob("spec/*_spec.lua", false, true)
table.sort(files)

for _, file in ipairs(files) do
  io.write("\n" .. file .. "\n")
  -- Each spec file starts from a clean module cache so config/singleton state
  -- from one file cannot leak into the next.
  for name in pairs(package.loaded) do
    if name:match("^issuehub") then
      package.loaded[name] = nil
    end
  end
  local chunk, lerr = loadfile(file)
  if not chunk then
    failed = failed + 1
    failures[#failures + 1] = file .. "\n       " .. tostring(lerr)
    io.write("  FAIL (load) " .. tostring(lerr) .. "\n")
  else
    local ok, rerr = pcall(chunk)
    if not ok then
      failed = failed + 1
      failures[#failures + 1] = file .. "\n       " .. tostring(rerr)
      io.write("  FAIL (run) " .. tostring(rerr) .. "\n")
    end
  end
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
if failed > 0 then
  io.write("\nFailures:\n")
  for _, f in ipairs(failures) do
    io.write("  - " .. f .. "\n")
  end
  vim.cmd("cquit 1")
end
