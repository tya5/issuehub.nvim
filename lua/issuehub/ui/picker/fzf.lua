---@brief fzf-lua adapter (§9.1, secondary tier).
local format = require("issuehub.ui.picker.format")

local M = {
  ---@type issuehub.PickerCaps
  --- preview is FALSE deliberately: this adapter does not implement one yet.
  --- Declaring a capability the adapter does not have is exactly what §9.2
  --- forbids — core would offer a preview that never appears. Implementing a
  --- fzf-lua previewer means subclassing its builtin previewer; until that is
  --- written and verified against a real fzf-lua, this stays honest.
  name = "fzf",
  caps = { preview = false, multi_select = true, actions = true },
}

function M.available()
  return (pcall(require, "fzf-lua"))
end

---@param view issuehub.View
---@param opts table
function M.pick(view, opts)
  local fzf = require("fzf-lua")
  local items = view:get_items()
  local w = format.widths(items)

  -- fzf works on strings, so keep a line → item map to recover the URI.
  local by_line, lines = {}, {}
  for _, item in ipairs(items) do
    local line = format.line(item, w)
    by_line[line] = item
    lines[#lines + 1] = line
  end

  local function resolve(selected)
    local out = {}
    for _, line in ipairs(selected or {}) do
      local item = by_line[line] or by_line[vim.trim(line)]
      if item then
        out[#out + 1] = item
      end
    end
    return out
  end

  fzf.fzf_exec(lines, {
    prompt = (opts.title or view.label) .. "> ",
    fzf_opts = { ["--multi"] = "", ["--no-sort"] = "" },
    actions = {
      ["default"] = function(selected)
        local picked = resolve(selected)
        if picked[1] then
          require("issuehub.ui.buffer").open(picked[1].uri)
        end
      end,
      ["ctrl-e"] = function(selected)
        view:set_selected(resolve(selected))
        vim.notify(("issuehub: %d issue(s) selected"):format(#view:get_selected()))
      end,
    },
  })
end

return M
