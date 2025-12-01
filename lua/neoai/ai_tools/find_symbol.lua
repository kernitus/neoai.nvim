local M = {}
local utils = require("neoai.ai_tools.utils")
local symbol_index = require("neoai.ai_tools.symbol_index")

M.run = function(args)
  local query = args.query
  if not query or query == "" then
    return "Error: Query is required"
  end

  local results = {}
  local seen = {}

  local function add(text)
    if not seen[text] then
      seen[text] = true
      table.insert(results, text)
    end
  end

  -- 1. LSP Lookup (Best)
  local lsp_ok, lsp_resp = pcall(vim.lsp.buf_request_sync, 0, "workspace/symbol", { query = query }, 1500)
  if lsp_ok and lsp_resp then
    for _, client_res in pairs(lsp_resp) do
      if client_res.result then
        for _, sym in ipairs(client_res.result) do
          -- Strict matching to avoid noise
          if sym.name == query or sym.name:match("^" .. query .. "$") or sym.name:match("%.?" .. query .. "$") then
            local path = vim.uri_to_fname(sym.location.uri)
            local rel_path = vim.fn.fnamemodify(path, ":.")
            local line = sym.location.range.start.line + 1
            local kind = vim.lsp.protocol.SymbolKind[sym.kind] or "Symbol"
            add(string.format("- %s:%d [%s] (LSP)", rel_path, line, kind))
          end
        end
      end
    end
  end

  -- 2. Tree-sitter Fallback (Better)
  if #results == 0 then
    local scan_args = {
      path = ".",
      globs = { "**/*" },
      max_files = 100,
      include_docstrings = false,
      languages = (args.language and args.language ~= "") and { args.language } or {},
    }

    local scan_data = symbol_index.scan(scan_args)
    if scan_data then
      for _, file_data in ipairs(scan_data) do
        if file_data.symbols then
          for _, sym in ipairs(file_data.symbols) do
            if sym.name == query then
              add(string.format("- %s:%d [%s] (Tree-sitter)", file_data.file, sym.line or 0, sym.kind))
            end
          end
        end
      end
    end
  end

  -- 3. Heuristic Text Fallback (Good enough)
  -- This is NOT a general grep. It specifically looks for definition patterns.
  if #results == 0 then
    -- Regex matches: "class Query", "function Query", "val Query", "def Query"
    -- \b ensures we don't match "QueryBuilder" when looking for "Query"
    local pattern =
      string.format("'^[\\t ]*(class|function|fun|fn|def|val|var|local function|interface|trait)\\s+%s\\b'", query)
    local grep_cmd = string.format("rg --vimgrep --no-heading --color never -e %s .", pattern)

    local handle = io.popen(grep_cmd)
    if handle then
      local out = handle:read("*a")
      handle:close()
      for s in (out or ""):gmatch("[^\r\n]+") do
        local parts = vim.split(s, ":")
        if #parts >= 4 then
          -- parts[1]=file, parts[2]=line
          add(string.format("- %s:%s [Definition Match] (Text Scan)", parts[1], parts[2]))
        end
      end
    end
  end

  if #results == 0 then
    return "No definitions found for symbol: " .. query
  end

  return utils.make_code_block(table.concat(results, "\n"), "txt")
end

return M
