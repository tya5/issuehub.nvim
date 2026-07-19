---@brief telescope.nvim adapter (§9.1, compatible tier).
---
--- Kept in step, but not driving design: upstream is in maintenance mode.

local format = require("issuehub.ui.picker.format")

local M = {
  name = "telescope",
  ---@type issuehub.PickerCaps
  caps = { preview = true, multi_select = true, actions = true },
}

function M.available()
  return (pcall(require, "telescope"))
end

---@param view issuehub.View
---@param opts table
function M.pick(view, opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local items = view:get_items()
  local w = format.widths(items)

  pickers
    .new(opts.telescope or {}, {
      prompt_title = opts.title or view.label,
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            display = format.line(item, w),
            -- ordinal is what telescope matches; notes ride along unseen.
            ordinal = ("%s %s %s %s"):format(item.id, item.status, item.title, item.notes or ""),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Issue",
        define_preview = function(self, entry)
          require("issuehub.ui.buffer").preview(entry.value.uri, self.state.bufnr)
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local entry = action_state.get_selected_entry()
          if entry then
            require("issuehub.ui.buffer").open(entry.value.uri)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
