local view_mod = require("issuehub.ui.view")
local issue = require("issuehub.core.issue")

local function make(id, closed, updated)
  return issue.normalize({
    provider = "jira",
    id = id,
    title = id .. " title",
    status = { id = "1", name = closed and "Done" or "Open", closed = closed },
    updated_at = updated,
  })
end

describe("view", function()
  it("sorts open first, then newest", function()
    local view = view_mod.from_issues({
      make("A", true, "2026-07-19T00:00:00Z"),
      make("B", false, "2026-07-01T00:00:00Z"),
      make("C", false, "2026-07-18T00:00:00Z"),
    })
    local ids = vim.tbl_map(function(i)
      return i.id
    end, view:get_items())
    assert.same({ "C", "B", "A" }, ids)
  end)

  it("falls back to all items when nothing is selected", function()
    -- This is what lets a picker without multi_select degrade gracefully
    -- instead of erroring (§9.2).
    local view =
      view_mod.from_issues({ make("A", false, "2026-07-19T00:00:00Z"), make("B", false, "2026-07-18T00:00:00Z") })
    assert.equals(2, #view:get_selected())
  end)

  it("honours an explicit selection", function()
    local view =
      view_mod.from_issues({ make("A", false, "2026-07-19T00:00:00Z"), make("B", false, "2026-07-18T00:00:00Z") })
    view:set_selected({ view:get_items()[1] })
    assert.equals(1, #view:get_selected())
  end)

  it("slugifies its label for export filenames", function()
    assert.equals("sprint-a-critical", view_mod.new({ label = "Sprint A: Critical!", items = {} }):slug())
    assert.equals("issues", view_mod.new({ label = "***", items = {} }):slug())
  end)
end)

describe("picker capabilities", function()
  it("are declared honestly", function()
    -- A capability the adapter does not implement makes core promise something
    -- that never appears (§9.2). snacks previews via ctx.preview, telescope via
    -- a buffer previewer; fzf has none yet and says so.
    local expectations = {
      snacks = { preview = true, multi_select = true, actions = true },
      telescope = { preview = true, multi_select = true, actions = true },
      fzf = { preview = false, multi_select = true, actions = true },
      select = { preview = false, multi_select = false, actions = false },
    }

    for name, expected in pairs(expectations) do
      local adapter = require("issuehub.ui.picker." .. name)
      assert.same(expected, adapter.caps)
      assert.equals(name, adapter.name)
      assert.equals("function", type(adapter.pick))
      assert.equals("function", type(adapter.available))
    end
  end)
end)
