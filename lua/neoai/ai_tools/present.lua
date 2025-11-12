local M = {}
local edit = require("neoai.ai_tools.edit")

M.meta = {
  name = "PresentEdits",
  description = "Present pending deferred edits in the inline diff UI. Call this when you are ready for user review. If 'paths' is an empty list, all pending edits will be presented.",
  parameters = {
    type = "object",
    properties = {
      paths = {
        type = "array",
        description = "List of file paths to present. Use an empty list to present all pending edits.",
        default = {}, -- strict mode: provide a sensible default
        items = { type = "string" },
      },
    },
    required = { "paths" }, -- strict mode: all parameters required
    additionalProperties = false,
  },
}

local function to_abs(p)
  if type(p) ~= "string" or p == "" then
    return nil
  end
  if p:match("^/") or p:match("^%a:[/\\]") then
    return vim.fn.fnamemodify(p, ":p")
  end
  return vim.fn.fnamemodify(vim.fn.getcwd() .. "/" .. p, ":p")
end

M.run = function(args)
  args = args or {}
  local paths_arg = args.paths
  if type(paths_arg) ~= "table" then
    paths_arg = {}
  end

  local candidates = edit.get_deferred_paths() or {}

  local chosen
  if #paths_arg > 0 then
    local want = {}
    for _, p in ipairs(paths_arg) do
      local abs = to_abs(p)
      if abs then
        want[vim.fn.fnamemodify(abs, ":p")] = true
      end
    end
    chosen = {}
    for _, p in ipairs(candidates) do
      if want[vim.fn.fnamemodify(p, ":p")] then
        table.insert(chosen, p)
      end
    end
  else
    chosen = candidates
  end

  if #chosen == 0 then
    return {
      content = "No pending deferred edits to present.",
      request_review = false,
    }
  end

  table.sort(chosen)
  local rels = {}
  for _, p in ipairs(chosen) do
    table.insert(rels, "- " .. vim.fn.fnamemodify(p, ":."))
  end

  return {
    content = string.format("Presenting %d pending edit(s):\n%s", #chosen, table.concat(rels, "\n")),
    request_review = true,
    open_paths = chosen,
    params_line = string.format("Parameters used: paths=%s", vim.inspect(paths_arg)),
  }
end

return M
