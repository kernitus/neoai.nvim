local M = {}

local function log_path()
  return vim.fn.stdpath("cache") .. "/neoai.log"
end

function M.clear()
  pcall(os.remove, log_path())
end

function M.log(fmt, ...)
  if not vim.g.neoai_debug then
    return
  end
  local ok, line = pcall(string.format, fmt, ...)
  local msg = (ok and line) or fmt
  local f = io.open(log_path(), "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
  end
end

return M
