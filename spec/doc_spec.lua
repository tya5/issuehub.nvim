-- The help file is hand-written, so these checks stand in for what a generator
-- would have guaranteed.

local fs = require("issuehub.util.fs")

local DOC = "doc/issuehub.txt"

local function body()
  return assert(fs.read(DOC), "doc/issuehub.txt is missing")
end

---Tag definitions: *like-this*, one word, on their own or right-aligned.
local function defined_tags(text)
  local tags = {}
  for line in text:gmatch("[^\n]+") do
    for tag in line:gmatch("%*(%S-)%*") do
      if not tag:find("%s") then
        tags[tag] = true
      end
    end
  end
  return tags
end

describe("help file", function()
  it("exists and declares its modeline", function()
    assert.truthy(body():find("vim:tw=78", 1, true))
    assert.truthy(body():find("ft=help", 1, true))
  end)

  it("resolves every |tag| it references", function()
    local text = body()
    local tags = defined_tags(text)

    local missing = {}
    for ref in text:gmatch("|(issuehub[%w%-%.%(%)_]*)|") do
      if not tags[ref] then
        missing[#missing + 1] = ref
      end
    end
    assert.same({}, missing)
  end)

  it("stays within 78 display columns", function()
    -- Display width, not bytes: an em dash is three bytes and one column.
    local long = {}
    local number = 0
    for line in (body() .. "\n"):gmatch("([^\n]*)\n") do
      number = number + 1
      if vim.fn.strdisplaywidth(line) > 78 then
        long[#long + 1] = number
      end
    end
    assert.same({}, long)
  end)

  it("documents every subcommand that exists", function()
    -- A help file that omits a command is a bug; one that invents a command is
    -- worse. Both are caught here.
    local text = body()
    local source = assert(fs.read("plugin/issuehub.lua"))

    -- Only the subcommands table: the user command's own `complete` option is
    -- a completion function, not a subcommand.
    local table_source = assert(source:match("local subcommands = {(.-)\n}"))

    local declared = {}
    for name in table_source:gmatch("\n  ([%a_]+) = function") do
      declared[#declared + 1] = name
    end
    for name in table_source:gmatch('\n  %["([%a_]+)"%] = function') do
      declared[#declared + 1] = name
    end
    assert.truthy(#declared > 5, "subcommand extraction found almost nothing")

    local undocumented = {}
    for _, name in ipairs(declared) do
      if not text:find(":IssueHub " .. name, 1, true) then
        undocumented[#undocumented + 1] = name
      end
    end
    assert.same({}, undocumented)
  end)

  it("only promises public API functions that exist", function()
    local text = body()
    local section = text:match("14%. LUA API(.-)==============")
    assert.truthy(section, "the Lua API section moved")

    local modules = {
      ["issuehub"] = require("issuehub"),
      ["issuehub.provider"] = require("issuehub.provider"),
      ["issuehub.backend"] = require("issuehub.backend"),
      ["issuehub.core.export"] = require("issuehub.core.export"),
      ["issuehub.core.collection"] = require("issuehub.core.collection"),
      ["issuehub.core.workspace"] = require("issuehub.core.workspace"),
      ["issuehub.core.overlay"] = require("issuehub.core.overlay"),
      ["issuehub.core.analysis"] = require("issuehub.core.analysis"),
      ["issuehub.ui.view"] = require("issuehub.ui.view"),
    }

    local missing = {}
    for module_name, module in pairs(modules) do
      local heading = module_name:gsub("%.", "%%.") .. " ~"
      local block = section:match(heading .. "(.-)\n\n")
      if block then
        for fn in block:gmatch("([%a_]+)%(") do
          if type(module[fn]) ~= "function" then
            missing[#missing + 1] = module_name .. "." .. fn
          end
        end
      end
    end
    assert.same({}, missing)
  end)
end)
