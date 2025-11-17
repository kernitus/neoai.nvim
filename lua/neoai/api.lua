local Job = require("plenary.job")
local conf = require("neoai.config").get_api("main")
local chat_tool_schemas = require("neoai.ai_tools").tool_schemas
local log = require("neoai.debug").log

local api = {}

-- Track current streaming job
---@type Job|nil
local current_job = nil

-- Single queued stream request (if a new request arrives whilst one is active)
local queued_stream = nil

--- Merges two tables into a new one (shallow).
---@param t1 table
---@param t2 table
---@return table
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
---@param tools table
---@return table
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
---@param base table
---@param native any
---@return table
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

-- Build the Responses API payload (without API key / URL – those go into an envelope)
local function build_payload(messages)
  log("api.stream: build_payload | messages=%d model=%s", #(messages or {}), tostring(conf.model))

  local tools = to_responses_tools(chat_tool_schemas)
  tools = merge_native_tools(tools, conf.native_tools)

  local items, instructions = chat_messages_to_items(messages)

  local basic_payload = {
    model = conf.model,
    input = items,
    stream = true, -- we will stream on the Kotlin side
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

  return payload_tbl
end

-- Locate the plugin root and the shaded jar
local function get_plugin_root()
  local info = debug.getinfo(1, "S")
  local source = info.source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  -- api.lua is at <root>/lua/neoai/api.lua
  local dir = vim.fn.fnamemodify(source, ":h") -- .../lua/neoai
  local root = vim.fn.fnamemodify(dir, ":h:h") -- plugin root
  return root
end

local function get_daemon_jar()
  local root = get_plugin_root()
  local jar = root .. "/build/libs/neoai-daemon-all.jar"
  if vim.fn.filereadable(jar) == 1 then
    return jar
  end
  vim.notify("NeoAI: daemon jar not found at " .. jar, vim.log.levels.ERROR)
  return nil
end

-- Robust JSON decode (vim.json or vim.fn.json_decode)
local function decode_json(s)
  if vim.json and type(vim.json.decode) == "function" then
    local ok, res = pcall(vim.json.decode, s)
    if ok then
      return true, res
    else
      log("api.stream: vim.json.decode error=%s for=%s", tostring(res), s)
    end
  end
  local ok, res = pcall(vim.fn.json_decode, s)
  if not ok then
    log("api.stream: vim.fn.json_decode error=%s for=%s", tostring(res), s)
  end
  return ok, res
end

--- Start streaming via the Kotlin jar.
--- We keep the same signature as the original: messages + 4 callbacks.
---@param messages table
---@param on_chunk fun(chunk: table)
---@param on_complete fun()
---@param on_error fun(err: integer|string)
---@param on_cancel fun()|nil
function api.stream(messages, on_chunk, on_complete, on_error, on_cancel)
  log("api.stream: start (daemon bridge) | messages=%d model=%s", #(messages or {}), tostring(conf.model))

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

  local payload_tbl = build_payload(messages)

  -- Envelope sent to the Kotlin process: includes URL, key, and the payload
  local envelope = {
    url = conf.url,
    api_key = conf.api_key,
    api_key_header = conf.api_key_header or "Authorization",
    api_key_format = conf.api_key_format or "Bearer %s",
    model = conf.model,
    body = payload_tbl,
  }

  local json = vim.fn.json_encode(envelope)

  local jar_path = get_daemon_jar()
  if not jar_path then
    if on_error then
      on_error("NeoAI daemon jar not found")
    end
    return
  end

  -- Wrap callbacks so they always run on the main thread (avoid fast-event API errors)
  local schedule_chunk = vim.schedule_wrap(function(ev)
    if on_chunk then
      on_chunk(ev)
    end
  end)
  local schedule_complete = vim.schedule_wrap(function()
    if on_complete then
      on_complete()
    end
  end)
  local schedule_error = vim.schedule_wrap(function(msg)
    if on_error then
      on_error(msg)
    end
  end)
  local schedule_cancel = on_cancel and vim.schedule_wrap(on_cancel) or nil

  current_job = Job:new({
    command = "java",
    args = { "-jar", jar_path },
    writer = json,
    on_stdout = function(_, data)
      if type(data) == "table" then
        data = table.concat(data, "\n")
      end
      log("api.stream: stdout raw=%s", vim.inspect(data))
      for _, line in ipairs(vim.split(data or "", "\n")) do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
          log("api.stream: stdout line=%s", trimmed)
          local ok, decoded = decode_json(trimmed)
          if not ok or type(decoded) ~= "table" then
            log("api.stream: json_decode failed | %s", tostring(trimmed))
          else
            log("api.stream: decoded=%s", vim.inspect(decoded))
            if decoded.kind == "chunk" then
              local t = decoded.type or "content"
              local d = decoded.data or ""
              -- Directly map to what chat.stream_ai_response expects
              schedule_chunk({ type = t, data = d })
            elseif decoded.kind == "complete" then
              log("api.stream: complete event received")
              schedule_complete()
            elseif decoded.kind == "error" then
              local msg = decoded.message or "Unknown error from daemon"
              log("api.stream: error event | %s", msg)
              schedule_error(msg)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if type(data) == "table" then
        data = table.concat(data, "\n")
      end
      local line = vim.trim(data or "")
      if line == "" then
        return
      end

      -- Ignore SLF4J warnings (they are harmless and very noisy)
      if line:match("^SLF4J%(") then
        log("api.stream: ignoring SLF4J stderr: %s", line)
        return
      end

      -- For now, just log other stderr lines; do not show popups.
      log("api.stream: stderr=%s", line)
      -- If you *do* want to see non-SLF4J errors, uncomment:
      -- vim.schedule(function()
      --   vim.notify("NeoAI daemon stderr: " .. line, vim.log.levels.ERROR, { title = "NeoAI" })
      -- end)
    end,
    on_exit = function(_, exit_code)
      log("api.stream: on_exit | code=%s", tostring(exit_code))
      local job = current_job
      current_job = nil

      if job and job._neoai_cancelled then
        if schedule_cancel then
          schedule_cancel()
        end
      else
        if exit_code ~= 0 then
          local msg = "NeoAI daemon exited with code " .. tostring(exit_code)
          log("api.stream: error | %s", msg)
          schedule_error(msg)
        else
          -- Normal exit; if the daemon forgot to send a complete event, force it.
          log("api.stream: normal exit, forcing on_complete()")
          schedule_complete()
        end
      end

      -- Start queued request if any
      if queued_stream then
        local q = queued_stream
        queued_stream = nil
        log("api.stream: starting queued stream request (daemon)")
        vim.schedule(function()
          api.stream(q.messages, q.on_chunk, q.on_complete, q.on_error, q.on_cancel)
        end)
      end
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

  log("api.cancel: cancelling current job")
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
