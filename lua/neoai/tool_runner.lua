local M = {}
local log = require("neoai.debug").log

-- Local apply_delay mirroring chat behaviour (without notify chatter)
local function apply_delay(callback)
  local delay = 0
  local ok, cfg = pcall(require, "neoai.config")
  if ok and cfg and type(cfg.get_api) == "function" then
    local ok2, api = pcall(cfg.get_api, "main")
    if ok2 and api and type(api.api_call_delay) == "number" then
      delay = api.api_call_delay
    end
  end
  if delay <= 0 then
    callback()
  else
    vim.defer_fn(function()
      callback()
    end, delay)
  end
end

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

--- Execute tool calls emitted by the model, persist messages, and then resume the model.
--- @param chat_module table
--- @param tool_schemas table
function M.run_tool_calls(chat_module, tool_schemas)
  local c = chat_module.chat_state
  local MT = chat_module.MESSAGE_TYPES
  local ai_tools = require("neoai.ai_tools")

  log("tool_runner: start | n=%d", #(tool_schemas or {}))
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

      local ok_args, args = pcall(vim.fn.json_decode, fn.arguments or "")
      if not ok_args then
        args = {}
      end

      local tool_found = false
      for _, tool in ipairs(ai_tools.tools) do
        if tool.meta and tool.meta.name == fn.name then
          tool_found = true

          log(
            "tool_runner: exec | id=%s name=%s arg_len=%d",
            tostring(schema.id),
            tostring(fn.name),
            #(tostring(fn.arguments or ""))
          )
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
            else
              content = type(resp) == "string" and resp or tostring(resp) or ""
            end
          end
          if content == "" then
            content = "No response"
          end

          log(
            "tool_runner: result | id=%s name=%s content_len=%d",
            tostring(schema.id),
            tostring(fn.name),
            #(tostring(content or ""))
          )
          log("tool_runner: add_message TOOL | tool_call_id=%s", tostring(schema.id))
          chat_module.add_message(MT.TOOL, tostring(content), meta, schema.id)

          completed = completed + 1
          break
        end
      end

      if not tool_found then
        local err = "Tool not found: " .. fn.name
        vim.notify(err, vim.log.levels.ERROR)
        chat_module.add_message(MT.TOOL, err, {}, schema.id)
        completed = completed + 1
      end
    end
  end

  if completed > 0 then
    log("tool_runner: completed=%d | scheduling send_to_ai", completed)
    apply_delay(function()
      chat_module.send_to_ai()
    end)
    -- Watchdog: if the loop did not resume for some reason, try again explicitly.
    vim.defer_fn(function()
      local active = chat_module.chat_state and chat_module.chat_state.streaming_active
      log("tool_runner: watchdog 800ms | streaming_active=%s", tostring(active))
      if not active then
        log("tool_runner: watchdog re-invoking send_to_ai()")
        pcall(chat_module.send_to_ai)
      end
    end, 800)
  else
    c.streaming_active = false
  end
end

return M
