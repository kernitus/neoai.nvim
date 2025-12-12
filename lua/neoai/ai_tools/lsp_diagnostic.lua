local M = {}
local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "LspDiagnostic",
  description = utils.read_description("lsp_diagnostic"),

  parameters = {
    type = "object",
    properties = {
      include_code_actions = {
        type = "boolean",
        description = "When true, also retrieve available code actions for the file.",
        default = false,
      },
      file_path = {
        type = "string",
        description = "Path to the file to inspect (relative to cwd). Use empty string to mean current buffer.",
        default = "",
      },
      bufnr = {
        type = "integer",
        description = "Buffer number to inspect. Use 0 to mean current buffer.",
        default = 0,
      },
    },
    required = {
      "include_code_actions",
      "file_path",
      "bufnr",
    },
    additionalProperties = false,
  },
}
--- Internal: resolve a buffer number from args without auto-creating new buffers
---@param args table|nil
---@return integer|nil
local function resolve_bufnr(args)
  args = args or {}
  local function normalise_path(path)
    if type(path) ~= "string" or path == "" then
      return nil
    end
    return vim.fn.fnamemodify(path, ":p")
  end

  if type(args.bufnr) == "number" and args.bufnr > 0 and vim.api.nvim_buf_is_valid(args.bufnr) then
    return args.bufnr
  end

  local normalised = normalise_path(args.file_path)
  if normalised then
    local existing = vim.fn.bufnr(normalised)
    if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
      if not vim.api.nvim_buf_is_loaded(existing) then
        pcall(vim.fn.bufload, existing)
      end
      args.file_path = vim.api.nvim_buf_get_name(existing)
      return existing
    end
    return nil
  end

  local current = vim.api.nvim_get_current_buf()
  if current and vim.api.nvim_buf_is_valid(current) then
    args.file_path = vim.api.nvim_buf_get_name(current)
    return current
  end

  return nil
end

--- Await an LSP DiagnosticChanged event (or timeout) then return current diagnostics count.
---@param args table: { file_path?: string, bufnr?: integer, timeout_ms?: integer }
---@return integer
function M.await_count(args)
  args = args or {}
  local bufnr = resolve_bufnr(args)
  if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then
    return 0
  end

  -- If no LSP clients, just return current diagnostics (likely none)
  local clients = {}
  if vim.lsp and vim.lsp.get_clients then
    clients = vim.lsp.get_clients({ bufnr = bufnr }) or {}
  end

  local initial = vim.diagnostic.get(bufnr) or {}
  if #clients == 0 then
    return #initial
  end

  -- If diagnostics already present, use them
  if #initial > 0 then
    return #initial
  end

  local timeout_ms = tonumber(args.timeout_ms) or 1200
  local updated = false
  local grp = vim.api.nvim_create_augroup("NeoAIAwaitDiagnostics_" .. tostring(bufnr), { clear = true })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = grp,
    buffer = bufnr,
    callback = function()
      updated = true
    end,
    once = true,
  })
  -- Wait for a publish cycle or timeout
  pcall(vim.wait, timeout_ms, function()
    return updated
  end, 50)
  pcall(vim.api.nvim_del_augroup_by_id, grp)

  local diags = vim.diagnostic.get(bufnr) or {}
  return #diags
end

local severity_map = {
  [vim.diagnostic.severity.ERROR] = "Error",
  [vim.diagnostic.severity.WARN] = "Warn",
  [vim.diagnostic.severity.INFO] = "Info",
  [vim.diagnostic.severity.HINT] = "Hint",
}

--- Runs the LSP diagnostic tool.
-- @param args table: {file_path: string, include_code_actions: boolean}
-- @return string: The diagnostics report, formatted as text.
M.run = function(args)
  args = args or {}

  local bufnr = resolve_bufnr(args)
  if not bufnr then
    local target = args.file_path
    if type(target) ~= "string" or target == "" then
      target = "current buffer"
    end
    return string.format(
      "Unable to locate a loaded buffer for %s. Open the file in Neovim (or pass bufnr) before requesting diagnostics.",
      target
    )
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    pcall(vim.fn.bufload, bufnr)
  end

  if not args.file_path or args.file_path == "" then
    args.file_path = vim.api.nvim_buf_get_name(bufnr)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return "Failed to load buffer for: " .. tostring(args.file_path)
  end

  -- Await at least one LSP diagnostic publish cycle (if a client is attached)
  pcall(M.await_count, { bufnr = bufnr, timeout_ms = 1200 })

  -- Get all diagnostics for this buffer
  local diags ---@type table
  diags = vim.diagnostic.get(bufnr)
  if vim.tbl_isempty(diags) then
    return "✅ No diagnostics for: " .. (args.file_path or bufnr)
  end

  -- Format each diagnostic
  local lines = {} ---@type string[]
  for _, d in ipairs(diags) do
    local line = d.lnum + 1
    local col = d.col + 1
    local sev = severity_map[d.severity] or tostring(d.severity)
    local src = d.source or ""
    table.insert(
      lines,
      string.format(
        "%s:%d:%d [%s] %s%s",
        args.file_path or "<buffer>",
        line,
        col,
        sev,
        d.message:gsub("\n", " "),
        (src ~= "" and string.format(" (%s)", src) or "")
      )
    )
  end

  local text = table.concat(lines, "\n") ---@type string
  -- Base diagnostics output
  local result = utils.make_code_block(text, "txt") ---@type string
  -- Append code actions if requested
  if args.include_code_actions then
    local code_action_tool = require("neoai.ai_tools.lsp_code_action")
    local ca = code_action_tool.run({ file_path = args.file_path })
    result = result .. "\n\n" .. ca
  end
  return result
end

return M
