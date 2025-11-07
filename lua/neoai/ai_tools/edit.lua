local utils = require("neoai.ai_tools.utils")
local finder = require("neoai.ai_tools.utils.find")

local M = {}

-- State to hold original content of the buffer being edited (for discard support).
local active_edit_state = {}

-- Accumulator for deferred, end-of-turn reviews. Keyed by absolute path.
-- Each entry: { baseline = {lines...}, latest = {lines...} }
local deferred_reviews = {}

--[[
  UTILITY FUNCTIONS

  NOTE: Callers must buffer the full tool-call arguments (no partial streaming)
  before invoking this tool. Partial calls will be ignored with a diagnostic.
--]]
local function split_lines(str)
  return vim.split(str, "\n", { plain = true })
end

local function normalise_eol(s)
  return (s or ""):gsub("\r\n", "\n"):gsub("\r", "")
end

local function strip_cr(lines)
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("\r$", "")
  end
end

local function leading_ws(s)
  return (s or ""):match("^%s*") or ""
end

local function min_indent_len(lines)
  local min_len
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local len = #leading_ws(l)
      if not min_len or len < min_len then
        min_len = len
      end
    end
  end
  return min_len or 0
end

local function range_min_indent_line(lines, s, e)
  local min_len, min_idx
  for i = s, math.max(s, e) do
    local l = lines[i]
    if l and l:match("%S") then
      local len = #leading_ws(l)
      if not min_len or len < min_len then
        min_len = len
        min_idx = i
      end
    end
  end
  return min_len or 0, min_idx
end

local function remove_leading_ws_chars(line, n)
  if n <= 0 then
    return line
  end
  local i, removed = 1, 0
  while removed < n and i <= #line do
    local ch = line:sub(i, i)
    if ch == " " or ch == "\t" then
      i = i + 1
      removed = removed + 1
    else
      break
    end
  end
  return line:sub(i)
end

local function dedent(lines)
  local n = min_indent_len(lines)
  if n <= 0 then
    return vim.deepcopy(lines)
  end
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("%S") then
      out[i] = remove_leading_ws_chars(l, n)
    else
      out[i] = ""
    end
  end
  return out
end

local function unrecognised_keys(tbl, allowed)
  local unk = {}
  if type(tbl) ~= "table" then
    return unk
  end
  for k, _ in pairs(tbl) do
    if not allowed[tostring(k)] then
      table.insert(unk, tostring(k))
    end
  end
  table.sort(unk)
  return unk
end

-- Best-effort diagnostics on proposed content without opening the review UI.
-- This tries to avoid flicker: if the target buffer is currently shown, we skip mutation.
local function best_effort_diagnostics(abs_path, proposed_lines)
  local lsp_diag = require("neoai.ai_tools.lsp_diagnostic")

  -- Find an existing loaded buffer for this path
  local bufnr = nil
  local target = vim.fn.fnamemodify(abs_path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if vim.fn.fnamemodify(name, ":p") == target then
        bufnr = b
        break
      end
    end
  end

  local function is_buf_visible(b)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == b then
        return true
      end
    end
    return false
  end

  local diagnostics_str, count = "", 0

  if bufnr and not is_buf_visible(bufnr) then
    -- Temporarily swap in proposed lines, query diagnostics, then restore
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local was_modified = vim.api.nvim_get_option_value("modified", { buf = bufnr })
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, proposed_lines)
    -- Give the LSP a moment and await counts
    pcall(lsp_diag.await_count, { bufnr = bufnr, timeout_ms = 1500 })
    diagnostics_str = lsp_diag.run({ file_path = abs_path, include_code_actions = false }) or ""
    count = #vim.diagnostic.get(bufnr)
    -- Restore content and modified flag
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, before)
    pcall(vim.api.nvim_set_option_value, "modified", was_modified, { buf = bufnr })
  else
    -- Use the high-level runner; may reflect current buffer state if visible, so treat as advisory.
    diagnostics_str = lsp_diag.run({ file_path = abs_path, include_code_actions = false }) or ""
    -- If we have a buffer, try to count; otherwise 0
    local b = bufnr
    if b then
      pcall(lsp_diag.await_count, { bufnr = b, timeout_ms = 1500 })
      count = #vim.diagnostic.get(b)
    else
      count = 0
    end
  end

  return diagnostics_str, count
end

-- This function is called from chat.lua to close an open diffview window.
function M.discard_all_diffs()
  local ok, diff_utils = pcall(require, "neoai.ai_tools.utils")
  if ok and diff_utils and diff_utils.inline_diff and diff_utils.inline_diff.close then
    diff_utils.inline_diff.close()
  end
  local bufnr = active_edit_state.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, active_edit_state.original_lines)
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
  end
  active_edit_state = {}
  return "All pending edits discarded and buffer reverted."
end

M.meta = {
  name = "Edit",
  description = utils.read_description("edit")
    .. " Edits may be provided in any order; the engine applies them order-invariantly and resolves overlaps."
    .. " Caller must buffer the full tool-call arguments before invoking this tool (no partial streaming).",
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = string.format("The path of the file to modify or create (relative to cwd %s)", vim.fn.getcwd()),
      },
      edits = {
        type = "array",
        description = "Array of edit operations, each containing old_string and new_string (plain text). Order is not required.",
        items = {
          type = "object",
          properties = {
            old_string = {
              type = "string",
              description = "Exact text block to replace (empty string means insert at beginning of file).",
            },
            new_string = {
              type = "string",
              description = "Replacement text block.",
            },
          },
          required = { "old_string", "new_string" },
          additionalProperties = false,
        },
      },
    },
    required = { "file_path", "edits" },
    additionalProperties = false,
  },
}

local function validate_edit(edit, index)
  if type(edit.old_string) ~= "string" then
    return string.format("Edit %d: 'old_string' must be a string", index)
  end
  if type(edit.new_string) ~= "string" then
    return string.format("Edit %d: 'new_string' must be a string", index)
  end
  return nil
end

-- Public helpers for the orchestrator
function M.get_deferred_paths()
  local paths = {}
  for p, v in pairs(deferred_reviews) do
    if v and v.baseline and v.latest then
      table.insert(paths, p)
    end
  end
  table.sort(paths)
  return paths
end

function M.has_deferred_reviews()
  for _, v in pairs(deferred_reviews) do
    if v and v.baseline and v.latest then
      return true
    end
  end
  return false
end

M.run = function(args)
  if type(args) ~= "table" then
    return string.format("Edit tool: ignored call; arguments must be an object/table (got %s)", type(args))
  end

  do
    local allowed_top = { file_path = true, edits = true }
    local unk = unrecognised_keys(args, allowed_top)
    if #unk > 0 then
      vim.notify(
        "Edit tool: unrecognised top-level argument keys: [" .. table.concat(unk, ", ") .. "]",
        vim.log.levels.WARN,
        { title = "NeoAI" }
      )
    end
  end

  local rel_path = args.file_path
  local edits = args.edits

  if type(rel_path) ~= "string" or type(edits) ~= "table" then
    local keys = {}
    for k, _ in pairs(args) do
      table.insert(keys, tostring(k))
    end
    table.sort(keys)

    local preview = ""
    pcall(function()
      preview = vim.inspect(args)
    end)
    if type(preview) == "string" and #preview > 4000 then
      preview = preview:sub(1, 4000) .. " ... (truncated)"
    end

    return string.format(
      "Edit tool: ignored call; expected 'file_path' (string) and 'edits' (array). Args keys: [%s]. Args preview: %s",
      table.concat(keys, ", "),
      preview
    )
  end

  local allowed_edit_keys = { old_string = true, new_string = true }
  for i, edit in ipairs(edits) do
    local err = validate_edit(edit, i)
    if err then
      local msg = "Edit tool error: " .. err
      vim.notify(msg, vim.log.levels.ERROR, { title = "NeoAI" })
      return msg
    end
    local unk = unrecognised_keys(edit, allowed_edit_keys)
    if #unk > 0 then
      vim.notify(
        string.format("Edit tool: unrecognised keys in edit %d: [%s]", i, table.concat(unk, ", ")),
        vim.log.levels.WARN,
        { title = "NeoAI" }
      )
    end
  end

  local cwd = vim.fn.getcwd()
  local abs_path = cwd .. "/" .. rel_path

  local content
  do
    local target = vim.fn.fnamemodify(abs_path, ":p")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if vim.fn.fnamemodify(name, ":p") == target then
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          content = table.concat(lines, "\n")
          break
        end
      end
    end
    if content == nil then
      local file = io.open(abs_path, "r")
      if file then
        content = file:read("*a") or ""
        file:close()
      else
        content = ""
      end
    end
  end

  local orig_lines = split_lines(normalise_eol(content))
  strip_cr(orig_lines)

  -- Apply order-invariant, multi-pass logic on a working copy (memory only)
  local working_lines = vim.deepcopy(orig_lines)
  local total_replacements = 0
  local skipped_already_applied = 0

  local pending = {}
  for i, edit in ipairs(edits) do
    local raw_old = normalise_eol(edit.old_string or "")
    local is_insert = (raw_old == "")
    local old_lines = is_insert and {} or split_lines(raw_old)
    if (not is_insert) and #old_lines == 1 and old_lines[1] == "" then
      is_insert = true
      old_lines = {}
    end
    local new_lines = split_lines(normalise_eol(edit.new_string or ""))
    strip_cr(old_lines)
    strip_cr(new_lines)
    table.insert(pending, {
      index = i,
      old_lines = old_lines,
      new_lines = new_lines,
      kind = is_insert and "insert" or "replace",
    })
  end

  local function apply_replacement_at(working, s, e, new_lines_)
    local base_indent = ""
    if s and e and s >= 1 and e >= s then
      local _, idx = range_min_indent_line(working, s, e)
      if idx and working[idx] then
        base_indent = leading_ws(working[idx])
      else
        base_indent = leading_ws(working[s] or "")
      end
    else
      base_indent = leading_ws(working[s] or "")
    end

    local adjusted_new = {}
    local dedented = dedent(new_lines_)
    for k, line in ipairs(dedented) do
      if line:match("%S") then
        adjusted_new[k] = base_indent .. line
      else
        adjusted_new[k] = ""
      end
    end

    local num_to_remove = e - s + 1
    if num_to_remove < 0 then
      num_to_remove = 0
    end
    for _ = 1, num_to_remove do
      table.remove(working, s)
    end
    for j, line in ipairs(adjusted_new) do
      table.insert(working, s - 1 + j, line)
    end
  end

  local max_passes = 3
  local pass = 0
  while #pending > 0 and pass < max_passes do
    pass = pass + 1
    local next_pending = {}

    local candidates = {}
    for _, item in ipairs(pending) do
      if item.kind == "replace" then
        local s, e = finder.find_block_location(working_lines, item.old_lines, 1, nil)
        if s then
          table.insert(candidates, { item = item, s = s, e = e })
        else
          local ns, _ = finder.find_block_location(working_lines, item.new_lines, 1, nil)
          if ns then
            skipped_already_applied = skipped_already_applied + 1
          else
            table.insert(next_pending, item)
          end
        end
      else
        table.insert(next_pending, item)
      end
    end

    table.sort(candidates, function(a, b)
      if a.s == b.s then
        return (a.e - a.s) < (b.e - b.s)
      end
      return a.s < b.s
    end)

    local selected = {}
    local last_end = 0
    for _, c in ipairs(candidates) do
      if c.s > last_end then
        table.insert(selected, c)
        last_end = c.e
      else
        table.insert(next_pending, c.item)
      end
    end

    for _, c in ipairs(selected) do
      local s_now, e_now = finder.find_block_location(working_lines, c.item.old_lines, 1, nil)
      if s_now then
        apply_replacement_at(working_lines, s_now, e_now, c.item.new_lines)
        total_replacements = total_replacements + 1
      else
        table.insert(next_pending, c.item)
      end
    end

    local inserts = {}
    for _, item in ipairs(next_pending) do
      if item.kind == "insert" then
        table.insert(inserts, item)
      end
    end
    if #inserts > 0 then
      local filtered = {}
      local to_insert_map = {}
      for _, it in ipairs(inserts) do
        to_insert_map[it] = true
      end
      for _, it in ipairs(next_pending) do
        if not to_insert_map[it] then
          table.insert(filtered, it)
        end
      end
      next_pending = filtered

      for _, ins in ipairs(inserts) do
        local pos = (pass == 1) and 1 or (#working_lines + 1)
        local ded = dedent(ins.new_lines)
        for j = #ded, 1, -1 do
          table.insert(working_lines, pos, ded[j])
        end
        total_replacements = total_replacements + 1
      end
    end

    pending = next_pending
  end

  if #pending > 0 then
    local first = pending[1]
    local preview_old = utils.make_code_block(table.concat(first.old_lines or {}, "\n"), "") or ""
    local preview_new = utils.make_code_block(table.concat(first.new_lines or {}, "\n"), "") or ""
    local verbose = table.concat({
      "Some edits could not be applied after multiple passes.",
      string.format("Unapplied edits remaining: %d", #pending),
      "Example (decoded) old block:",
      preview_old,
      "Example (decoded) new block:",
      preview_new,
    }, "\n\n")
    vim.notify("NeoAI Edit warning:\n" .. verbose, vim.log.levels.WARN, { title = "NeoAI" })
  end

  if total_replacements == 0 then
    if skipped_already_applied > 0 then
      return string.format("No changes needed in %s (%d edit(s) already applied).", rel_path, skipped_already_applied)
    end
    return string.format("No replacements made in %s.", rel_path)
  end

  local updated_lines = working_lines

  -- Accumulate into deferred review (baseline preserved from first edit)
  do
    local entry = deferred_reviews[abs_path]
    if entry == nil then
      deferred_reviews[abs_path] = { baseline = vim.deepcopy(orig_lines), latest = vim.deepcopy(updated_lines) }
    else
      entry.latest = vim.deepcopy(updated_lines)
      deferred_reviews[abs_path] = entry
    end
  end

  -- Best-effort diagnostics for AI self-correction (without opening the diff UI)
  local diagnostics_text, diag_count = best_effort_diagnostics(abs_path, updated_lines)

  -- Do not open inline diff UI here; defer to end-of-turn review
  -- Provide a compact, machine-friendly acknowledgement plus diagnostics back to the AI.
  local parts = {
    string.format("Queued edits for review in %s.", rel_path),
    string.format(
      "Edits summary: applied %d, skipped %d (already applied)",
      total_replacements,
      skipped_already_applied
    ),
  }
  if diagnostics_text and diagnostics_text ~= "" then
    table.insert(parts, diagnostics_text)
  else
    table.insert(
      parts,
      string.format("Diagnostics (post-edit, provisional): %d issue(s) detected.", tonumber(diag_count) or 0)
    )
  end
  return table.concat(parts, "\n\n")
end

function M.open_deferred_review(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return false, "Invalid file path"
  end
  local abs_path = file_path
  if not abs_path:match("^/") and not abs_path:match("^%a:[/\\]") then
    abs_path = vim.fn.getcwd() .. "/" .. file_path
  end
  local entry = deferred_reviews[abs_path]
  if not entry or not entry.baseline or not entry.latest then
    return false, "No pending deferred review for this file"
  end

  local function lines_equal(a, b)
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if a[i] ~= b[i] then
        return false
      end
    end
    return true
  end
  if lines_equal(entry.baseline, entry.latest) then
    deferred_reviews[abs_path] = nil
    return false, "No changes to review"
  end

  local ok, msg = utils.inline_diff.apply(abs_path, entry.baseline, entry.latest)
  if ok then
    active_edit_state = {
      bufnr = vim.fn.bufadd(abs_path),
      original_lines = entry.baseline,
    }
    -- Clear just this file from the accumulator now that the review is open
    deferred_reviews[abs_path] = nil
  end
  return ok, msg
end

function M.clear_deferred_review(file_path)
  if type(file_path) ~= "string" or file_path == "" then
    return
  end
  local abs_path = file_path
  if not abs_path:match("^/") and not abs_path:match("^%a:[/\\]") then
    abs_path = vim.fn.getcwd() .. "/" .. file_path
  end
  deferred_reviews[abs_path] = nil
end

return M
