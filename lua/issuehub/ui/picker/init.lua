---@brief Picker detection and dispatch (§9.1, §9.2).
---
--- Pickers are NEVER declared as dependencies. Detection is a runtime pcall,
--- because vim.pack has no optional-dependency concept and runtime probing is
--- the only portable mechanism (§1.3).

local M = {}

---Tiers, in detection order (§9.1).
local ORDER = { "snacks", "fzf", "telescope", "select" }

local MODULES = {
  snacks = "issuehub.ui.picker.snacks",
  fzf = "issuehub.ui.picker.fzf",
  telescope = "issuehub.ui.picker.telescope",
  select = "issuehub.ui.picker.select",
}

local resolved = nil

---@param name string
---@return issuehub.Picker?
local function load(name)
  local ok, picker = pcall(require, MODULES[name])
  if not ok then
    return nil
  end
  return picker
end

---@return issuehub.Picker
function M.get()
  if resolved then
    return resolved
  end

  local choice = require("issuehub.config").get().ui.picker

  if choice ~= "auto" then
    local picker = load(choice)
    if picker and picker.available() then
      resolved = picker
      return resolved
    end
    require("issuehub.util.log").warn(("ui.picker=%s is unavailable; falling back"):format(choice))
  end

  for _, name in ipairs(ORDER) do
    local picker = load(name)
    if picker and picker.available() then
      resolved = picker
      return resolved
    end
  end

  -- select.lua is built on vim.ui.select and is always available, so this is
  -- unreachable in practice.
  resolved = load("select")
  return resolved
end

---@return issuehub.PickerCaps
function M.caps()
  return M.get().caps
end

---@param view issuehub.View
---@param opts table?
function M.pick(view, opts)
  -- Remember it before showing: export and collection commands operate on the
  -- current view regardless of which picker rendered it.
  require("issuehub.ui.view").set_last(view)
  M.get().pick(view, opts or {})
end

function M.reset()
  resolved = nil
end

---Names of every picker backend currently usable. Reported by :checkhealth.
---@return string[]
function M.detected()
  local found = {}
  for _, name in ipairs(ORDER) do
    local picker = load(name)
    if picker and picker.available() then
      found[#found + 1] = name
    end
  end
  return found
end

return M
