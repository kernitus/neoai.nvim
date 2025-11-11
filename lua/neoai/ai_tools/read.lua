--- @class Reader
--- @field file_path string: The path of the file to read (relative to the current working directory)
--- @field start_line number: Line number to start reading the content (use 1 for beginning)
--- @field end_line number: Line number to stop reading the content (use -1 for end of file)
local M = {}

local utils = require("neoai.ai_tools.utils")

M.meta = {
  name = "Read",
  description = utils.read_description("read"),
  parameters = {
    type = "object",
    properties = {
      file_path = {
        type = "string",
        description = "The path of the file to read (relative to the current working directory). Must not be empty.",
      },
      start_line = {
        type = "number",
        description = "Line number to start reading the content. Use 1 for beginning of file.",
        default = 1,
      },
      end_line = {
        type = "number",
        description = "Line number to stop reading the content. Use -1 to read to end of file.",
        default = -1,
      },
    },
    required = {
      "file_path",
      "start_line",
      "end_line",
    },
    additionalProperties = false,
  },
}

--- Executes the reading operation based on provided arguments.
--- @param args Reader: Arguments for the reading process
--- @return table<string, string>: The content and status display information
M.run = function(args)
  -- Validate file_path
  if not args.file_path or type(args.file_path) ~= "string" or args.file_path == "" then
    return { content = "Error: file_path is required and must not be empty", display = "Read: (failed - no path)" }
  end

  local pwd = vim.loop.cwd() or vim.fn.getcwd()
  local abs_path = args.file_path
  if not abs_path:match("^/") and not abs_path:match("^%a:[/\\]") then
    abs_path = pwd .. "/" .. abs_path
  end
  abs_path = vim.fn.fnamemodify(abs_path, ":p")

  -- Coerce start_line with default of 1
  local start_line = tonumber(args.start_line) or 1
  if start_line < 1 then
    start_line = 1
  end

  local function read_current_or_disk(path)
    local target = vim.fn.fnamemodify(path, ":p")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" and vim.fn.fnamemodify(name, ":p") == target then
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          return table.concat(lines, "\n"), b
        end
      end
    end
    local ok, lines = pcall(vim.fn.readfile, target)
    if ok and type(lines) == "table" then
      return table.concat(lines, "\n"), nil
    end
    local f = io.open(target, "rb")
    if f then
      local content = f:read("*a") or ""
      f:close()
      return content, nil
    end
    return nil, nil
  end

  local content, bufnr = read_current_or_disk(abs_path)
  if not content then
    return { content = "Cannot open file: " .. abs_path, display = "Read: " .. args.file_path .. " (failed)" }
  end

  local raw_lines = vim.split(content, "\n", { plain = true })
  local total_lines = #raw_lines

  -- Coerce end_line: -1 or nil or 0 means "end of file"
  local end_line = tonumber(args.end_line)
  if not end_line or end_line <= 0 or end_line == math.huge then
    end_line = total_lines
  elseif end_line > total_lines then
    end_line = total_lines
  elseif end_line < start_line then
    end_line = start_line
  end

  local lines = {}
  local width = #tostring(end_line)
  for ln = start_line, end_line do
    local line = raw_lines[ln] or ""
    table.insert(lines, string.format("%" .. width .. "d|%s", ln, line))
  end

  local function get_extension(filename)
    return filename:match("^.+%.([a-zA-Z0-9_]+)$") or ""
  end

  local ext = get_extension(abs_path)
  local text = table.concat(lines, "\n")
  local result = utils.make_code_block(text, ext)

  local diag_args = bufnr and { bufnr = bufnr, file_path = args.file_path } or { file_path = args.file_path }
  local diag = require("neoai.ai_tools.lsp_diagnostic").run(diag_args)
  local content_out = result .. "\n" .. diag
  local display = string.format(
    "Read: %s (%s:%s-%s)",
    args.file_path,
    ext ~= "" and ext or "txt",
    tostring(start_line),
    tostring(end_line)
  )
  return { content = content_out, display = display }
end

return M
