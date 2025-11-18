local chat = {}

local log = require("neoai.debug").log

-- Ensure that the discard_all_diffs function is accessible
local ai_tools = require("neoai.ai_tools")
local prompt = require("neoai.prompt")
local storage = require("neoai.storage")
local uv = vim.loop

-- Lazy, idempotent initialisation
local _setup_done = false
local function ensure_setup()
  if _setup_done then
    return true
  end
  local ok = chat.setup()
  _setup_done = ok and true or false
  return _setup_done
end

-- Helper: get the configured "main" model name (if available)
local function get_main_model_name()
  local ok, cfg = pcall(require, "neoai.config")
  if not ok or not cfg or type(cfg.get_api) ~= "function" then
    return nil
  end
  local ok2, api = pcall(function()
    return cfg.get_api("main")
  end)
  if not ok2 or not api then
    return nil
  end
  local model = api.model
  if type(model) ~= "string" or model == "" then
    return nil
  end
  return model
end

local function input_has_text()
  local ib = chat.chat_state and chat.chat_state.buffers and chat.chat_state.buffers.input or nil
  if not (ib and vim.api.nvim_buf_is_valid(ib)) then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(ib, 0, -1, false)
  local text = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  return text ~= ""
end

-- Helper: build the Assistant header including the model name when available
local function build_assistant_header(time_str)
  local model = get_main_model_name()
  if model then
    return "**Assistant:** (" .. model .. ") *" .. time_str .. "*"
  else
    return "**Assistant:** *" .. time_str .. "*"
  end
end

-- Safe helper to stop and close a libuv timer without throwing when it's already closing
local function safe_stop_and_close_timer(t)
  if not t then
    return
  end
  local closing = false
  if uv and uv.is_closing then
    local ok, cl = pcall(uv.is_closing, t)
    closing = ok and cl or false
  end
  if closing then
    return
  end
  pcall(function()
    if t.stop then
      t:stop()
    end
  end)
  if uv and uv.is_closing then
    local ok2, cl2 = pcall(uv.is_closing, t)
    if ok2 and cl2 then
      return
    end
  end
  pcall(function()
    if t.close then
      t:close()
    end
  end)
end

-- Treesitter helpers to avoid crashes during streaming updates of partial Markdown/code
local function ts_suspend(bufnr)
  local ok, ts = pcall(require, "vim.treesitter")
  if ok and ts.stop and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(ts.stop, bufnr)
  end
end

local function ts_resume(bufnr)
  local ok, ts = pcall(require, "vim.treesitter")
  if ok and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    ---@diagnostic disable-next-line: undefined-field
    if ts.start then
      -- Reattach markdown parser
      pcall(ts.start, bufnr, "markdown")
    else
      -- Fallback: re-set filetype to trigger reattach
      pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", "markdown")
    end
  end
end

-- Thinking animation (spinner) helpers
local thinking_ns = vim.api.nvim_create_namespace("NeoAIThinking")

-- Redraw any windows that are currently showing the chat buffer, without stealing focus
local function redraw_chat_windows()
  local bufnr = chat.chat_state and chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("redraw")
      end)
    end
  end
end

-- Format a duration in seconds into a compact human-friendly string (e.g., 1m 33s)
local function fmt_duration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  local parts = {}
  if h > 0 then
    table.insert(parts, string.format("%dh", h))
  end
  if m > 0 or h > 0 then
    table.insert(parts, string.format("%dm", m))
  end
  table.insert(parts, string.format("%ds", s))
  return table.concat(parts, " ")
end

local function find_last_assistant_header_row()
  local bufnr = chat.chat_state and chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("^%*%*Assistant:%*%*") then
      return i - 1 -- 0-based row index
    end
  end
  return nil
end

local function stop_thinking_animation()
  local st = chat.chat_state and chat.chat_state.thinking or nil
  if not st then
    return
  end
  if st.timer then
    safe_stop_and_close_timer(st.timer)
    st.timer = nil
  end
  if
    st.extmark_id
    and chat.chat_state.buffers
    and chat.chat_state.buffers.chat
    and vim.api.nvim_buf_is_valid(chat.chat_state.buffers.chat)
  then
    pcall(vim.api.nvim_buf_del_extmark, chat.chat_state.buffers.chat, thinking_ns, st.extmark_id)
  end
  st.extmark_id = nil
  st.active = false
end

-- Ensure the thinking status (virt_lines) is visible with minimal scrolling
local function ensure_thinking_visible()
  if not (chat.chat_state and chat.chat_state.config and chat.chat_state.config.auto_scroll) then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  local st = chat.chat_state and chat.chat_state.thinking or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and st and st.extmark_id) then
    return
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, thinking_ns, st.extmark_id, {})
  if not ok or not pos or pos[1] == nil then
    return
  end
  local target = pos[1] + 1 -- 1-based line number of the header/anchor
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      -- Temporarily disable scrolloff to avoid re-centring (common with so=999)
      local orig_so
      local ok_get_so, so = pcall(function()
        return vim.wo[win].scrolloff
      end)
      if ok_get_so then
        orig_so = so
        pcall(function()
          vim.wo[win].scrolloff = 0
        end)
      end

      -- Query the current visible range for this window
      local view_ok, top, bot = pcall(function()
        return vim.api.nvim_win_call(win, function()
          return vim.fn.line("w0"), vim.fn.line("w$")
        end)
      end)

      if view_ok and top and bot then
        if target < top then
          -- Reveal just enough upwards: put target at the top
          pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
          pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("normal! zt")
          end)
        elseif target > bot then
          -- Reveal just enough downwards: put target at the bottom
          pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
          pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("normal! zb")
          end)
        else
          -- Already visible: do nothing
        end
      else
        -- Fallback: align to bottom rather than centring
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
        pcall(vim.api.nvim_win_call, win, function()
          vim.cmd("normal! zb")
        end)
      end

      -- Restore user's original scrolloff
      if orig_so ~= nil then
        pcall(function()
          vim.wo[win].scrolloff = orig_so
        end)
      end
    end
  end
end

-- Capture the current thinking duration and mark it to be announced when streaming begins
local function capture_thinking_duration_for_announce()
  local st = chat.chat_state and chat.chat_state.thinking or nil
  if not st then
    return
  end
  local secs = 0
  if st.start_time then
    secs = os.time() - st.start_time
  end
  st.last_duration_str = fmt_duration(secs)
  st.announce_pending = true
  stop_thinking_animation()
end

local function start_thinking_animation()
  if not (chat.chat_state and chat.chat_state.is_open) then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local row = find_last_assistant_header_row()
  if not row then
    return
  end

  local st = chat.chat_state.thinking
  -- Reset any previous state
  stop_thinking_animation()

  st.active = true
  st.start_time = os.time()
  st.announce_pending = false
  st.last_duration_str = nil

  local text = " Thinking… 0s "
  st.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, thinking_ns, row, 0, {
    virt_lines = {
      { { "", "Comment" } },
      { { text, "Comment" } },
    },
    virt_lines_above = false,
  })

  -- Auto-reveal the thinking status so it is visible without manual scrolling
  ensure_thinking_visible()
  -- Ensure the line is actually drawn even when focus remains in the input window
  redraw_chat_windows()

  st.timer = vim.loop.new_timer()
  ---@diagnostic disable-next-line: undefined-field
  st.timer:start(
    0,
    1000,
    vim.schedule_wrap(function()
      if not st.active then
        return
      end
      if
        not (
          chat.chat_state
          and chat.chat_state.buffers
          and chat.chat_state.buffers.chat
          and vim.api.nvim_buf_is_valid(chat.chat_state.buffers.chat)
        )
      then
        return
      end
      local b = chat.chat_state.buffers.chat
      local elapsed = 0
      if st.start_time then
        elapsed = os.time() - st.start_time
      end
      local t = " Thinking… " .. fmt_duration(elapsed) .. " "

      -- Be robust to header relocation: recompute the current header row when possible
      local current_row = find_last_assistant_header_row() or row

      if st.extmark_id then
        pcall(vim.api.nvim_buf_set_extmark, b, thinking_ns, current_row, 0, {
          id = st.extmark_id,
          virt_lines = {
            { { "", "Comment" } },
            { { t, "Comment" } },
          },
          virt_lines_above = false,
        })
      end

      -- Force a redraw for any windows showing the chat so the timer visibly updates
      redraw_chat_windows()
    end)
  )
end

-- Ctrl-C cancel listener (global) so it works even if mappings are bypassed
local CTRL_C_NS = vim.api.nvim_create_namespace("NeoAICtrlC")
local CTRL_C_KEY = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)

local function enable_ctrl_c_cancel()
  if not chat.chat_state then
    return
  end
  if chat.chat_state._ctrlc_enabled then
    return
  end
  chat.chat_state._ctrlc_enabled = true
  vim.on_key(function(keys)
    -- Only act when a stream is active
    if not (chat.chat_state and chat.chat_state.streaming_active) then
      return
    end
    if keys ~= CTRL_C_KEY then
      return
    end
    -- Restrict cancellation to chat or input buffers
    local cur = vim.api.nvim_get_current_buf()
    local bchat = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
    local binput = chat.chat_state.buffers and chat.chat_state.buffers.input or nil
    if cur == bchat or cur == binput then
      vim.schedule(function()
        require("neoai.chat").cancel_stream()
      end)
    end
  end, CTRL_C_NS)
end

local function disable_ctrl_c_cancel()
  if chat.chat_state and chat.chat_state._ctrlc_enabled then
    pcall(vim.on_key, nil, CTRL_C_NS)
    chat.chat_state._ctrlc_enabled = false
  end
end

-- Message types
local MESSAGE_TYPES = {
  USER = "user",
  ASSISTANT = "assistant",
  TOOL = "tool",
  SYSTEM = "system",
  THINKING = "thinking",
  ERROR = "error",
}

-- Defer review orchestration
local function get_edit_module()
  local ok, mod = pcall(require, "neoai.ai_tools.edit")
  if not ok then
    return nil
  end
  return mod
end

local function maybe_open_deferred_reviews(paths_override)
  local ed = get_edit_module()
  log(
    "maybe_open_deferred_reviews: inline_active=%s awaiting=%s",
    tostring(vim.g.neoai_inline_diff_active),
    tostring(chat.chat_state and chat.chat_state.awaiting_user_review)
  )
  if not ed then
    return
  end
  if vim.g.neoai_inline_diff_active then
    return
  end
  if not chat.chat_state or chat.chat_state.awaiting_user_review then
    return
  end

  -- Use provided paths if present; otherwise query the edit module
  local paths = paths_override
  if not paths or #paths == 0 then
    paths = ed.get_deferred_paths()
  end
  log("maybe_open_deferred_reviews: candidates=%d", #(paths or {}))
  if not paths or #paths == 0 then
    return
  end

  -- Queue all paths and open the first one
  chat.chat_state.awaiting_user_review = true
  chat.chat_state._review_queue = vim.deepcopy(paths)
  chat.chat_state._auto_resume_after_review = true -- arm one-shot auto-resume

  local function open_next()
    if not chat.chat_state._review_queue or #chat.chat_state._review_queue == 0 then
      chat.chat_state.awaiting_user_review = false
      chat.chat_state._review_queue = nil
      return
    end
    local p = table.remove(chat.chat_state._review_queue, 1)
    log("maybe_open_deferred_reviews: opening %s", tostring(p))
    local ok, msg = ed.open_deferred_review(p)
    if not ok then
      vim.notify("NeoAI: " .. (msg or "Failed to open review"), vim.log.levels.WARN)
      -- Try the next one
      vim.schedule(open_next)
    end
  end

  open_next()
end

-- Setup function (idempotent & non-fatal)
function chat.setup()
  if _setup_done then
    return true
  end

  -- Safe tools setup
  pcall(function()
    ai_tools.setup()
  end)

  -- Get config safely
  local ok_cfg, cfg = pcall(require, "neoai.config")
  if not ok_cfg or not cfg or not cfg.values or not cfg.values.chat then
    vim.notify("NeoAI: config not initialised; skipping chat setup", vim.log.levels.WARN)
    return false
  end

  -- Minimal state
  chat.chat_state = {
    config = cfg.values.chat,
    windows = {},
    buffers = {},
    current_session = nil,
    sessions = {},
    is_open = false,
    streaming_active = false,
    _timeout_timer = nil,
    _ts_suspended = false,
    thinking = { active = false, timer = nil, extmark_id = nil, frame = 1 },
    _diff_await_id = 0, -- This is necessary for the fix.
    _iter_map = {}, -- Track per-file iteration state for edit+diagnostic loop
    awaiting_user_review = false,
    _review_queue = nil,
    _last_tool_turn_ts = 0, -- os.time() of last tool-run turn
    _empty_turn_retry_used = false, -- guard to avoid infinite retries
    _consecutive_silent_turns = 0,
    _plan_without_action_count = 0,
  }

  -- Bridge inline diff outcome to chat as a user-visible message
  pcall(function()
    local grp = vim.api.nvim_create_augroup("NeoAIInlineDiffBridge", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = grp,
      pattern = "NeoAIInlineDiffClosed",
      callback = function(ev)
        log(
          "diff_closed: action=%s path=%s diagnostics=%s diff_len=%d",
          tostring(ev and ev.data and ev.data.action),
          tostring(ev and ev.data and ev.data.path),
          tostring(ev and ev.data and ev.data.diagnostics_count),
          #(tostring(ev and ev.data and ev.data.diff or ""))
        )
        local payload = ev and ev.data or {}
        local path = payload.path or "unknown"
        local action = payload.action or "closed"
        local diag_count = tonumber(payload.diagnostics_count or 0) or 0
        local diff_text = payload.diff or ""

        local lines = {}
        table.insert(lines, string.format("Review outcome for %s: %s", path, action))
        table.insert(lines, string.format("Diagnostics after review: %d issue(s).", diag_count))
        if diff_text ~= "" then
          table.insert(lines, "")
          table.insert(lines, "Final diff:")
          table.insert(lines, "```diff")
          table.insert(lines, diff_text)
          table.insert(lines, "```")
        end

        chat.add_message(MESSAGE_TYPES.USER, table.concat(lines, "\n"), {
          user_action = "review_result",
          file = path,
          action = action,
          diagnostics_count = diag_count,
        })

        if chat.chat_state and chat.chat_state._review_queue and #chat.chat_state._review_queue > 0 then
          vim.schedule(function()
            local ed = require("neoai.ai_tools.edit")
            local p = table.remove(chat.chat_state._review_queue, 1)
            log("maybe_open_deferred_reviews: opening %s", tostring(p))
            local ok2, msg2 = ed.open_deferred_review(p)
            if not ok2 then
              vim.notify("NeoAI: " .. (msg2 or "Failed to open review"), vim.log.levels.WARN)
            end
          end)
        else
          chat.chat_state.awaiting_user_review = false
          -- Always auto-resume once after the final review, unless the user is typing or a stream already started.
          if chat.chat_state._auto_resume_after_review then
            chat.chat_state._auto_resume_after_review = false -- one-shot
            vim.schedule(function()
              if not chat.chat_state.streaming_active and not input_has_text() then
                log("diff_closed: auto-resume after final review")
                chat.send_to_ai()
              else
                log("diff_closed: skip auto-resume (streaming or user input present)")
              end
            end)
          end
        end
      end,
    })
  end)

  -- Ensure daemon is stopped on exit
  pcall(function()
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("NeoAIDaemonCleanup", { clear = true }),
      callback = function()
        local ok, api = pcall(require, "neoai.api")
        if ok and api.get_client then
          local client = api.get_client()
          if client then
            client:stop()
          end
        end
      end,
    })
  end)

  -- Initialise storage backend (guarded, with dir creation and error surfacing)
  local db_path = (chat.chat_state.config and chat.chat_state.config.database_path) or nil
  if not db_path or db_path == "" then
    vim.notify("NeoAI: chat.database_path is not set", vim.log.levels.ERROR)
    return false
  end
  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(db_path, ":h")
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, dir, "p")
  end

  -- Init storage
  local ok_store, success, err = pcall(storage.init, chat.chat_state.config)
  if not ok_store or not success then
    local msg = "NeoAI: Failed to initialise storage"
    if err then
      msg = msg .. (": " .. tostring(err))
    end
    -- Add path to help you diagnose quickly
    msg = msg .. " (path: " .. db_path .. ")"
    vim.notify(msg, vim.log.levels.ERROR)
    return false
  end

  -- Load or create session (guarded)
  local ok_active, active = pcall(storage.get_active_session)
  if not ok_active or not active then
    local ok_new = pcall(chat.new_session)
    if not ok_new then
      vim.notify("NeoAI: Failed to create new session", vim.log.levels.ERROR)
      return false
    end
    active = storage.get_active_session()
    if not active then
      vim.notify("NeoAI: Failed to load active session", vim.log.levels.ERROR)
      return false
    end
  end
  chat.chat_state.current_session = active

  local ok_all, sessions = pcall(storage.get_all_sessions)
  chat.chat_state.sessions = ok_all and sessions or {}

  _setup_done = true
  return true
end

-- Scroll helper
local function scroll_to_bottom(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, win in pairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_win_set_cursor(win, { line_count, 0 })
      break
    end
  end
end

-- Update chat display (robust)
local function update_chat_display()
  if not (chat.chat_state and chat.chat_state.is_open and chat.chat_state.current_session) then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  local lines = {}
  local sess = chat.chat_state.current_session
  if not sess then
    return
  end

  local ok_msgs, messages = pcall(storage.get_session_messages, sess.id)
  messages = ok_msgs and messages or {}

  table.insert(lines, " **NeoAI Chat** ")
  table.insert(lines, " *Session: " .. (sess.title or "Untitled") .. "* ")
  table.insert(lines, " *ID: " .. sess.id .. " | Messages: " .. #messages .. "* ")
  table.insert(lines, " *Created: " .. sess.created_at .. "* ")
  if #chat.chat_state.sessions > 1 then
    table.insert(
      lines,
      " *Total Sessions: " .. #chat.chat_state.sessions .. " | Use :NeoAISessionList or `<leader>as` to switch* "
    )
  end
  table.insert(lines, "")

  for _, message in ipairs(messages) do
    local prefix = ""
    local ts = message.metadata and message.metadata.timestamp or message.created_at or "Unknown"
    if message.type == MESSAGE_TYPES.USER then
      prefix = "**User:** *" .. ts .. "*"
    elseif message.type == MESSAGE_TYPES.ASSISTANT then
      prefix = build_assistant_header(ts)
      if message.metadata and message.metadata.response_time then
        prefix = prefix:gsub("%*$", " (" .. message.metadata.response_time .. "s)*")
      end
    elseif message.type == MESSAGE_TYPES.TOOL then
      local tooln = (message.metadata and message.metadata.tool_name) or nil
      if tooln and tooln ~= "" then
        prefix = "**Tool Response (" .. tooln .. ")**: *" .. ts .. "*"
      else
        prefix = "**Tool Response:** *" .. ts .. "*"
      end
    elseif message.type == MESSAGE_TYPES.SYSTEM then
      prefix = "**System:** *" .. ts .. "*"
    elseif message.type == MESSAGE_TYPES.ERROR then
      prefix = "**Error:** *" .. ts .. "*"
    end

    table.insert(lines, "---")
    table.insert(lines, prefix)
    table.insert(lines, "")
    -- Prefer display text (if provided) to avoid cluttering the chat UI
    local display_content = message.content or ""
    if message.metadata and message.metadata.display and message.metadata.display ~= "" then
      display_content = message.metadata.display
    end
    for _, line in ipairs(vim.split(display_content, "\n")) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if chat.chat_state.config.auto_scroll then
    scroll_to_bottom(bufnr)
  end
end

-- Add message
---@param type string
---@param content string
---@param metadata table | nil
---@param tool_call_id string | nil
---@param tool_calls any
function chat.add_message(type, content, metadata, tool_call_id, tool_calls)
  if type == MESSAGE_TYPES.USER then
    chat.chat_state.user_feedback = true -- Track that feedback occurred
  end
  metadata = metadata or {}
  metadata.timestamp = metadata.timestamp or os.date("%Y-%m-%d %H:%M:%S")

  log(
    "storage.add_message: type=%s tool_call_id=%s tool_calls=%s content_len=%d",
    tostring(type),
    tostring(tool_call_id),
    (tool_calls and #tool_calls) or 0,
    #(tostring(content or ""))
  )

  local ok_add, msg_id =
    pcall(storage.add_message, chat.chat_state.current_session.id, type, content, metadata, tool_call_id, tool_calls)
  if not ok_add or not msg_id then
    vim.notify("Failed to save message to storage", vim.log.levels.ERROR)
  end

  if chat.chat_state.is_open then
    update_chat_display()
  end
end

-- New session (non-fatal)
function chat.new_session(title)
  title = title or ("Session " .. os.date("%Y-%m-%d %H:%M:%S"))
  local ok_create, session_id = pcall(storage.create_session, title, {})
  if not ok_create or not session_id then
    vim.notify("NeoAI: Failed to create new session", vim.log.levels.ERROR)
    return false
  end

  local active = storage.get_active_session()
  if not active then
    vim.notify("NeoAI: Failed to load active session after creation", vim.log.levels.ERROR)
    return false
  end

  chat.chat_state.current_session = active
  chat.chat_state.sessions = storage.get_all_sessions()

  chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", { session_id = session_id })
  vim.notify("Created new session: " .. title, vim.log.levels.INFO)
  return true
end

-- Open/close/toggle
function chat.open()
  if not ensure_setup() then
    vim.notify("NeoAI: Chat initialisation failed; check your config and storage", vim.log.levels.ERROR)
    return
  end
  local ui = require("neoai.ui")
  local keymaps = require("neoai.keymaps")
  ui.open()
  keymaps.buffer_setup()
  chat.chat_state.is_open = true
  update_chat_display()
end

function chat.close()
  -- Ensure any active thinking animation is stopped when closing the UI
  stop_thinking_animation()
  disable_ctrl_c_cancel()
  require("neoai.ui").close()
  chat.chat_state.is_open = false
end

function chat.toggle()
  if chat.chat_state and chat.chat_state.is_open then
    chat.close()
  else
    chat.open()
  end
end

-- Send message
function chat.send_message()
  if not chat.chat_state or not chat.chat_state.buffers or not chat.chat_state.buffers.input then
    vim.notify("NeoAI: Chat is not initialised", vim.log.levels.WARN)
    return
  end

  if chat.chat_state.streaming_active and chat.chat_state.user_feedback then
    vim.notify("Pending diffs handled. Awaiting inline diff review.", vim.log.levels.INFO)
    return
  end

  if chat.chat_state.streaming_active then
    vim.notify("Please wait for the current response to complete", vim.log.levels.WARN)
    return
  end

  -- Normal message handling.
  local lines = vim.api.nvim_buf_get_lines(chat.chat_state.buffers.input, 0, -1, false)
  local message = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
  if message == "" then
    return
  end

  chat.add_message(MESSAGE_TYPES.USER, message)
  vim.api.nvim_buf_set_lines(chat.chat_state.buffers.input, 0, -1, false, { "" })
  chat.send_to_ai()
end

-- Send to AI
function chat.send_to_ai()
  log("chat.send_to_ai: start")
  -- Prepare template data: tools and optional AGENTS.md content
  local agents_md = nil
  do
    -- Try to locate AGENTS.md at repo root or current working directory
    local candidate_paths = {}
    -- 1) If inside a git repo, detect its root
    local git_root = nil
    pcall(function()
      local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
      if handle then
        local out = handle:read("*a") or ""
        handle:close()
        out = (out:gsub("\r", ""):gsub("\n", ""))
        if out ~= "" then
          git_root = out
        end
      end
    end)
    local cwd = vim.loop.cwd()
    local roots = {}
    if git_root and git_root ~= "" then
      table.insert(roots, git_root)
    end
    if cwd and cwd ~= git_root then
      table.insert(roots, cwd)
    end

    for _, root in ipairs(roots) do
      table.insert(candidate_paths, root .. "/AGENTS.md")
      table.insert(candidate_paths, root .. "/agents.md")
    end

    for _, path in ipairs(candidate_paths) do
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a") or ""
        f:close()
        content = (content:gsub("^%s+", ""):gsub("%s+$", ""))
        if content ~= "" then
          agents_md = "---\n## 📘 Project AGENTS.md\n\n" .. content .. "\n---"
          break
        end
      end
    end
  end

  local data = {
    tools = chat.format_tools(),
    agents = agents_md or "",
  }

  local system_prompt = prompt.get_system_prompt(data)
  local messages = {
    { role = "system", content = system_prompt },
  }

  -- Fetch a generous recent window to reduce the chance of slicing between
  -- an assistant tool_calls turn and its tool responses.
  local session_msgs = storage.get_session_messages(chat.chat_state.current_session.id, 300)

  -- Bootstrap pre-flight: always run on the first user turn of a new session.
  do
    local is_first_turn = (#session_msgs == 2 and session_msgs[2].type == MESSAGE_TYPES.USER)
    if is_first_turn then
      local boot_cfg = (chat.chat_state and chat.chat_state.config and chat.chat_state.config.bootstrap) or nil
      require("neoai.bootstrap").run_preflight(chat, boot_cfg)
      -- Refresh session messages so the subsequent payload includes the bootstrap turn
      session_msgs = storage.get_session_messages(chat.chat_state.current_session.id, 300)
    end
  end

  log("chat.send_to_ai: session_msgs_window | n=%d", #(session_msgs or {}))

  -- Build a valid provider payload by shaping the conversation so that:
  -- - tool messages only appear immediately after an assistant message with tool_calls
  -- - orphan tool messages (e.g. due to truncation) are skipped
  -- - we include only user/assistant/tool messages
  local recent = {}
  for i = #session_msgs, 1, -1 do
    local msg = session_msgs[i]
    if msg.type == MESSAGE_TYPES.USER or msg.type == MESSAGE_TYPES.ASSISTANT or msg.type == MESSAGE_TYPES.TOOL then
      table.insert(recent, 1, msg)
      if #recent >= 150 then
        break
      end
    end
  end

  log("chat.send_to_ai: shaping | recent=%d", #recent)

  -- Shape into API messages with correct tool pairing
  do
    local pending_tool_ids = nil ---@type table<string, boolean>|nil
    for _, msg in ipairs(recent) do
      if msg.type == MESSAGE_TYPES.ASSISTANT then
        -- Reset pending ids unless this assistant includes tool calls
        pending_tool_ids = nil
        local tool_calls = msg.tool_calls
        if type(tool_calls) == "table" and #tool_calls > 0 then
          pending_tool_ids = {}
          local ids = {}
          for _, tc in ipairs(tool_calls) do
            if tc and (tc.id or tc.index) then
              local id = tc.id
              if not id or id == "" then
                -- S synthesise a stable id from index if needed (belt and braces)
                id = string.format("tc-%s-%d", tostring(msg.id or "turn"), tonumber(tc.index or 0))
                tc.id = id
              end
              pending_tool_ids[tostring(id)] = true
              table.insert(ids, tostring(id))
            end
          end
          log("shaper: assistant tool_calls | n=%d ids=%s", #tool_calls, table.concat(ids, ","))
        end
        table.insert(messages, {
          role = "assistant",
          content = msg.content,
          tool_calls = tool_calls,
        })
      elseif msg.type == MESSAGE_TYPES.TOOL then
        -- Only include tool messages that respond to a currently pending tool id
        local tid = msg.tool_call_id and tostring(msg.tool_call_id) or "<nil>"
        local include = (pending_tool_ids and tid and pending_tool_ids[tid]) and true or false
        log("shaper: tool msg | tool_call_id=%s include=%s", tostring(tid), tostring(include))
        if include then
          -- Consume this id (each tool_call should have at most one tool response)
          pending_tool_ids[tid] = nil
          table.insert(messages, {
            role = "tool",
            content = msg.content,
            tool_call_id = msg.tool_call_id,
          })
        else
          -- Skip orphan tool messages to satisfy provider constraints
        end
      elseif msg.type == MESSAGE_TYPES.USER then
        -- Any user input breaks a pending tool response chain
        pending_tool_ids = nil
        table.insert(messages, { role = "user", content = msg.content })
      end
    end
  end

  if
    chat.chat_state.is_open
    and chat.chat_state.buffers
    and chat.chat_state.buffers.chat
    and vim.api.nvim_buf_is_valid(chat.chat_state.buffers.chat)
  then
    local bufnr = chat.chat_state.buffers.chat
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    table.insert(lines, "---")
    table.insert(lines, build_assistant_header(os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(lines, "")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if chat.chat_state.config.auto_scroll then
      scroll_to_bottom(bufnr)
    end
    start_thinking_animation()
  end

  log("chat.send_to_ai: call api.stream | payload_messages=%d", #messages)
  chat.stream_ai_response(messages)
end

-- Tool call handling
---@param tool_schemas table
function chat.get_tool_calls(tool_schemas)
  log("chat.get_tool_calls: start | n=%d", #(tool_schemas or {}))
  -- Ensure any previous stream is considered ended before orchestrating tools/resume.
  chat.chat_state.streaming_active = false

  -- Mark that we just entered a tool-call turn and reset empty-turn retry guard
  chat.chat_state._last_tool_turn_ts = os.time()
  chat.chat_state._empty_turn_retry_used = false
  chat.chat_state._consecutive_silent_turns = 0

  for _, sc in ipairs(tool_schemas or {}) do
    local name = sc and sc["function"] and sc["function"].name or "<nil>"
    log("chat.get_tool_calls: schema | idx=%s id=%s name=%s", tostring(sc and sc.index), tostring(sc and sc.id), name)
  end
  local summary = require("neoai.tool_runner").run_tool_calls(chat, tool_schemas)
  log("chat.get_tool_calls: finished run_tool_calls")

  -- Decide next step centrally: either present diffs now (if requested) or resume the model.
  vim.schedule(function()
    if summary and summary.request_review then
      log("chat.get_tool_calls: PresentEdits requested; opening %d path(s)", #(summary.paths or {}))
      maybe_open_deferred_reviews(summary and summary.paths or nil)
      return
    end

    log("chat.get_tool_calls: no present request; resuming model turn")
    chat.send_to_ai()
  end)

  return summary
end

-- Format tools
function chat.format_tools()
  local names = {}
  for _, tool in ipairs(ai_tools.tool_schemas) do
    if tool.type == "function" and tool["function"] and tool["function"].name then
      table.insert(names, tool["function"].name)
    end
  end
  return table.concat(names, ", ")
end

-- Stream AI response
function chat.stream_ai_response(messages)
  log("stream_ai_response: entry | msgs=%d", #(messages or {}))
  local api = require("neoai.api")
  chat.chat_state.streaming_active = true
  enable_ctrl_c_cancel()

  if chat.chat_state.is_open and chat.chat_state.buffers.chat and not chat.chat_state._ts_suspended then
    ts_suspend(chat.chat_state.buffers.chat)
    chat.chat_state._ts_suspended = true
  end

  local reason, content, tool_calls_response = "", "", {}
  local tool_calls_by_id = {} -- Accumulate tool calls across chunks (id -> record)
  local reasoning_summary = "" -- Accumulate streamed reasoning summary
  log("stream_ai_response: init state")
  local start_time = os.time()
  local saw_first_token = false
  local has_completed = false

  local function human_bytes(n)
    if not n or n <= 0 then
      return "0 B"
    end
    if n < 1024 then
      return string.format("%d B", n)
    elseif n < 1024 * 1024 then
      return string.format("%.1f KB", n / 1024)
    elseif n < 1024 * 1024 * 1024 then
      return string.format("%.2f MB", n / (1024 * 1024))
    else
      return string.format("%.2f GB", n / (1024 * 1024 * 1024))
    end
  end

  local function render_tool_prep_status()
    local per_call = {}
    local total = 0
    for _, tc in ipairs(tool_calls_response) do
      local name = (tc["function"] and tc["function"].name) or (tc.type or "function")
      local args = (tc["function"] and tc["function"].arguments) or ""
      local size = #args
      total = total + size
      table.insert(per_call, string.format("- %s: %s", name ~= "" and name or "function", human_bytes(size)))
    end

    local header = "\nPreparing tool calls…"
    if #per_call > 0 then
      header = header .. string.format(" (total %s)", human_bytes(total))
    end
    local body = table.concat(per_call, "\n")
    local display = header
    if body ~= "" then
      display = display .. "\n" .. body
    end
    return display
  end

  if chat.chat_state._timeout_timer then
    safe_stop_and_close_timer(chat.chat_state._timeout_timer)
    chat.chat_state._timeout_timer = nil
  end

  local timeout_duration_s = require("neoai.config").values.chat.thinking_timeout or 300
  local thinking_timeout_timer = vim.loop.new_timer()
  chat.chat_state._timeout_timer = thinking_timeout_timer

  local function handle_timeout()
    if has_completed then
      return
    end
    has_completed = true

    if not chat.chat_state.streaming_active then
      return
    end
    chat.chat_state.streaming_active = false
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
    stop_thinking_animation()
    disable_ctrl_c_cancel()

    local err_msg = "NeoAI: Timed out after " .. timeout_duration_s .. "s waiting for a response."
    chat.add_message(MESSAGE_TYPES.ERROR, err_msg, { timeout = true })
    update_chat_display()
    vim.notify(err_msg, vim.log.levels.ERROR)

    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end

    require("neoai.api").cancel()
  end

  thinking_timeout_timer:start(timeout_duration_s * 1000, 0, vim.schedule_wrap(handle_timeout))
  api.stream(messages, function(chunk)
    if not saw_first_token then
      saw_first_token = true
      capture_thinking_duration_for_announce()
      -- Convert to a stall timer that resets on every chunk
      local stall_s = (require("neoai.config").values.chat.stream_stall_timeout or 60)
      thinking_timeout_timer:stop()
      thinking_timeout_timer:start(stall_s * 1000, 0, vim.schedule_wrap(handle_timeout))
    else
      -- reset stall timer on each chunk
      local stall_s = (require("neoai.config").values.chat.stream_stall_timeout or 60)
      thinking_timeout_timer:stop()
      thinking_timeout_timer:start(stall_s * 1000, 0, vim.schedule_wrap(handle_timeout))
    end

    if chunk.type == "content" and chunk.data ~= "" then
      content = tostring(content) .. chunk.data
      chat.update_streaming_message(reason, tostring(content or ""), false, reasoning_summary)
    elseif chunk.type == "reasoning" and chunk.data ~= "" then
      reason = reason .. chunk.data
      chat.update_streaming_message(reason, tostring(content), false, reasoning_summary)
    elseif chunk.type == "reasoning_summary" and chunk.data ~= "" then
      reasoning_summary = reasoning_summary .. chunk.data
      chat.update_streaming_message(reason, tostring(content), false, reasoning_summary)
    elseif chunk.type == "tool_calls" then
      local calls = type(chunk.data) == "table" and chunk.data or {}
      local n = #calls
      local ids = {}
      for _, tc in ipairs(calls) do
        table.insert(ids, tostring(tc.id or tc.call_id or ("<noid>#" .. tostring(tc.index or -1))))
      end
      log("stream_ai_response: chunk tool_calls | n=%d ids=%s", n, table.concat(ids, ","))

      -- Accumulate by id across chunks (do not drop earlier calls)
      local stamp = tostring(os.time())
      for _, tc in ipairs(calls) do
        local id = tc.id or tc.call_id
        if not id or id == "" then
          if tc.index ~= nil then
            id = string.format("idx_%d", tc.index)
          else
            id = "tc-" .. stamp
          end
        end
        local fn_name = (tc["function"] and tc["function"].name) or tc.name or ""
        local fn_args = (tc["function"] and tc["function"].arguments) or tc.arguments or ""

        tool_calls_by_id[id] = {
          id = id,
          index = tc.index, -- may be nil
          type = "function",
          ["function"] = { name = fn_name, arguments = fn_args or "" },
        }
      end

      -- Rebuild stable array for status UI and for on_complete
      local arr = {}
      for _, rec in pairs(tool_calls_by_id) do
        table.insert(arr, rec)
      end
      table.sort(arr, function(a, b)
        if a.index ~= nil and b.index ~= nil then
          return a.index < b.index
        elseif a.index ~= nil then
          return true
        elseif b.index ~= nil then
          return false
        else
          return tostring(a.id) < tostring(b.id)
        end
      end)
      tool_calls_response = arr

      -- Show preparation status (sizes), then keep streaming content as usual
      local prep_status = render_tool_prep_status()
      chat.update_streaming_message(prep_status, tostring(content or ""), false, reasoning_summary)
    end
  end, function()
    if has_completed then
      return
    end
    has_completed = true

    if not chat.chat_state.streaming_active then
      return
    end
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
    stop_thinking_animation()

    log(
      "stream_ai_response: on_complete | content_len=%d tool_calls=%d",
      #(tostring(content or "")),
      #tool_calls_response
    )

    -- Persist any streamed assistant content/reasoning before handling tool calls,
    -- so it remains visible in the chat even after the UI refresh, but do NOT
    -- put reasoning/summary into assistant content (keep it for UI only).
    do
      local have_reason = (reason and reason ~= "")
      local have_summary = (reasoning_summary and reasoning_summary ~= "")
      local have_content = (content and content ~= "")
      if have_reason or have_summary or have_content then
        local meta = { response_time = os.time() - start_time }
        local parts = {}

        if have_reason then
          table.insert(parts, "Reasoning:\n" .. reason)
        end
        if have_summary then
          meta.reasoning_summary = reasoning_summary
          table.insert(parts, "Reasoning summary:\n" .. reasoning_summary)
        end
        if have_content then
          table.insert(parts, content)
        end

        local combined = (#parts > 0) and table.concat(parts, "\n\n") or "(plan)"
        meta.display = combined

        -- Store only the assistant's final content (no reasoning/summary) so API history stays clean.
        local content_only = have_content and content or ""
        chat.add_message(MESSAGE_TYPES.ASSISTANT, content_only, meta)
      end
    end

    update_chat_display()

    disable_ctrl_c_cancel()

    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end

    if #tool_calls_response > 0 then
      -- The model turn ended with tool calls; mark stream as ended so the tool orchestrator can resume the loop.
      chat.chat_state.streaming_active = false
      chat.get_tool_calls(tool_calls_response)
    else
      -- No more tools; end of turn.
      chat.chat_state.streaming_active = false

      local content_txt = tostring(content or "")
      local silent = (content_txt == "")
      local now = os.time()
      local recent_tool = chat.chat_state._last_tool_turn_ts > 0 and ((now - chat.chat_state._last_tool_turn_ts) <= 180)

      -- Detect plan-without-action cues even when no recent tool turn
      local plan_cue = false
      do
        -- Tweak phrases here as you see them in the wild
        if
          content_txt:match("[Pp]roceeding")
          or content_txt:match("[Ww]ill%s+read")
          or content_txt:match("[Rr]eading")
          or content_txt:match("[Ii]nspecting")
          or content_txt:match("[Ww]ill%s+apply")
          or content_txt:match("[Ww]ill%s+implement")
        then
          plan_cue = true
        end
      end

      local should_resume = false
      local resume_reason = ""

      if recent_tool then
        if silent then
          chat.chat_state._consecutive_silent_turns = (chat.chat_state._consecutive_silent_turns or 0) + 1
          if chat.chat_state._consecutive_silent_turns <= 5 then
            should_resume = true
            resume_reason = string.format("silent turn #%d after tools", chat.chat_state._consecutive_silent_turns)
          else
            log("chat: max silent retries (5) reached")
          end
        elseif plan_cue then
          chat.chat_state._plan_without_action_count = (chat.chat_state._plan_without_action_count or 0) + 1
          if chat.chat_state._plan_without_action_count <= 3 then
            should_resume = true
            resume_reason = string.format("plan-without-action #%d", chat.chat_state._plan_without_action_count)
          else
            log("chat: max plan-without-action retries (3) reached")
          end
        else
          -- Reset counters if the assistant actually responded substantively
          chat.chat_state._consecutive_silent_turns = 0
          chat.chat_state._plan_without_action_count = 0
        end
      else
        -- New: also resume on plan cues even when there was no recent tool turn
        if plan_cue then
          chat.chat_state._plan_without_action_count = (chat.chat_state._plan_without_action_count or 0) + 1
          if chat.chat_state._plan_without_action_count <= 2 then
            should_resume = true
            resume_reason = "plan-cue without recent tools"
          else
            log("chat: plan-cue retries exceeded (2) without recent tools")
          end
        else
          chat.chat_state._consecutive_silent_turns = 0
          chat.chat_state._plan_without_action_count = 0
        end
      end

      if should_resume then
        -- Persist a snapshot for the UI only; avoid polluting the next request payload.
        local content_txt = tostring(content or "")
        local meta = { response_time = os.time() - start_time, partial = true }
        local parts = {}

        if reason and reason ~= "" then
          table.insert(parts, "Reasoning:\n" .. reason)
        end
        if content_txt ~= "" then
          table.insert(parts, content_txt)
        else
          table.insert(parts, "(plan)")
        end
        if reasoning_summary and reasoning_summary ~= "" then
          table.insert(parts, "Reasoning summary:\n" .. reasoning_summary)
          meta.reasoning_summary = reasoning_summary
        end

        local combined = table.concat(parts, "\n\n")
        meta.display = combined

        -- Store empty content so api.chat_messages_to_items omits this assistant turn,
        -- keeping the next request free of interim reasoning/snapshot text.
        chat.add_message(MESSAGE_TYPES.ASSISTANT, "", meta)
        update_chat_display()

        log("chat: auto-resume (persisted partial) after %s", resume_reason)
        vim.schedule(function()
          if not chat.chat_state.streaming_active and not input_has_text() then
            chat.send_to_ai()
          end
        end)
        return
      end

      if silent then
        log("chat: skip persisting empty assistant message")
      end

      vim.schedule(function()
        log("stream_ai_response: opening deferred reviews (if any)")
        maybe_open_deferred_reviews()
      end)
    end
  end, function(exit_code)
    if has_completed then
      return
    end
    has_completed = true

    if not chat.chat_state.streaming_active then
      return
    end
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
    chat.chat_state.streaming_active = false
    stop_thinking_animation()
    local err_text = "AI error: " .. tostring(exit_code)
    log("stream_ai_response: on_error | %s", tostring(exit_code))
    chat.add_message(MESSAGE_TYPES.ERROR, err_text, {})
    update_chat_display()
    -- Also show a notification so the user is immediately aware
    vim.notify("NeoAI: " .. err_text, vim.log.levels.ERROR)
    disable_ctrl_c_cancel()
    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end
    -- Ensure any underlying job is terminated promptly
    pcall(function()
      require("neoai.api").cancel()
    end)
  end, function()
    if not chat.chat_state.streaming_active then
      return
    end
    log("stream_ai_response: end callback")
    safe_stop_and_close_timer(thinking_timeout_timer)
    chat.chat_state._timeout_timer = nil
  end)
end

-- Update streaming display (shows reasoning and content as they arrive)
---@param reason string | nil
---@param content string | nil
---@param append boolean
---@param summary string | nil
function chat.update_streaming_message(reason, content, append, summary)
  if not chat.chat_state.is_open or not chat.chat_state.streaming_active then
    return
  end
  local bufnr = chat.chat_state.buffers and chat.chat_state.buffers.chat or nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local display = ""
  -- Insert the thinking duration announcement (if any) at the very top, just once
  local st_ = chat.chat_state and chat.chat_state.thinking or nil
  if st_ and st_.announce_pending and st_.last_duration_str and st_.last_duration_str ~= "" then
    display = display .. "Thought for " .. st_.last_duration_str .. "\n\n"
    st_.announce_pending = false
  end
  -- Ensure the "Preparing tool calls…" status appears below already streamed text, while
  -- keeping any general reasoning text (when present) above the content as before.
  local prep_status
  if type(reason) == "string" and reason:find("Preparing tool calls") then
    -- Trim any leading newlines so spacing remains tidy when appended below.
    prep_status = reason:gsub("^%s*\n+", "")
    reason = nil
  end

  if reason and reason ~= "" then
    display = display .. reason .. "\n\n"
  end
  if content and content ~= "" then
    display = display .. tostring(content)
  end

  -- Stream reasoning summary below content when available
  if summary and summary ~= "" then
    if display ~= "" then
      display = display .. "\n\n"
    end
    display = display .. "Reasoning summary:\n" .. summary
  end

  if prep_status and prep_status ~= "" then
    if display ~= "" then
      display = display .. "\n\n" .. prep_status
    else
      display = prep_status
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("^%*%*Assistant:%*%*") then
      local new_lines = {}
      for j = 1, i - 1 do
        table.insert(new_lines, lines[j])
      end
      table.insert(new_lines, build_assistant_header(os.date("%Y-%m-%d %H:%M:%S")))

      table.insert(new_lines, "")
      for _, ln in ipairs(vim.split(display, "\n")) do
        table.insert(new_lines, "  " .. ln)
      end
      table.insert(new_lines, "")
      vim.api.nvim_buf_set_lines(bufnr, append and #lines or 0, -1, false, new_lines)
      if chat.chat_state.config.auto_scroll then
        scroll_to_bottom(bufnr)
      end
      break
    end
  end
end

-- Append content to current stream
---@param reason string | nil
---@param content string | nil
---@param extra string | nil
---@param summary string | nil
function chat.append_to_streaming_message(reason, content, extra, summary)
  if not chat.chat_state.is_open or not chat.chat_state.streaming_active then
    return
  end
  local final_content = content or ""
  if type(extra) == "string" and extra ~= "" then
    if final_content ~= "" then
      final_content = final_content .. "\n"
    end
    final_content = final_content .. extra
  end
  chat.update_streaming_message(reason, final_content, true, summary)
end

-- Allow cancelling current stream
function chat.cancel_stream()
  if chat.chat_state.streaming_active then
    chat.chat_state.streaming_active = false
    chat.chat_state.user_feedback = true

    stop_thinking_animation()
    local t = chat.chat_state._timeout_timer
    if t then
      safe_stop_and_close_timer(t)
      chat.chat_state._timeout_timer = nil
    end

    disable_ctrl_c_cancel()

    if chat.chat_state._ts_suspended and chat.chat_state.buffers.chat then
      ts_resume(chat.chat_state.buffers.chat)
      chat.chat_state._ts_suspended = false
    end

    if chat.chat_state.is_open then
      update_chat_display()
    end

    local api = require("neoai.api")
    api.cancel()
  end
end

-- Cancel stream if active, otherwise close chat
function chat.cancel_or_close()
  if chat.chat_state.streaming_active then
    chat.cancel_stream()
  else
    chat.close()
  end
end

-- Session info and management
function chat.get_session_info()
  local msgs = storage.get_session_messages(chat.chat_state.current_session.id)
  return {
    id = chat.chat_state.current_session.id,
    title = chat.chat_state.current_session.title,
    created_at = chat.chat_state.current_session.created_at,
    message_count = #msgs,
  }
end

function chat.switch_session(session_id)
  local success = storage.switch_session(session_id)
  if success then
    chat.chat_state.current_session = storage.get_active_session()
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then
      update_chat_display()
    end
  end
  return success
end

function chat.get_all_sessions()
  return storage.get_all_sessions()
end

function chat.delete_session(session_id)
  local sessions = storage.get_all_sessions()
  if #sessions <= 1 then
    vim.notify("Cannot delete the only session", vim.log.levels.WARN)
    return false
  end
  local is_current = chat.chat_state.current_session.id == session_id
  local success = storage.delete_session(session_id)
  if success then
    if is_current then
      local rem = storage.get_all_sessions()
      if #rem > 0 then
        chat.switch_session(rem[1].id)
      else
        chat.new_session()
      end
    end
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then
      update_chat_display()
    end
  end
  return success
end

function chat.rename_session(new_title)
  local success = storage.update_session_title(chat.chat_state.current_session.id, new_title)
  if success then
    chat.chat_state.current_session.title = new_title
    chat.chat_state.sessions = storage.get_all_sessions()
    if chat.chat_state.is_open then
      update_chat_display()
    end
    vim.notify("Session renamed to: " .. new_title, vim.log.levels.INFO)
  end
  return success
end

function chat.clear_session()
  local success = storage.clear_session_messages(chat.chat_state.current_session.id)
  if success then
    chat.add_message(MESSAGE_TYPES.SYSTEM, "NeoAI Chat Session Started", {})
    if chat.chat_state.is_open then
      update_chat_display()
    end
  end
  return success
end

--- Open chat (if not open) and clear the current session so the user sees a fresh chat
function chat.open_and_clear()
  chat.open()
  return chat.clear_session()
end

function chat.get_stats()
  return storage.get_stats()
end

function chat.lookup_messages(term)
  if term == "" then
    vim.notify("Provide a search term", vim.log.levels.WARN)
    return
  end
  local results = {}
  for _, m in ipairs(storage.get_session_messages(chat.chat_state.current_session.id)) do
    if m.content:find(term, 1, true) then
      table.insert(results, m)
    end
  end
  vim.cmd("botright new")
  vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile, vim.bo.filetype = "nofile", "wipe", false, "markdown"
  local lines = { "# Lookup messages containing '" .. term .. "'", "" }
  if #results == 0 then
    table.insert(lines, "No messages found.")
  else
    for _, m in ipairs(results) do
      local ts = m.metadata and m.metadata.timestamp or m.created_at or "Unknown"
      table.insert(lines, "- **" .. m.type .. "** at *" .. ts .. "*")
      table.insert(lines, "```")
      table.insert(lines, m.content)
      table.insert(lines, "```")
      table.insert(lines, "")
    end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modifiable = false
end

-- Export
chat.MESSAGE_TYPES = MESSAGE_TYPES
return chat
