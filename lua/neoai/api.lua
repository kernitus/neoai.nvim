local Job = require("plenary.job")
local conf = require("neoai.config").get_api("main")
local tool_schemas = require("neoai.ai_tools").tool_schemas
local log = require("neoai.debug").log

local api = {}

-- Track current streaming job
--- @type Job|nil  -- Current streaming job
local current_job = nil

-- Single queued stream request (if a new request arrives whilst one is active)
local queued_stream = nil

--- Merges two tables into a new one.
--- @param t1 table  -- The first table
--- @param t2 table  -- The second table
--- @return table  -- The merged table
local function merge_tables(t1, t2)
  local result = {}
  for k, v in pairs(t1) do
    result[k] = v
  end
  for k, v in pairs(t2) do
    result[k] = v
  end
  return result
end

--- Start streaming completion
--- @param messages table
--- @param on_chunk fun(chunk: table)
--- @param on_complete fun()
--- @param on_error fun(err: integer|string)
--- @param on_cancel fun()|nil
function api.stream(messages, on_chunk, on_complete, on_error, on_cancel)
  log(
    "api.stream: start | messages=%d tools=%d model=%s",
    #(messages or {}),
    #(tool_schemas or {}),
    tostring(conf.model)
  )

  -- If a stream is already active, queue this request and start it when the current job exits.
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

  -- Track if we've already reported an error to avoid duplicate notifications
  local error_reported = false
  -- Buffer non-SSE stdout to recover JSON error bodies when the server does not stream
  local non_sse_buf = {}
  local http_status -- captured from curl --write-out
  local saw_any_chunk = false

  -- Track stream completion and sentinel
  local completed = false
  local done_seen = false

  local basic_payload = {
    model = conf.model,
    max_completion_tokens = conf.max_completion_tokens,
    stream = true,
    messages = messages,
    tools = tool_schemas,
  }

  local payload = vim.fn.json_encode(merge_tables(basic_payload, conf.additional_kwargs or {}))

  if conf.debug_payload then
    vim.notify("NeoAI: Sending JSON payload to curl (stream):\n" .. payload, vim.log.levels.DEBUG, { title = "NeoAI" })
  end

  local raw_body_chunks = {}

  -- Accumulate streamed tool_call arguments across deltas and flush on finish
  local tool_call_acc = {} -- key (id or idx_*) -> schema
  local tool_call_order = {} -- stable first-seen order
  local index_to_key = {} -- index -> current authoritative key (for re-routing after merge)

  local function acc_tool_calls(calls)
    for _, tc in ipairs(calls or {}) do
      local f = tc["function"] or {}
      local real_id = tc.id
      local idx = tc.index

      -- Determine the authoritative key for this index
      local key
      if idx ~= nil and index_to_key[idx] then
        -- We already have a key for this index (either idx_* or real_id from a previous delta)
        key = index_to_key[idx]
      elseif real_id and real_id ~= "" then
        -- First time seeing this index with a real id
        key = real_id
        if idx ~= nil then
          index_to_key[idx] = real_id
        end
      else
        -- First time seeing this index, no real id yet
        key = "idx_" .. tostring(idx or (#tool_call_order + 1))
        if idx ~= nil then
          index_to_key[idx] = key
        end
      end

      -- If we just learned the real_id for an index that was previously idx_*, migrate the entry
      if real_id and real_id ~= "" and idx ~= nil then
        local old_key = "idx_" .. tostring(idx)
        if old_key ~= key and tool_call_acc[old_key] then
          -- Migrate idx_* entry to real_id
          local stub = tool_call_acc[old_key]
          tool_call_acc[old_key] = nil

          if not tool_call_acc[key] then
            tool_call_acc[key] = {
              id = real_id,
              index = stub.index or idx,
              type = "function",
              ["function"] = {
                name = (f.name and f.name ~= "" and f.name) or (stub["function"] and stub["function"].name) or "",
                arguments = (stub["function"] and stub["function"].arguments) or "",
              },
            }
          else
            -- Merge arguments if both exist
            local early = (stub["function"] and stub["function"].arguments) or ""
            local existing = (tool_call_acc[key]["function"] and tool_call_acc[key]["function"].arguments) or ""
            tool_call_acc[key]["function"].arguments = early .. existing
            if (tool_call_acc[key]["function"].name or "") == "" then
              tool_call_acc[key]["function"].name = (f.name and f.name ~= "" and f.name)
                or (stub["function"] and stub["function"].name)
                or ""
            end
          end

          -- Update order list
          for i, k in ipairs(tool_call_order) do
            if k == old_key then
              tool_call_order[i] = key
              break
            end
          end

          -- Update mapping
          index_to_key[idx] = key
        end
      end

      -- Ensure entry exists
      if not tool_call_acc[key] then
        tool_call_acc[key] = {
          id = real_id or key,
          index = idx,
          type = "function",
          ["function"] = { name = f.name or "", arguments = "" },
        }
        table.insert(tool_call_order, key)
      end

      -- Update name (prefer non-empty)
      if f.name and f.name ~= "" then
        tool_call_acc[key]["function"].name = f.name
      end

      -- Append streamed arguments
      if f.arguments and f.arguments ~= "" then
        local prev = tool_call_acc[key]["function"].arguments or ""
        tool_call_acc[key]["function"].arguments = prev .. f.arguments

        -- Log accumulation for large tool calls
        local total = #tool_call_acc[key]["function"].arguments
        if total > 30000 then
          log(
            "acc_tool_calls: id=%s name=%s total_bytes=%d delta_bytes=%d",
            tostring(key),
            tostring(tool_call_acc[key]["function"].name),
            total,
            #f.arguments
          )
        end
      end
    end
  end

  local function flush_tool_calls()
    if #tool_call_order == 0 then
      return {}
    end

    -- Log final sizes before flushing
    for _, id in ipairs(tool_call_order) do
      local tc = tool_call_acc[id]
      local args_len = tc and tc["function"] and #(tc["function"].arguments or "") or 0
      if args_len > 0 then
        log(
          "flush_tool_calls: id=%s name=%s final_args_bytes=%d",
          tostring(id),
          tostring(tc and tc["function"] and tc["function"].name),
          args_len
        )
      end
    end

    table.sort(tool_call_order, function(a, b)
      local ia = tool_call_acc[a] and tool_call_acc[a].index or math.huge
      local ib = tool_call_acc[b] and tool_call_acc[b].index or math.huge
      if ia == ib then
        return tostring(a) < tostring(b)
      end
      return ia < ib
    end)
    local out = {}
    for _, id in ipairs(tool_call_order) do
      table.insert(out, tool_call_acc[id])
    end
    tool_call_acc = {}
    tool_call_order = {}
    index_to_key = {} -- Clear mapping
    return out
  end

  local function flush_pending_tool_calls()
    if next(tool_call_acc) ~= nil then
      local assembled = flush_tool_calls()
      if #assembled > 0 then
        on_chunk({ type = "tool_calls", data = assembled, complete = true })
        return true
      end
    end
    return false
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

  log("api.stream: spawning curl | url=%s", tostring(conf.url))
  current_job = Job:new({
    command = "curl",
    args = {
      "--silent",
      "--show-error",
      "--no-buffer",
      "--location",
      conf.url,
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
        -- Accept "data:" with or without a trailing space
        if data_line:sub(1, 5) == "data:" then
          local chunk = vim.trim(data_line:sub(6))
          saw_any_chunk = true
          vim.schedule(function()
            if chunk == "[DONE]" then
              done_seen = true
              -- Flush any final tool_calls before completing
              if not error_reported then
                flush_pending_tool_calls()
              end
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
              elseif decoded.message and not decoded.choices and not decoded.delta then
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

            local handled = false

            if decoded.type and type(decoded.type) == "string" then
              log("api.stream: sse.type=%s", tostring(decoded.type))
              local t = decoded.type
              if (t == "response.reasoning_text.delta" or t == "response.reasoning.delta") and decoded.delta then
                on_chunk({ type = "reasoning", data = decoded.delta })
                handled = true
              elseif t == "response.reasoning_text.done" or t == "response.reasoning.done" then
                handled = true
              end

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
                handled = true
              elseif t == "response.output_text.done" or t == "response.text.done" then
                local text = decoded.text
                if text and text ~= "" then
                  on_chunk({ type = "content", data = text })
                end
                handled = true
              end

              -- Optional: typed tool_call streaming support
              if
                t == "response.tool_call.delta"
                or t == "message.tool_call.delta"
                or t == "response.tool_calls.delta"
              then
                local calls = decoded.delta and decoded.delta.tool_calls
                if
                  not calls
                  and decoded.delta
                  and (decoded.delta["function"] or decoded.delta.id or decoded.delta.index)
                then
                  calls = { decoded.delta }
                end
                if not calls and decoded.tool_calls then
                  calls = decoded.tool_calls
                end
                if calls then
                  acc_tool_calls(calls)
                end
                handled = true
              elseif t == "response.tool_call.completed" or t == "message.tool_call.completed" then
                local flushed = flush_pending_tool_calls()
                if flushed then
                  log("api.stream: typed tool_call.completed -> flushed")
                end
                handled = true
              elseif t == "response.completed" or t == "response.done" then
                -- Defensive: flush any pending tool_calls before completing
                if not error_reported then
                  flush_pending_tool_calls()
                end
                log("api.stream: response.completed -> on_complete()")
                mark_complete("typed_completed")
                handled = true
              end
            end

            if not handled then
              local choice = decoded.choices and decoded.choices[1]
              if choice then
                local delta = choice.delta or {}
                local content = delta and delta.content
                local tool_calls = delta and delta.tool_calls
                local reasons = delta and delta.reasoning

                if reasons and reasons ~= vim.NIL and reasons ~= "" then
                  on_chunk({ type = "reasoning", data = reasons })
                end
                if content and content ~= vim.NIL and content ~= "" then
                  on_chunk({ type = "content", data = content })
                end
                if tool_calls then
                  acc_tool_calls(tool_calls)
                end

                local finished_reason = choice.finish_reason
                if finished_reason == "stop" then
                  log("api.stream: on_complete() via finish_reason=stop")
                  mark_complete("finish_reason_stop")
                elseif finished_reason == "tool_calls" then
                  -- Flush accumulated tool_calls immediately so the runner can start assembling UI state now.
                  local flushed = flush_pending_tool_calls()
                  log(
                    "api.stream: finish_reason=tool_calls | flushed=%s; waiting for [DONE] (with exit fallback)",
                    tostring(flushed)
                  )
                  -- Do not mark complete here; either [DONE] will arrive, or on_exit will finalise.
                end
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
                  elseif type(decoded) == "table" and decoded.message and not decoded.choices then
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

          -- Handle curl process exit statuses and HTTP errors first
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

          -- Fallback: if stream ended without [DONE]/typed completed but we did receive chunks,
          -- flush pending tool_calls and complete once.
          if not j._neoai_cancelled and not error_reported and saw_any_chunk and not completed then
            local flushed = flush_pending_tool_calls()
            if flushed then
              log("api.stream: on_exit fallback -> flushed pending tool_calls")
            end
            -- Even if nothing to flush, mark complete so the UI/runner can progress.
            mark_complete("on_exit_without_DONE")
          end

          -- If a next stream was queued whilst this one was active, start it now.
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
