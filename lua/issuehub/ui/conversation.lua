---@brief The conversation window: analysis history plus the prompt.
---
--- The prompt used to live in the issue buffer, wedged between memo and
--- metadata, with the answers it produced somewhere else entirely. That is the
--- wrong shape: a prompt is one turn of a conversation, and you write the next
--- one by reading the previous ones.
---
--- This is a side window holding that conversation — every past prompt and
--- response, oldest first — with the next prompt at the bottom, editable and
--- written to `prompt.md` on `:w`.

local analysis = require("issuehub.core.analysis")
local overlay = require("issuehub.core.overlay")

local M = {}

local ns = vim.api.nvim_create_namespace("issuehub_conversation")
local augroup = vim.api.nvim_create_augroup("issuehub_conversation", { clear = true })

local PROMPT_HEADING = "## Prompt"

---@type table<integer, string>
local tracked = {}

---@param uri string
---@return string
local function bufname(uri)
  return ("issuehub://%s/conversation"):format(uri:gsub("://", "/"))
end

---@param uri string
---@return string[] lines
---@return integer prompt_line   1-indexed line of the prompt heading.
function M.render(uri)
  local lines = { ("# Conversation — %s"):format(uri), "" }

  local entries = analysis.list(uri)
  if #entries == 0 then
    lines[#lines + 1] = "_No analyses yet. Write a prompt below and run `:IssueHub analyze`._"
    lines[#lines + 1] = ""
  else
    -- Oldest first: a conversation reads downward, and the newest answer ends
    -- up next to the prompt box where you are about to write.
    for i = #entries, 1, -1 do
      local entry = entries[i]
      lines[#lines + 1] = ("### %s  ·  %s%s"):format(
        entry.created_at,
        entry.model or entry.backend or "unknown",
        entry.status == "outdated" and "  ·  OUTDATED" or ""
      )
      lines[#lines + 1] = ""
      lines[#lines + 1] = "> " .. entry.prompt:gsub("\n", "\n> ")
      lines[#lines + 1] = ""
      for _, line in ipairs(vim.split(entry.response, "\n", { plain = true })) do
        lines[#lines + 1] = line
      end
      lines[#lines + 1] = ""
    end
  end

  local prompt_line = #lines + 1
  lines[#lines + 1] = PROMPT_HEADING
  lines[#lines + 1] = ""
  for _, line in ipairs(vim.split(overlay.read(uri).prompt, "\n", { plain = true })) do
    lines[#lines + 1] = line
  end
  if lines[#lines] ~= "" then
    lines[#lines + 1] = ""
  end

  return lines, prompt_line
end

---Everything below the prompt heading, which is the only editable part.
---@param buf integer
---@return string?
function M.extract_prompt(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local at
  for i, line in ipairs(lines) do
    if line == PROMPT_HEADING then
      at = i
    end
  end
  if not at then
    return nil
  end
  local body = {}
  for i = at + 1, #lines do
    body[#body + 1] = lines[i]
  end
  return (table.concat(body, "\n"):gsub("^%s*\n", ""):gsub("%s+$", ""))
end

---@param buf integer
---@return boolean ok
function M.save(buf)
  local uri = tracked[buf]
  if not uri then
    return false
  end

  local prompt = M.extract_prompt(buf)
  if not prompt then
    vim.notify("issuehub: cannot save — the `## Prompt` heading is gone", vim.log.levels.ERROR)
    return false
  end

  local written, err = overlay.write(uri, { prompt = prompt })
  if err then
    vim.notify("issuehub: " .. err, vim.log.levels.ERROR)
    return false
  end

  vim.bo[buf].modified = false
  vim.notify(#written > 0 and "issuehub: wrote prompt" or "issuehub: no changes", vim.log.levels.INFO)
  return true
end

---@param buf integer
---@param prompt_line integer
local function decorate(buf, prompt_line)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if prompt_line <= vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_buf_set_extmark(buf, ns, prompt_line - 1, 0, {
      virt_text = { { "  editable → prompt.md   ·   :w to save, :IssueHub analyze to run", "IssueHubEditable" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
    vim.api.nvim_buf_set_extmark(buf, ns, prompt_line - 1, 0, {
      virt_lines_above = true,
      virt_lines = { { { ("─"):rep(30) .. " next turn ", "IssueHubDivider" } } },
    })
  end
end

---@param uri string
---@param buf integer
function M.refresh(uri, buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines, prompt_line = M.render(uri)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  decorate(buf, prompt_line)
end

---Open the conversation for a URI in a window on the right.
---@param uri string?
---@param opts { focus: boolean? }?
function M.open(uri, opts)
  opts = opts or {}
  uri = uri or require("issuehub.ui.buffer").current_uri()
  if not uri then
    return vim.notify("issuehub: open an issue first", vim.log.levels.WARN)
  end

  local name = bufname(uri)
  local buf
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(candidate) and vim.api.nvim_buf_get_name(candidate):sub(-#name) == name then
      buf = candidate
      break
    end
  end

  if not buf then
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "hide"
    tracked[buf] = uri

    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = augroup,
      buffer = buf,
      callback = function()
        M.save(buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = augroup,
      buffer = buf,
      callback = function()
        tracked[buf] = nil
      end,
    })
  end
  tracked[buf] = uri

  -- Reuse the window if this conversation is already on screen.
  local window
  for _, candidate in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(candidate) == buf then
      window = candidate
      break
    end
  end

  if not window then
    local current = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(window, buf)
    vim.wo[window].wrap = true
    vim.wo[window].linebreak = true
    if not opts.focus then
      vim.api.nvim_set_current_win(current)
    end
  elseif opts.focus then
    vim.api.nvim_set_current_win(window)
  end

  M.refresh(uri, buf)

  -- Put the cursor where you would type.
  if opts.focus then
    local _, prompt_line = M.render(uri)
    pcall(vim.api.nvim_win_set_cursor, window, { math.min(prompt_line + 1, vim.api.nvim_buf_line_count(buf)), 0 })
  end

  return buf
end

---Repaint any open conversation for this URI. Called after an analysis lands.
---@param uri string
function M.update(uri)
  for buf, tracked_uri in pairs(tracked) do
    if tracked_uri == uri and vim.api.nvim_buf_is_valid(buf) then
      M.refresh(uri, buf)
    end
  end
end

return M
