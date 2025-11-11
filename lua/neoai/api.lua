local Job = require("plenary.job")
local conf = require("neoai.config").get_api("main")
local chat_tool_schemas = require("neoai.ai_tools").tool_schemas
local log = require("neoai.debug").log

local api = {}

-- Track current streaming job
--- @type Job|nil
local current_job = nil

-- Single queued stream request (if a new request arrives whilst one is active)
local queued_stream = nil

--- Merges two tables into a new one (shallow).
--- @param t1 table
--- @param t2 table
--- @return table
local function merge_tables(t1, t2)
  local result = {}
  for k, v in pairs(t1 or {}) do
    result[k] = v
  end
  for k, v in pairs(t2 or {}) do
    result[k] = v
  end
  return result
end

--- Convert Chat-style function tools into Responses API tool shape (internally-tagged).
--- Chat-style:
---   { type="function", ["function"]={ name, description, parameters, strict? } }
--- Responses-style:
---   { type="function", name, description, parameters, strict? }
--- @param tools table
--- @return table
local function to_responses_tools(tools)
  local out = {}
  for _, t in ipairs(tools or {}) do
    if t and t.type == "function" and t["function"] then
      local f = t["function"]
      table.insert(out, {
        type = "function",
        name = f.name,
        description = f.description,
        parameters = f.parameters,
        strict = (f.strict ~= nil) and f.strict or true,
      })
    else
      table.insert(out, t)
    end
  end
  return out
end

--- Merge user-configured native tools (if any) into the outgoing tools list.
--- @param base table
--- @param native any
--- @return table
local function merge_native_tools(base, native)
  if type(native) == "table" then
    for _, t in ipairs(native) do
      table.insert(base, t)
    end
  end
  return base
end

local function is_reasoning_model(name)
  local n = tostring(name or ""):lower()
  if n:match("^gpt%-5") then
    return true
  end
  if n:match("^o%d") or n:match("^o%-") then
    return true
  end
  return false
end

--- Convert Chat-style messages to Responses Items + instructions.
local function chat_messages_to_items(messages)
  local items = {}
  local instructions_parts = {}

  local function add_instructions(s)
    if s and s ~= "" then
      table.insert(instructions_parts, s)
    end
  end

  for _, m in ipairs(messages or {}) do
    local role = m.role
    local content = m.content or ""
    if role == "system" then
      add_instructions(content)
    elseif role == "user" then
      table.insert(items, {
        type = "message",
        role = "user",
        content = { { type = "input_text", text = content } },
      })
    elseif role == "assistant" then
      local tcs = m.tool_calls
      if type(tcs) == "table" and #tcs > 0 then
        for _, tc in ipairs(tcs) do
          local fn = tc["function"] or {}
          local args = fn.arguments
          if type(args) ~= "string" then
            local ok, enc = pcall(vim.fn.json_encode, args)
            args = ok and enc or tostring(args)
          end
          local call_id = tc.call_id or tc.id or ("tc-" .. tostring(tc.index or 0))
          table.insert(items, {
            type = "function_call",
            call_id = tostring(call_id),
            name = fn.name or "",
            arguments = args or "{}",
          })
        end
      else
        if content ~= "" then
          table.insert(items, {
            type = "message",
            role = "assistant",
            content = { { type = "output_text", text = content } },
          })
        end
      end
    elseif role == "tool" then
      local call_id = m.tool_call_id or m.id or ""
      table.insert(items, {
        type = "function_call_output",
        call_id = tostring(call_id),
        output = content,
      })
    end
  end

  local instructions = table.concat(instructions_parts, "\n\n")
  return items, instructions
end

--- Start streaming a Responses API generation
--- @param messages table
--- @param on_chunk fun(chunk: table)
--- @param on_complete fun()
--- @param on_error fun(err: integer|string)
--- @param on_cancel fun()|nil
function api.stream(messages, on_chunk, on_complete, on_error, on_cancel)
  log("api.stream: start (Responses) | messages=%d model=%s", #(messages or {}), tostring(conf.model))

  if current_job ~= nil then
    log("api.stream: busy; queuing next stream request")
    queued_stream = {
      messages = messages,
      on_chunk = on_chunk,
      on_complete = on_complete,
      on_error = on_error,
      on_cancel = on_cancel,
    }
    return
  end

  local error_reported = false
  local non_sse_buf = {}
  local http_status
  local saw_any_chunk = false
  local completed = false
  local done_seen = false

  local tools = to_responses_tools(chat_tool_schemas)
  tools = merge_native_tools(tools, conf.native_tools)

  local items, instructions = chat_messages_to_items(messages)

  local basic_payload = {
    model = conf.model,
    input = items,
    stream = true,
    tools = tools,
    max_output_tokens = conf.max_output_tokens,
    store = false,
  }
  if instructions and instructions ~= "" then
    basic_payload.instructions = instructions
  end

  local payload_tbl = merge_tables(basic_payload, conf.additional_kwargs or {})
  payload_tbl.store = false
  payload_tbl.previous_response_id = nil
  payload_tbl.conversation = nil
  payload_tbl.thread_id = nil

  if is_reasoning_model(conf.model) then
    payload_tbl.reasoning = payload_tbl.reasoning or {}
    if payload_tbl.reasoning.summary == nil then
      payload_tbl.reasoning.summary = "auto"
    end
  else
    payload_tbl.reasoning = nil
  end

  local payload = vim.fn.json_encode(payload_tbl)

  if conf.debug_payload then
    vim.notify(
      "NeoAI: Sending JSON payload to curl (Responses stream):\n" .. payload,
      vim.log.levels.DEBUG,
      { title = "NeoAI" }
    )
  end

  local raw_body_chunks = {}

  -- Function-call accumulator keyed by call_id (Responses itemised events)
  local fc_acc = {} -- call_id -> { name, args, index }
  local active_call_id = nil -- current function_call item id for deltas that omit call_id

  local function fc_ensure(id)
    if not id or id == "" then
      return nil
    end
    local rec = fc_acc[id]
    if not rec then
      rec = { name = "", args = "", index = nil }
      fc_acc[id] = rec
    end
    return rec
  end

  local function fc_flush_one(id)
    local rec = id and fc_acc[id] or nil
    if not rec then
      return false
    end
    local call = {
      id = id,
      index = rec.index,
      type = "function",
      ["function"] = {
        name = rec.name or "",
        arguments = rec.args or "",
      },
    }
    on_chunk({ type = "tool_calls", data = { call }, complete = true })
    fc_acc[id] = nil
    if active_call_id == id then
      active_call_id = nil
    end
    return true
  end

  local function fc_flush_all()
    local out = {}
    for id, rec in pairs(fc_acc) do
      table.insert(out, {
        id = id,
        index = rec.index,
        type = "function",
        ["function"] = { name = rec.name or "", arguments = rec.args or "" },
      })
    end
    if #out > 0 then
      on_chunk({ type = "tool_calls", data = out, complete = true })
      fc_acc = {}
      active_call_id = nil
      return true
    end
    return false
  end

  -- Back-compat typed tool/function-call streams (single or batched deltas)
  local function acc_tool_calls_typed(calls)
    for _, tc in ipairs(calls or {}) do
      local f = tc["function"] or {}
      local id = tc.call_id or tc.id
      if id and id ~= "" then
        local rec = fc_ensure(id)
        if not rec then
          goto continue
        end
        if f.name and f.name ~= "" then
          rec.name = f.name
        elseif tc.name and tc.name ~= "" then
          rec.name = tc.name
        end
        local delta = f.arguments or tc.arguments or tc.arguments_delta
        if delta and delta ~= "" then
          rec.args = (rec.args or "") .. delta
        end
        if tc.index ~= nil then
          rec.index = rec.index or tc.index
        end
        active_call_id = active_call_id or id
      end
      ::continue::
    end
  end

  local function mark_complete(reason)
    if completed then
      return
    end
    completed = true
    log("api.stream: complete (%s) -> on_complete()", tostring(reason))
    if not error_reported then
      on_complete()
    end
  end

  local api_key_header = conf.api_key_header or "Authorization"
  local api_key_format = conf.api_key_format or "Bearer %s"
  local api_key_value = string.format(api_key_format, conf.api_key)
  local api_key = api_key_header .. ": " .. api_key_value

  local url = conf.url or "https://api.openai.com/v1/responses"
  url = url:gsub("/v1/chat/completions", "/v1/responses")

  log("api.stream: spawning curl | url=%s", tostring(url))
  current_job = Job:new({
    command = "curl",
    args = {
      "--silent",
      "--show-error",
      "--no-buffer",
      "--location",
      url,
      "--header",
      "Content-Type: application/json",
      "--header",
      api_key,
      "--data-binary",
      "@-",
      "--write-out",
      "\nHTTPSTATUS:%{http_code}\n",
    },
    writer = payload,
    on_stdout = function(_, line)
      for _, data_line in ipairs(vim.split(line, "\n")) do
        if data_line:sub(1, 5) == "data:" then
          local chunk = vim.trim(data_line:sub(6))
          saw_any_chunk = true
          vim.schedule(function()
            if chunk == "[DONE]" then
              -- Final chance to flush any function calls
              if not error_reported then
                fc_flush_all()
              end
              done_seen = true
              log("api.stream: SSE [DONE] -> on_complete()")
              mark_complete("SSE_DONE")
              return
            end

            local ok, decoded = pcall(vim.fn.json_decode, chunk)
            if not (ok and decoded) then
              return
            end

            if not error_reported and type(decoded) == "table" then
              local err_msg
              if type(decoded.error) == "table" then
                err_msg = decoded.error.message or decoded.error.type or vim.inspect(decoded.error)
              elseif decoded.error ~= nil then
                err_msg = tostring(decoded.error)
              elseif decoded.message and not decoded.output and not decoded.delta then
                err_msg = decoded.message
              end
              if err_msg and err_msg ~= "" then
                error_reported = true
                local verbose = "API error (SSE): "
                  .. tostring(err_msg)
                  .. "\nFull SSE payload (decoded):\n"
                  .. vim.inspect(decoded)
                  .. "\nFull SSE chunk (raw):\n"
                  .. chunk
                log("api.stream: on_error | %s", tostring(err_msg))
                vim.notify(verbose, vim.log.levels.ERROR, { title = "NeoAI" })
                on_error(verbose)
                return
              end
            end

            if decoded.type and type(decoded.type) == "string" then
              local t = decoded.type
              log("api.stream: sse.type=%s", tostring(t))

              -- Reasoning deltas
              if (t == "response.reasoning_text.delta" or t == "response.reasoning.delta") and decoded.delta then
                on_chunk({ type = "reasoning", data = decoded.delta })
              end

              -- Reasoning summary deltas
              if
                t == "response.reasoning_summary.delta"
                or t == "response.reasoning.summary.delta"
                or t == "response.reasoning_summary_text.delta"
              then
                local summary = decoded.delta or decoded.text
                if summary and summary ~= "" then
                  on_chunk({ type = "reasoning_summary", data = summary })
                end
              end

              -- Content deltas
              if
                t == "response.output_text.delta"
                or t == "response.text.delta"
                or t == "response.delta"
                or t == "message.delta"
                or t == "response.output.delta"
              then
                local text = decoded.delta or decoded.text
                if text and text ~= "" then
                  on_chunk({ type = "content", data = text })
                end
              elseif t == "response.output_text.done" or t == "response.text.done" then
                local text = decoded.text
                if text and text ~= "" then
                  on_chunk({ type = "content", data = text })
                end
              end

              -- New Responses item: function_call item begins
              if t == "response.output_item.added" and decoded.item then
                local it = decoded.item
                if it.type == "function_call" then
                  local cid = it.call_id or it.id or it.output_item_id
                  local fname = it.name or (it["function"] and it["function"].name)
                  local idx = it.index
                  if cid and cid ~= "" then
                    local rec = fc_ensure(cid)
                    if rec then
                      if fname and fname ~= "" then
                        rec.name = fname
                      end
                      rec.index = rec.index or idx
                      active_call_id = cid
                    end
                  end
                end
              end

              -- New Responses item: function_call arguments deltas
              if t == "response.function_call_arguments.delta" then
                local cid = decoded.call_id or decoded.id or decoded.output_item_id or active_call_id
                local idx = decoded.index
                local d = ""
                if type(decoded.delta) == "string" then
                  d = decoded.delta
                elseif type(decoded.delta) == "table" then
                  d = decoded.delta.arguments or decoded.delta.text or ""
                elseif type(decoded.arguments) == "string" then
                  d = decoded.arguments
                elseif type(decoded.text) == "string" then
                  d = decoded.text
                end
                if cid and cid ~= "" and d ~= "" then
                  local rec = fc_ensure(cid)
                  if rec then
                    rec.args = (rec.args or "") .. d
                    if idx ~= nil then
                      rec.index = rec.index or idx
                    end
                    active_call_id = cid
                  end
                end
              elseif t == "response.function_call_arguments.done" then
                -- Prefer to flush the active call, fall back to flushing all if unknown
                local flushed = false
                if active_call_id then
                  flushed = fc_flush_one(active_call_id)
                end
                if not flushed then
                  fc_flush_all()
                end
              end

              -- Back-compat typed function/tool call events
              if
                t == "response.function_call.delta"
                or t == "message.function_call.delta"
                or t == "response.function_calls.delta"
                or t == "response.tool_call.delta"
                or t == "message.tool_call.delta"
                or t == "response.tool_calls.delta"
              then
                local calls = nil
                if decoded.delta and decoded.delta.tool_calls then
                  calls = decoded.delta.tool_calls
                end
                if
                  not calls
                  and decoded.delta
                  and (decoded.delta.name or decoded.delta.arguments or decoded.delta.call_id)
                then
                  local d = decoded.delta
                  calls = {
                    {
                      call_id = d.call_id,
                      id = d.id,
                      index = d.index,
                      ["function"] = {
                        name = d.name or (d["function"] and d["function"].name),
                        arguments = d.arguments or (d["function"] and d["function"].arguments) or d.arguments_delta,
                      },
                    },
                  }
                end
                if not calls and decoded.tool_calls then
                  calls = decoded.tool_calls
                end
                if calls then
                  acc_tool_calls_typed(calls)
                end
              end

              -- Item completion for function_call
              if t == "response.output_item.done" and decoded.item then
                local it = decoded.item
                if it.type == "function_call" then
                  -- Try to flush the specific id if present on the item, else flush active/all
                  local cid = it.call_id or it.id or it.output_item_id or active_call_id
                  if not (cid and fc_flush_one(cid)) then
                    fc_flush_all()
                  end
                end
              end

              -- Final completion
              if t == "response.completed" or t == "response.done" then
                fc_flush_all()
                log("api.stream: response.completed -> on_complete()")
                mark_complete("typed_completed")
              end
            end
          end)
        else
          local trimmed = vim.trim(data_line)
          local st = trimmed:match("^HTTPSTATUS:(%d+)$")
          if st then
            http_status = tonumber(st)
          else
            if trimmed ~= "" then
              table.insert(non_sse_buf, trimmed)
              table.insert(raw_body_chunks, trimmed)
            end
            if not error_reported then
              local aggregated = table.concat(non_sse_buf, "\n")
              local agg_trim = vim.trim(aggregated)
              local first = agg_trim:sub(1, 1)
              if first == "{" or first == "[" then
                local ok, decoded = pcall(vim.fn.json_decode, agg_trim)
                if ok and decoded then
                  local err_msg
                  if type(decoded.error) == "table" then
                    err_msg = decoded.error.message or decoded.error.type or vim.inspect(decoded.error)
                  elseif decoded.error ~= nil then
                    err_msg = tostring(decoded.error)
                  elseif type(decoded) == "table" and decoded.message and not decoded.output then
                    err_msg = decoded.message
                  end
                  if err_msg and err_msg ~= "" then
                    error_reported = true
                    vim.schedule(function()
                      local prefix = http_status and ("HTTP " .. tostring(http_status) .. ": ") or ""
                      local verbose = prefix
                        .. "API error: "
                        .. tostring(err_msg)
                        .. "\nFull response body (decoded):\n"
                        .. vim.inspect(decoded)
                        .. "\nFull response body (raw):\n"
                        .. agg_trim
                      log("api.stream: on_error | %s", tostring(err_msg))
                      vim.notify(verbose, vim.log.levels.ERROR, { title = "NeoAI" })
                      on_error(verbose)
                    end)
                  end
                end
              end
            end
          end
        end
      end
    end,
    on_stderr = function(_, line)
      if not line or line == "" then
        return
      end
      if not error_reported then
        error_reported = true
        vim.schedule(function()
          local verbose = "curl error: " .. tostring(line)
          log("api.stream: on_error | %s", verbose)
          vim.notify(verbose, vim.log.levels.ERROR, { title = "NeoAI" })
          on_error(verbose)
        end)
      end
    end,
    on_exit = function(j, exit_code)
      vim.schedule(function()
        log(
          "api.stream: on_exit | exit_code=%s saw_any_chunk=%s http_status=%s done_seen=%s completed=%s",
          tostring(exit_code),
          tostring(saw_any_chunk),
          tostring(http_status),
          tostring(done_seen),
          tostring(completed)
        )
        if current_job == j then
          current_job = nil

          if j._neoai_cancelled then
            if on_cancel then
              on_cancel()
            end
          else
            if exit_code ~= 0 then
              local verbose = "curl exited with code: " .. tostring(exit_code)
              log("api.stream: on_error | %s", verbose)
              vim.notify(verbose, vim.log.levels.ERROR, { title = "NeoAI" })
              on_error(verbose)
            else
              if not error_reported and http_status and http_status >= 400 then
                local raw_body = table.concat(raw_body_chunks, "\n")
                local verbose = "HTTP " .. tostring(http_status) .. " error"
                if raw_body ~= "" then
                  verbose = verbose .. "\nRaw body (unparsed):\n" .. raw_body
                end
                log("api.stream: on_error | %s", verbose)
                vim.notify(verbose, vim.log.levels.ERROR, { title = "NeoAI" })
                on_error(verbose)
              end
            end
          end

          -- Fallback: flush any pending calls if we received chunks but did not complete properly
          if not j._neoai_cancelled and not error_reported and saw_any_chunk and not completed then
            local flushed = fc_flush_all()
            if flushed then
              log("api.stream: on_exit fallback -> flushed pending function calls")
            end
            mark_complete("on_exit_without_DONE")
          end

          -- Start queued request if any
          if queued_stream then
            local q = queued_stream
            queued_stream = nil
            log("api.stream: starting queued stream request")
            vim.schedule(function()
              api.stream(q.messages, q.on_chunk, q.on_complete, q.on_error, q.on_cancel)
            end)
            return
          end
        end
      end)
    end,
  })

  current_job._neoai_cancelled = false
  current_job:start()
end

--- Cancel current streaming request (if any)
function api.cancel()
  local job = current_job
  if not job then
    return
  end

  job._neoai_cancelled = true

  if type(job.kill) == "function" then
    pcall(function()
      job:kill(15)
    end)
  end

  if type(job.shutdown) == "function" then
    pcall(function()
      job:shutdown()
    end)
  end

  vim.defer_fn(function()
    if current_job == job and type(job.kill) == "function" then
      pcall(function()
        job:kill(9)
      end)
    end
  end, 150)
end

return api
