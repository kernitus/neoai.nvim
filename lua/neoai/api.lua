local Job = require("plenary.job")
local conf = require("neoai.config").get_api("main")
local tool_schemas = require("neoai.ai_tools").tool_schemas
local log = require("neoai.debug").log

local api = {}

-- Track current streaming job
--- @type Job|nil  -- Current streaming job
local current_job = nil

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
  -- Track if we've already reported an error to avoid duplicate notifications
  local error_reported = false
  -- Buffer non-SSE stdout to recover JSON error bodies when the server doesn't stream
  local non_sse_buf = {}
  local http_status -- captured from curl --write-out
  local saw_any_chunk = false

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
        if vim.startswith(data_line, "data: ") then
          local chunk = data_line:sub(7)
          saw_any_chunk = true
          vim.schedule(function()
            if chunk == "[DONE]" then
              log("api.stream: SSE [DONE] -> on_complete()")
              if not error_reported then
                on_complete()
              end
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
              elseif t == "response.completed" or t == "response.done" then
                log("api.stream: response.completed -> on_complete()")
                on_complete()
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
                  local ids = {}
                  for _, tc in ipairs(tool_calls) do
                    table.insert(ids, tostring(tc.id or ("<nil>#" .. tostring(tc.index))))
                  end
                  log("api.stream: emit tool_calls | n=%d ids=%s", #tool_calls, table.concat(ids, ","))
                  on_chunk({ type = "tool_calls", data = tool_calls })
                end

                local finished_reason = choice.finish_reason
                if finished_reason == "stop" or finished_reason == "tool_calls" then
                  log("api.stream: on_complete() via finish_reason=%s", tostring(finished_reason))
                  on_complete()
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
          "api.stream: on_exit | exit_code=%s saw_any_chunk=%s http_status=%s",
          tostring(exit_code),
          tostring(saw_any_chunk),
          tostring(http_status)
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
