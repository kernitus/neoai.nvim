-- Example configuration for NeoAI plugin
-- Copy this to your init.lua or plugin configuration

---@class APIConfig
---@field url string
---@field api_key string
---@field model string
---@field max_output_tokens number|nil
---@field api_key_header string|nil
---@field api_key_format string|nil
---@field additional_kwargs? table<string, any>
---@field native_tools? table[]  -- e.g. { { type = "web_search" }, { type = "file_search" } }

---@class APISet
---@field main APIConfig
---@field small APIConfig

---@class KeymapConfig
---@field normal table<string, string>
---@field input table<string, string>
---@field chat table<string, string|string[]>
---@field session_picker string

---@class WindowConfig
---@field width number
---@field height_ratio number  -- Fraction of column height for chat window (0..1). 0.8 => 80% chat, 20% input
---@field min_input_lines number -- Minimum lines reserved for input window

---@class BootstrapToolConfig
---@field name string
---@field args table|nil

---@class BootstrapConfig
---@field strategy string|nil
---@field tools BootstrapToolConfig[]

---@class ChatConfig
---@field window WindowConfig
---@field auto_scroll boolean
---@field database_path string
---@field thinking_timeout number|nil
---@field bootstrap BootstrapConfig|nil

---@class Config
---@field api APISet
---@field chat ChatConfig
---@field keymaps KeymapConfig
---@field presets table<string, table>
---@field preset string|nil

local config = {}
-- Default configuration
---@type Config
config.defaults = {
  keymaps = {
    input = {
      -- Insert file with @@ trigger in insert mode
      file_picker = "@@",
      close = "<C-c>",
      send_message = "<CR>",
    },
    chat = {
      close = { "<C-c>", "q" },
    },
    normal = {
      open = "<leader>ai",
      toggle = "<leader>at",
      clear_history = "<leader>ac",
    },
    session_picker = "default",
  },
  -- API settings (two labelled models are required)
  api = {
    main = {
      url = "your-api-url-here", -- Use a Responses API endpoint, e.g. https://api.openai.com/v1/responses
      api_key = os.getenv("AI_API_KEY") or "<your api key>", -- Support environment variables
      api_key_header = "Authorization", -- Default header
      api_key_format = "Bearer %s", -- Default format
      model = "your-main-model-here",
      max_output_tokens = 4096,
      api_call_delay = 0,
      native_tools = {}, -- e.g. { { type = "web_search" } }
    },
    small = {
      url = "your-api-url-here",
      api_key = os.getenv("AI_API_KEY") or "<your api key>",
      api_key_header = "Authorization",
      api_key_format = "Bearer %s",
      model = "your-small-model-here",
      max_output_tokens = 4096,
      api_call_delay = 0,
      native_tools = {},
    },
  },

  -- Chat UI settings
  chat = {
    window = {
      width = 80, -- Chat window column width
      height_ratio = 0.8, -- 80% of column height for chat window
      min_input_lines = 3, -- Ensure input has at least a few lines
    },

    -- Storage settings:
    -- Example: database_path = vim.fn.stdpath("data") .. "/neoai.db"
    --          database_path = vim.fn.stdpath("data") .. "/neoai.json"
    database_path = vim.fn.stdpath("data") .. "/neoai.json",

    -- Display settings:
    auto_scroll = true, -- Auto-scroll to bottom

    -- Streaming/response handling
    thinking_timeout = 300, -- seconds

    -- Bootstrap pre-flight: always runs on the first user turn and injects
    -- synthetic tool_call + tool messages so the model starts with context.
    -- You may override the tool list via chat.bootstrap.tools, but it cannot be disabled.
    bootstrap = {
      strategy = "synthetic_tool_call", -- reserved for future strategies
      -- Bootstrap now always emits only the SymbolIndex table to minimise payload size.
      -- Custom tool lists are allowed, but any non-SymbolIndex entries will be ignored.
      tools = {
        {
          name = "SymbolIndex",
          args = {
            path = ".",
            -- No explicit languages by default: rely on runtime queries per installed parser.
            globs = { "**/*" },
            include_docstrings = true,
            include_ranges = true,
            include_signatures = true,
            max_files = 150,
            max_symbols_per_file = 300,
            fallback_to_text = true,
          },
        },
      },
    },
  },

  presets = {
    groq = {
      api = {
        main = {
          url = "https://api.groq.com/openai/v1/responses",
          api_key = os.getenv("GROQ_API_KEY") or "<your api key>",
          model = "deepseek-r1-distill-llama-70b",
          max_output_tokens = 4096,
        },
        small = {
          url = "https://api.groq.com/openai/v1/responses",
          api_key = os.getenv("GROQ_API_KEY") or "<your api key>",
          model = "llama-3.1-8b-instant", -- example small
          max_output_tokens = 4096,
        },
      },
    },

    openai = {
      api = {
        main = {
          url = "https://api.openai.com/v1/responses",
          api_key = os.getenv("OPENAI_API_KEY"),
          model = "gpt-5.1-codex",
          max_output_tokens = 128000,
          additional_kwargs = {
            temperature = 1,
            reasoning = {
              effort = "medium",
            },
          },
        },
        small = {
          url = "https://api.openai.com/v1/responses",
          api_key = os.getenv("OPENAI_API_KEY"),
          model = "gpt-5-mini",
          max_output_tokens = 128000,
          additional_kwargs = {
            temperature = 1,
            reasoning = {
              effort = "minimal",
            },
          },
        },
      },
    },

    -- Local models (ensure your local gateway supports the Responses API)
    ollama = {
      api = {
        main = {
          url = "http://localhost:11434/v1/responses",
          api_key = "", -- No API key needed for local
          model = "llama3.1:70b",
          max_output_tokens = 4096,
        },
        small = {
          url = "http://localhost:11434/v1/responses",
          api_key = "",
          model = "llama3.2:1b",
          max_output_tokens = 4096,
        },
      },
    },
  },
}

-- Setup function
--- Setup NeoAI configuration with user options
---@param opts Config|nil User-defined configuration options
function config.set_defaults(opts)
  opts = opts or {}

  -- Start with base defaults
  local merged = vim.deepcopy(config.defaults)

  -- Apply preset if specified
  if opts.preset then
    if type(opts.preset) ~= "string" then
      vim.notify("NeoAI: preset must be a string", vim.log.levels.ERROR)
      return
    end

    local preset_config = config.defaults.presets[opts.preset]
    if not preset_config then
      vim.notify(
        "NeoAI: Unknown preset '"
          .. opts.preset
          .. "'. Available presets: "
          .. table.concat(vim.tbl_keys(config.defaults.presets), ", "),
        vim.log.levels.ERROR
      )
      return
    end

    -- Apply preset configuration
    merged = vim.tbl_deep_extend("force", merged, preset_config)
  end

  -- Remove preset from opts to avoid it being merged into final config
  local clean_opts = vim.deepcopy(opts)
  clean_opts.preset = nil

  -- Apply user options (these override preset values)
  config.values = vim.tbl_deep_extend("force", merged, clean_opts)

  -- Validation: require both labelled APIs
  local apis = config.values.api or {}
  local function missing(path)
    vim.notify("NeoAI: Missing required config: " .. path, vim.log.levels.ERROR)
  end

  if type(apis) ~= "table" then
    missing("api")
    return
  end
  if type(apis.main) ~= "table" then
    missing("api.main")
    return
  end
  if type(apis.small) ~= "table" then
    missing("api.small")
    return
  end

  -- Validate keys for both
  for label, a in pairs({ main = apis.main, small = apis.small }) do
    if a.api_key == "<your api key>" then
      vim.notify(
        "NeoAI: Please set your API key for api." .. label .. " or use environment variables",
        vim.log.levels.WARN
      )
    end
    if not a.url or a.url == "" then
      missing("api." .. label .. ".url")
      return
    end
    if not a.model or a.model == "" then
      missing("api." .. label .. ".model")
      return
    end
    a.api_key_header = a.api_key_header or "Authorization"
    a.api_key_format = a.api_key_format or "Bearer %s"

    -- Normalise tokens to max_output_tokens
    if a.max_output_tokens == nil and a.max_completion_tokens ~= nil then
      a.max_output_tokens = a.max_completion_tokens
    end
    a.max_output_tokens = a.max_output_tokens or 4096

    -- Ensure native_tools is a list if provided
    if a.native_tools ~= nil and type(a.native_tools) ~= "table" then
      vim.notify("NeoAI: api." .. label .. ".native_tools must be a table (list)", vim.log.levels.ERROR)
      return
    end
  end

  return config.values
end

-- Helper function to list available presets
function config.list_presets()
  return vim.tbl_keys(config.defaults.presets)
end

-- Helper function to get current config
function config.get()
  return config.values
end

--- Get API config by label ("main" or "small"). Defaults to "main".
---@param which string|nil
---@return APIConfig
function config.get_api(which)
  which = which or "main"
  local apis = (config.values and config.values.api) or {}
  local conf = apis[which]
  if not conf then
    vim.notify("NeoAI: Unknown API label '" .. tostring(which) .. "'", vim.log.levels.ERROR)
    return apis.main or {}
  end
  return conf
end

return config
