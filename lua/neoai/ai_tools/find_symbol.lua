local M = {}
local utils = require("neoai.ai_tools.utils")
local symbol_index = require("neoai.ai_tools.symbol_index")

local SEARCH_TYPES = {
  definition = true,
  implementation = true,
  references = true,
}

local function matches_query(name, query)
  if not name then
    return false
  end
  return name == query or name:match("^" .. query .. "$") or name:match("%.?" .. query .. "$")
end

local function run_lsp_request(bufnr, method, params)
  local ok, resp = pcall(vim.lsp.buf_request_sync, bufnr or 0, method, params, 1500)
  if not ok or not resp then
    return {}
  end
  return resp
end

local function normalise_location(item)
  if item.location then
    return item.location
  end
  if item.uri and item.range then
    return { uri = item.uri, range = item.range }
  end
  if item.targetUri and item.targetRange then
    return { uri = item.targetUri, range = item.targetRange }
  end
  return nil
end

local function find_symbols(bufnr, query)
  local resp = run_lsp_request(bufnr, "workspace/symbol", { query = query })
  local symbols = {}
  for _, client_res in pairs(resp) do
    local items = client_res.result
    if items then
      for _, sym in ipairs(items) do
        if matches_query(sym.name, query) and sym.location then
          table.insert(symbols, sym)
        end
      end
    end
  end
  return symbols
end

local function add_definition_results(symbols, add)
  for _, sym in ipairs(symbols) do
    local location = sym.location
    if location and location.uri and location.range then
      local path = vim.uri_to_fname(location.uri)
      local rel_path = vim.fn.fnamemodify(path, ":.")
      local line = location.range.start.line + 1
      local kind = vim.lsp.protocol.SymbolKind[sym.kind] or "Symbol"
      add(string.format("- %s:%d [%s] (LSP)", rel_path, line, kind))
    end
  end
end

local function collect_location_results(resp, label, add)
  for _, client_res in pairs(resp) do
    local items = client_res.result
    if items then
      if items.uri and items.range then
        items = { items }
      end
      for _, entry in ipairs(items) do
        local location = normalise_location(entry)
        if location and location.uri and location.range then
          local path = vim.uri_to_fname(location.uri)
          local rel_path = vim.fn.fnamemodify(path, ":.")
          local line = (location.range.start and location.range.start.line or 0) + 1
          add(string.format("- %s:%d (%s)", rel_path, line, label))
        end
      end
    end
  end
end

local function lookup_locations_for_symbols(bufnr, symbols, method, label, opts, add)
  for _, sym in ipairs(symbols) do
    local location = sym.location
    if location and location.uri and location.range and location.range.start then
      local params = {
        textDocument = { uri = location.uri },
        position = location.range.start,
      }
      if opts and opts.include_declaration ~= nil then
        params.context = { includeDeclaration = opts.include_declaration }
      end
      local resp = run_lsp_request(bufnr, method, params)
      collect_location_results(resp, label, add)
    end
  end
end

M.run = function(args)
  local query = args.query
  if not query or query == "" then
    return "Error: Query is required"
  end

  local search_type = args.type or "definition"
  if not SEARCH_TYPES[search_type] then
    return "Error: Unsupported search type: " .. tostring(search_type)
  end

  local results = {}
  local seen = {}
  local function add(text)
    if not seen[text] then
      seen[text] = true
      table.insert(results, text)
    end
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local symbols = find_symbols(bufnr, query)

  if search_type == "definition" then
    add_definition_results(symbols, add)

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

    if #results == 0 then
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
            add(string.format("- %s:%s [Definition Match] (Text Scan)", parts[1], parts[2]))
          end
        end
      end
    end

    if #results == 0 then
      return "No definitions found for symbol: " .. query
    end
  elseif search_type == "implementation" then
    if #symbols == 0 then
      return "No definitions found to request implementations for symbol: " .. query
    end
    lookup_locations_for_symbols(bufnr, symbols, "textDocument/implementation", "Implementation", nil, add)
    if #results == 0 then
      return "No implementations found for symbol: " .. query
    end
  elseif search_type == "references" then
    if #symbols == 0 then
      return "No definitions found to request references for symbol: " .. query
    end
    lookup_locations_for_symbols(
      bufnr,
      symbols,
      "textDocument/references",
      "Reference",
      { include_declaration = true },
      add
    )
    if #results == 0 then
      return "No references found for symbol: " .. query
    end
  end

  return utils.make_code_block(table.concat(results, "\n"), "txt")
end

return M
