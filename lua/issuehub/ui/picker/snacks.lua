---@brief snacks.picker adapter — the primary UI backend (§9.1).
local format = require("issuehub.ui.picker.format")

local M = {
  name = "snacks",
  ---@type issuehub.PickerCaps
  caps = { preview = true, multi_select = true, actions = true },
}

function M.available()
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks.picker ~= nil
end

---@param view issuehub.View
---@param opts table
function M.pick(view, opts)
  local snacks = require("snacks")
  local items = view:get_items()
  local w = format.widths(items)

  local entries = {}
  for i, item in ipairs(items) do
    entries[#entries + 1] = {
      idx = i,
      text = format.line(item, w),
      item = item,
      uri = item.uri,
    }
  end

  snacks.picker.pick({
    title = opts.title or view.label,
    items = entries,
    format = function(entry)
      return { { entry.text } }
    end,
    -- snacks hands the previewer an object, not a buffer handle: writing to a
    -- bufnr here silently previewed nothing and errored in the preview pane.
    preview = function(ctx)
      ctx.preview:reset()
      ctx.preview:set_title(ctx.item.item.id or "issue")
      ctx.preview:set_lines(require("issuehub.ui.buffer").preview_lines(ctx.item.uri))
      ctx.preview:highlight({ ft = "markdown" })
      return true
    end,
    confirm = function(picker, entry)
      picker:close()
      if entry then
        require("issuehub.ui.buffer").open(entry.item.uri)
      end
    end,
    actions = {
      export = function(picker)
        local selected = picker:selected({ fallback = true })
        view:set_selected(vim.tbl_map(function(e)
          return e.item
        end, selected))
        picker:close()
        vim.notify(("issuehub: %d issue(s) selected"):format(#view:get_selected()))
      end,
    },
  })
end

return M
