local M = {}

local dir = vim.fn.stdpath("data") .. "/neoai_logs"
pcall(vim.fn.mkdir, dir, "p")
local logfile = dir .. "/neoai.log"

local function safe_fmt(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if ok then
    return msg
  end
  return tostring(fmt)
end

function M.log(fmt, ...)
  local line = string.format("[%s] %s", os.date("%Y-%m-%d %H:%M:%S"), safe_fmt(fmt, ...))
  local ok, f = pcall(io.open, logfile, "a")
  if ok and f then
    f:write(line .. "\n")
    f:close()
  else
    vim.schedule(function()
      vim.notify("NeoAI log fallback: " .. line, vim.log.levels.DEBUG, { title = "NeoAI" })
    end)
  end
end

function M.path()
  return logfile
end

return M
