local M = {}

local function abspath(p)
  if not p or p == "" then
    return nil
  end
  local cwd = vim.loop.cwd() or vim.fn.getcwd()
  local abs = p
  if not abs:match("^/") and not abs:match("^%a:[/\\]") then
    abs = cwd .. "/" .. abs
  end
  abs = vim.fn.fnamemodify(abs, ":p")
  return abs
end

local store = {}

function M.set(path, text)
  local ap = abspath(path)
  if not ap or type(text) ~= "string" then
    return
  end
  store[ap] = text
end

function M.get(path)
  local ap = abspath(path)
  if not ap then
    return nil
  end
  return store[ap]
end

function M.clear(path)
  if not path or path == "" then
    store = {}
    return
  end
  local ap = abspath(path)
  if ap then
    store[ap] = nil
  end
end

function M.clear_all()
  store = {}
end

function M.has(path)
  return M.get(path) ~= nil
end

return M
