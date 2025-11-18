local jar_path = vim.fn.getcwd() .. "/build/libs/neoai-daemon-all.jar"
local java_bin = "/usr/lib/jvm/java-25-openjdk/bin/java"
local cmd = { java_bin, "-jar", jar_path }

print("Starting daemon from: " .. jar_path)

_G.NeoAI_OnChunk = function(chunk_data)
  print("Received chunk: " .. vim.inspect(chunk_data))
  if chunk_data[1] and chunk_data[1].type == "complete" then
    print("Received COMPLETE signal. Exiting.")
    vim.cmd("quit")
  elseif chunk_data[1] and chunk_data[1].type == "error" then
    print("Received ERROR signal. Exiting.")
    vim.cmd("quit")
  end
end

local job_id = vim.fn.jobstart(cmd, {
  rpc = true,
  on_stderr = function(_, data)
    if data then
      for _, line in ipairs(data) do
        if line ~= "" then print("DAEMON STDERR: " .. line) end
      end
    end
  end,
  on_exit = function(_, code)
    print("Daemon exited with code: " .. code)
  end
})

if job_id <= 0 then
  print("Failed to start daemon! Job ID: " .. job_id)
  vim.cmd("quit")
end

print("Daemon started with Job ID: " .. job_id)

-- Wait for daemon to initialize
vim.wait(2000, function() return false end)

local params = {
  url = "https://api.openai.com/v1",
  api_key = os.getenv("OPENAI_API_KEY") or "sk-test-key", 
  model = "gpt-4o",
  body = {
    input = {
      {
        type = "message",
        role = "user",
        content = {
          { type = "text", text = "Hello, are you working?" }
        }
      }
    }
  }
}

print("Sending 'generate' request...")
-- We wrap params in a list because the daemon expects [params_object] as arguments
vim.rpcnotify(job_id, "generate", params)

print("Waiting for response...")
-- Wait up to 10 seconds
vim.wait(10000, function() return false end)

print("Test timed out.")
vim.cmd("quit")
