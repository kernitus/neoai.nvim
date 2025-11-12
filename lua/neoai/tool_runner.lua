local M = {}
local log = require("neoai.debug").log

-- Ensure each streamed tool schema has a stable id so we can pair responses.
local function ensure_tool_ids(tool_schemas)
  local stamp = tostring(os.time())
  for i, sc in ipairs(tool_schemas or {}) do
    if sc and (sc.id == nil or sc.id == "") then
      local idx = sc.index or i
      sc.id = string.format("tc-%s-%d", stamp, idx)
    end
  end
end

local function preview_str(v, max_len)
  max_len = max_len or 2000
  local s
  if type(v) == "string" then
    s = v
  else
    local ok, enc = pcall(vim.fn.json_encode, v)
    s = ok and enc or tostring(v)
  end
  s = tostring(s):gsub("\r", "\r"):gsub("\n", "\n")
  if #s > max_len then
    s = s:sub(1, max_len) .. " ... (truncated)"
  end
  return s
end

local function dump_failed_tool_call(schema, tool_name, reason, raw_args, decoded_args)
  local dir = vim.fn.stdpath("data") .. "/neoai_logs"
  pcall(vim.fn.mkdir, dir, "p")
  local fname = string.format(
    "failed_tool_%s_%s_%s.json",
    os.date("%Y%m%d_%H%M%S"),
    tostring(schema.id or "noid"),
    tostring(tool_name or "noname")
  )
  local path = dir .. "/" .. fname

  local payload = {
    id = schema.id,
    name = tool_name,
    reason = reason,
    raw_arguments = raw_args,
    decoded_arguments = decoded_args,
  }

  local ok, json = pcall(vim.fn.json_encode, payload)
  if not ok then
    local payload2 = {
      id = schema.id,
      name = tool_name,
      reason = reason,
      raw_arguments = type(raw_args) == "string" and raw_args or tostring(raw_args),
      decoded_arguments = type(decoded_args) == "table" and decoded_args or tostring(decoded_args),
      note = "json_encode failed on first attempt; coerced non-serialisable values to strings",
    }
    ok, json = pcall(vim.fn.json_encode, payload2)
  end

  if ok and json then
    local f = io.open(path, "w")
    if f then
      f:write(json)
      f:close()
    end
  end
  return path
end

--- Execute tool calls emitted by the model, persist messages, and then resume the model.
--- @param chat_module table
--- @param tool_schemas table
function M.run_tool_calls(chat_module, tool_schemas)
  local c = chat_module.chat_state
  local MT = chat_module.MESSAGE_TYPES
  local ai_tools = require("neoai.ai_tools")

  log("tool_runner: start | n=%d", #(tool_schemas or {}))

  -- Summary for the orchestrator (chat.get_tool_calls) to decide present vs resume
  local summary = { request_review = false, paths = {} }

  for _, sc in ipairs(tool_schemas or {}) do
    log(
      "tool_runner: schema pre | idx=%s id=%s name=%s",
      tostring(sc and sc.index),
      tostring(sc and sc.id),
      sc and sc["function"] and sc["function"].name or "<nil>"
    )
  end

  if #tool_schemas == 0 then
    vim.notify("No valid tool calls found", vim.log.levels.WARN)
    c.streaming_active = false
    return
  end

  ensure_tool_ids(tool_schemas)
  for _, sc in ipairs(tool_schemas or {}) do
    log(
      "tool_runner: schema post | idx=%s id=%s name=%s",
      tostring(sc and sc.index),
      tostring(sc and sc.id),
      sc and sc["function"] and sc["function"].name or "<nil>"
    )
  end

  -- Persist an assistant "Tool call" message that carries tool_calls (ids included)
  local call_names = {}
  for _, sc in ipairs(tool_schemas) do
    if sc and sc["function"] and sc["function"].name and sc["function"].name ~= "" then
      table.insert(call_names, sc["function"].name)
    end
  end
  local call_title = (#call_names > 0) and ("**Tool call:** " .. table.concat(call_names, ", ")) or "**Tool call**"
  chat_module.add_message(MT.ASSISTANT, call_title, {}, nil, tool_schemas)
  log("tool_runner: persisted assistant tool_calls")

  local completed = 0

  -- Execute each call and persist a Tool message with tool_call_id matching the assistant.tool_calls id
  for _, schema in ipairs(tool_schemas) do
    if schema.type == "function" and schema["function"] and schema["function"].name then
      local fn = schema["function"]

      local tool_found = false
      for _, tool in ipairs(ai_tools.tools) do
        if tool.meta and tool.meta.name == fn.name then
          tool_found = true

          -- Accept both JSON string and table for arguments
          local raw = fn.arguments
          local args, decode_err
          if type(raw) == "table" then
            args = raw
          elseif type(raw) == "string" then
            if raw == "" then
              decode_err = "empty string"
            else
              local ok_dec, decoded = pcall(vim.fn.json_decode, raw)
              if ok_dec and type(decoded) == "table" then
                args = decoded
              else
                decode_err = ok_dec and "decoded non-table" or tostring(decoded)
              end
            end
          else
            decode_err = "unexpected type: " .. type(raw)
          end

          if type(args) ~= "table" then
            local raw_prev = type(raw) == "string" and preview_str(raw, 2000) or preview_str(vim.inspect(raw), 2000)
            local reason = "decode_failed: " .. tostring(decode_err)
            local dump_path = dump_failed_tool_call(schema, fn.name, reason, raw, nil)
            local msg = string.format(
              "Tool args decode failed for %s (id=%s): %s\nRaw arguments preview:\n%s\nDump written: %s",
              tostring(fn.name),
              tostring(schema.id),
              tostring(decode_err),
              raw_prev,
              dump_path or "<n/a>"
            )
            vim.notify(msg, vim.log.levels.ERROR)
            log("%s", msg)
            chat_module.add_message(MT.TOOL, msg, { tool_name = fn.name, decode_error = decode_err }, schema.id)
            completed = completed + 1
            goto continue_schema
          end

          -- Check for required keys strictly before executing
          local missing = {}
          do
            local req = tool.meta and tool.meta.parameters and tool.meta.parameters.required
            if type(req) == "table" then
              for _, k in ipairs(req) do
                if args[k] == nil then
                  table.insert(missing, k)
                end
              end
            end
          end

          if #missing > 0 then
            local ok_json, args_json_str = pcall(vim.fn.json_encode, args)
            local args_prev = ok_json and preview_str(args_json_str, 2000) or preview_str(vim.inspect(args), 2000)
            local raw_prev = type(raw) == "string" and preview_str(raw, 2000) or preview_str(vim.inspect(raw), 2000)
            local reason = "missing_required_keys: [" .. table.concat(missing, ", ") .. "]"
            local dump_path = dump_failed_tool_call(schema, fn.name, reason, raw, args)
            local msg = string.format(
              "Tool args missing required keys for %s (id=%s): [%s]\nDecoded args preview:\n%s\nRaw arguments preview:\n%s\nDump written: %s",
              tostring(fn.name),
              tostring(schema.id),
              table.concat(missing, ", "),
              args_prev,
              raw_prev,
              dump_path or "<n/a>"
            )
            vim.notify(msg, vim.log.levels.WARN)
            log("%s", msg)
            chat_module.add_message(MT.TOOL, msg, { tool_name = fn.name, schema_mismatch = true }, schema.id)
            completed = completed + 1
            goto continue_schema
          end

          -- Execute tool only when decode and schema checks pass
          local resp_ok, resp = pcall(tool.run, args)

          local meta = { tool_name = fn.name }
          local content
          if not resp_ok then
            content = "Error executing tool " .. fn.name .. ": " .. tostring(resp)
            vim.notify(content, vim.log.levels.ERROR)
          else
            if type(resp) == "table" then
              content = resp.content or ""
              if resp.display and resp.display ~= "" then
                meta.display = resp.display
              end
              if resp.params_line and resp.params_line ~= "" then
                content = (content ~= "" and (tostring(resp.params_line) .. "\n\n" .. content))
                  or tostring(resp.params_line)
              end

              -- PresentEdits integration: propagate request to open review UI
              if resp.request_review then
                summary.request_review = true
                if type(resp.open_paths) == "table" then
                  for _, p in ipairs(resp.open_paths) do
                    table.insert(summary.paths, p)
                  end
                elseif type(resp.abs_path) == "string" then
                  table.insert(summary.paths, resp.abs_path)
                end
                meta.request_review = true
              end
              content = type(resp) == "string" and resp or tostring(resp) or ""
            end
          end
          if content == "" then
            content = "No response"
          end

          chat_module.add_message(MT.TOOL, tostring(content), meta, schema.id)

          completed = completed + 1
          break
        end
      end
      ::continue_schema::

      if not tool_found then
        local err = "Tool not found: " .. fn.name
        vim.notify(err, vim.log.levels.ERROR)
        chat_module.add_message(MT.TOOL, err, {}, schema.id)
        completed = completed + 1
      end
    end
  end
  -- Do not auto-resume here; let chat.get_tool_calls decide whether to present or resume.
  if completed == 0 then
    c.streaming_active = false
  end

  return summary
end
return M
