---@brief vim.ui.select fallback — capability Level 2 (§9.1).
---
--- This exists so issuehub functions with zero plugins installed. It is NOT a
--- target for feature parity: vim.ui.select offers a single column, no preview,
--- no async filtering, and no multi-select. Anyone browsing issues seriously
--- should install one of the Level 1 pickers.

local format = require("issuehub.ui.picker.format")

local M = {
  name = "select",
  ---@type issuehub.PickerCaps
  caps = { preview = false, multi_select = false, actions = false },
}

function M.available()
  return true
end

---@param view issuehub.View
---@param opts table
function M.pick(view, opts)
  local items = view:get_items()
  if #items == 0 then
    vim.notify("issuehub: no issues", vim.log.levels.INFO)
    return
  end

  vim.ui.select(items, {
    prompt = opts.title or view.label,
    format_item = format.plain,
  }, function(item)
    if item then
      require("issuehub.ui.buffer").open(item.uri)
    end
  end)
end

return M
