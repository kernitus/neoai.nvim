local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "LspCodeAction",
  description = utils.read_description("lsp_code_action"),
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = "Path to the file to inspect (relative to cwd). Use empty string to mean current buffer.",
        default = "",
      },
      action_index = {
        type = "integer",
        description = "Index of the code action to apply (1-based). Use 0 to list available actions without applying.",
        default = 0,
      },
    },
    required = {
      "file_path",
      "action_index",
    },
    additionalProperties = false,
  },
}

---
--- Runs the LSP code action with the given arguments.
---
--- @param args table: A table containing parameters:
--- - `file_path` (string): Path to the file to inspect, relative to cwd. Empty string means current buffer.
--- - `action_index` (integer): Index of the code action to apply (1-based). 0 means list actions without applying.
---
M.run = function(args)
  args = args or {}

  -- Coerce file_path to current buffer when empty
  local file_path = args.file_path
  if type(file_path) ~= "string" or file_path == "" then
    file_path = nil
  end

  ---@type integer
  local bufnr
  if file_path then
    bufnr = vim.fn.bufnr(file_path, true)
    vim.fn.bufload(bufnr)
  else
    bufnr = vim.api.nvim_get_current_buf()
    file_path = vim.api.nvim_buf_get_name(bufnr)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return "Failed to load buffer: " .. tostring(file_path)
  end

  ---@type table
  local params = vim.lsp.util.make_range_params()
  params.context = { diagnostics = vim.diagnostic.get(bufnr) }
  ---@type table
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/codeAction", params, 1000) or {}
  ---@type table
  local actions = {}
  for _, res in pairs(results) do
    if res.result then
      for _, action in ipairs(res.result) do
        table.insert(actions, action)
      end
    end
  end

  -- If no actions available
  if #actions == 0 then
    return utils.make_code_block("✅ No code actions available for: " .. (file_path or tostring(bufnr)), "txt")
  end

  -- Coerce action_index: 0 or negative means list only
  local action_index = tonumber(args.action_index) or 0
  if action_index > 0 then
    -- Execute the specified action
    if action_index > #actions then
      return "Invalid action_index: " .. tostring(action_index) .. " (only " .. #actions .. " actions available)"
    end
    local action = actions[action_index]
    -- Apply workspace edit if present
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit, "utf-8")
    end
    -- Execute command if present
    if action.command then
      vim.lsp.buf.execute_command(action.command)
    end
    return "Applied code action: " .. action.title
  end

  -- List available actions
  ---@type table
  local titles = {}
  for i, action in ipairs(actions) do
    table.insert(titles, string.format("%d. %s", i, action.title))
  end

  return utils.make_code_block(table.concat(titles, "\n"), "txt")
end

return M
