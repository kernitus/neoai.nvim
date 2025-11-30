local M = {}
local M = {}

local storage = nil --[[@type table?]]

local function lazy_init()
  if storage then
    return storage
  end
  storage = require("neoai.storage_json")
  return storage
end

---Initialise the storage module with a given configuration.
---@param config table: The configuration table.
---@return any
function M.init(config)
  local backend = lazy_init()
  return backend.init(config)
end

local function proxy(method, ...)
  local backend = lazy_init()
  if not backend or type(backend[method]) ~= "function" then
    error("NeoAI: Storage backend does not implement " .. method)
  end
  return backend[method](...)
end

function M.create_session(...)
  return proxy("create_session", ...)
end

function M.get_active_session(...)
  return proxy("get_active_session", ...)
end

function M.switch_session(...)
  return proxy("switch_session", ...)
end

function M.get_all_sessions(...)
  return proxy("get_all_sessions", ...)
end

function M.delete_session(...)
  return proxy("delete_session", ...)
end

function M.update_session_title(...)
  return proxy("update_session_title", ...)
end

function M.add_message(...)
  return proxy("add_message", ...)
end

function M.get_session_messages(...)
  return proxy("get_session_messages", ...)
end

function M.clear_session_messages(...)
  return proxy("clear_session_messages", ...)
end

function M.get_stats(...)
  return proxy("get_stats", ...)
end

function M.close(...)
  if storage and storage.close then
    return storage.close(...)
  end
end

function M.get_backend()
  return "json"
end

return M
