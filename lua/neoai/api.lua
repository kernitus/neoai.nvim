local conf = require("neoai.config").get_api("main")
local chat_tool_schemas = require("neoai.ai_tools").tool_schemas
local log = require("neoai.debug").log

local api = {}

-- --- Daemon Client ---

local DaemonClient = {}
DaemonClient.__index = DaemonClient

-- Singleton instance
local client_instance = nil

function DaemonClient:new()
  local obj = setmetatable({
    job_id = nil,
    callbacks = {}, -- map of request_id -> {on_chunk, on_complete, on_error} (but we use global notifications mostly)
  }, self)
  return obj
end

function DaemonClient:get_jar_path()
  local info = debug.getinfo(1, "S")
  local source = info.source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local dir = vim.fn.fnamemodify(source, ":h") -- .../lua/neoai
  local root = vim.fn.fnamemodify(dir, ":h:h") -- plugin root
  local jar = root .. "/build/libs/neoai-daemon-all.jar"
  if vim.fn.filereadable(jar) == 1 then
    return jar
  end
  return nil
end

function DaemonClient:start()
  if self.job_id then
    return true
  end

  local jar = self:get_jar_path()
  if not jar then
    vim.notify("NeoAI: Daemon jar not found at " .. tostring(jar), vim.log.levels.ERROR)
    return false
  end

  log("DaemonClient: starting java -jar %s", jar)
  
  self.job_id = vim.fn.jobstart({ "java", "-jar", jar }, {
    rpc = true,
    on_exit = function(_, code, _)
      log("DaemonClient: exited with code %s", tostring(code))
      self.job_id = nil
      -- If we had active requests, we should probably fail them.
      -- But since we rely on global callbacks, we might just let them hang or handle cleanup elsewhere.
    end,
  })

  if self.job_id == 0 or self.job_id == -1 then
    vim.notify("NeoAI: Failed to start daemon", vim.log.levels.ERROR)
    self.job_id = nil
    return false
  end

  return true
end

function DaemonClient:stop()
  if self.job_id then
    vim.fn.jobstop(self.job_id)
    self.job_id = nil
  end
end

function DaemonClient:notify(method, params)
  if not self:start() then
    return false
  end
  local ok, err = pcall(vim.rpcnotify, self.job_id, method, params)
  if not ok then
    log("DaemonClient: rpcnotify failed: %s", tostring(err))
    return false
  end
  return true
end

-- Global accessor
function api.get_client()
  if not client_instance then
    client_instance = DaemonClient:new()
  end
  return client_instance
end

-- --- Payload Helpers ---

local function merge_tables(t1, t2)
  local result = {}
  for k, v in pairs(t1 or {}) do result[k] = v end
  for k, v in pairs(t2 or {}) do result[k] = v end
  return result
end

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

local function merge_native_tools(base, native)
  if type(native) == "table" then
    for _, t in ipairs(native) do table.insert(base, t) end
  end
  return base
end

local function is_reasoning_model(name)
  local n = tostring(name or ""):lower()
  return n:match("^gpt%-5") or n:match("^o%d") or n:match("^o%-")
end

local function chat_messages_to_items(messages)
  local items = {}
  local instructions_parts = {}

  local function add_instructions(s)
    if s and s ~= "" then table.insert(instructions_parts, s) end
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
      if content ~= "" then
        table.insert(items, {
          type = "message",
          role = "assistant",
          content = { { type = "output_text", text = content } },
        })
      end
    end
  end

  local instructions = table.concat(instructions_parts, "\n\n")
  return items, instructions
end

local function build_payload(messages)
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

  return payload_tbl
end

-- --- API Methods ---

-- Track active callbacks for the current stream
local current_callbacks = nil

--- Start streaming via the persistent daemon.
---@param messages table
---@param on_chunk fun(chunk: table)
---@param on_complete fun()
---@param on_error fun(err: integer|string)
---@param on_cancel fun()|nil
function api.stream(messages, on_chunk, on_complete, on_error, on_cancel)
  log("api.stream: start | messages=%d model=%s", #(messages or {}), tostring(conf.model))

  if current_callbacks then
    log("api.stream: busy; cancelling previous")
    api.cancel()
  end

  current_callbacks = {
    on_chunk = on_chunk,
    on_complete = on_complete,
    on_error = on_error,
    on_cancel = on_cancel,
  }

  local payload_tbl = build_payload(messages)
  local envelope = {
    url = conf.url,
    api_key = conf.api_key,
    api_key_header = conf.api_key_header or "Authorization",
    api_key_format = conf.api_key_format or "Bearer %s",
    model = conf.model,
    body = payload_tbl,
  }

  local client = api.get_client()
  -- Send notification: "generate" with [envelope]
  -- Note: rpcnotify params must be a list/array.
  if not client:notify("generate", envelope) then
    if on_error then on_error("Failed to send request to daemon") end
    current_callbacks = nil
  end
end

function api.cancel()
  if current_callbacks then
    if current_callbacks.on_cancel then
      current_callbacks.on_cancel()
    end
    current_callbacks = nil
  end
  -- Optionally notify daemon to cancel? 
  -- client:notify("cancel", {})
end

-- Global callback invoked by the daemon
-- The daemon sends: nvim_call_function("NeoAI_OnChunk", [ {type="...", data="..."} ])
function _G.NeoAI_OnChunk(chunk)
  -- chunk is a table: { type="...", data="..." }
  log("NeoAI_OnChunk: %s", vim.inspect(chunk))
  
  if not current_callbacks then
    return
  end

  local t = chunk.type
  local d = chunk.data

  if t == "content" or t == "reasoning" then
    if current_callbacks.on_chunk then
      -- Schedule to ensure main thread safety if needed (rpc calls are usually safe but...)
      vim.schedule(function()
        if current_callbacks then
            current_callbacks.on_chunk({ type = t, data = d })
        end
      end)
    end
  elseif t == "complete" then
    if current_callbacks.on_complete then
      vim.schedule(function()
        if current_callbacks then
            current_callbacks.on_complete()
            current_callbacks = nil
        end
      end)
    end
  elseif t == "error" then
    if current_callbacks.on_error then
      vim.schedule(function()
        if current_callbacks then
            current_callbacks.on_error(d)
            current_callbacks = nil
        end
      end)
    end
  end
end

return api
