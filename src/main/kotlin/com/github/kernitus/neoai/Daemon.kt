package com.github.kernitus.neoai

import ai.koog.prompt.dsl.prompt
import ai.koog.prompt.executor.clients.openai.OpenAIClientSettings
import ai.koog.prompt.executor.clients.openai.OpenAILLMClient
import ai.koog.prompt.executor.clients.openai.OpenAIModels
import ai.koog.prompt.executor.clients.openai.OpenAIResponsesParams
import ai.koog.prompt.executor.clients.openai.base.models.ReasoningEffort
import ai.koog.prompt.executor.clients.openai.models.ReasoningConfig
import ai.koog.prompt.executor.clients.openai.models.ReasoningSummary
import ai.koog.prompt.message.Message
import ai.koog.prompt.message.RequestMetaInfo
import com.github.kernitus.neoai.ai_tools.CustomReadFileTool
import com.github.kernitus.neoai.ai_tools.CustomListDirectoryTool
import com.github.kernitus.neoai.ai_tools.CustomEditFileTool
import ai.koog.prompt.streaming.StreamFrame
import ai.koog.agents.core.tools.ToolRegistry
import ai.koog.agents.core.agent.AIAgent
import ai.koog.agents.core.agent.GraphAIAgent.FeatureContext
import ai.koog.agents.core.dsl.builder.forwardTo
import ai.koog.agents.core.dsl.builder.strategy
import ai.koog.agents.core.dsl.extension.nodeExecuteMultipleTools
import ai.koog.agents.core.dsl.extension.nodeLLMRequestStreamingAndSendResults
import ai.koog.agents.core.dsl.extension.onMultipleToolCalls
import ai.koog.agents.core.environment.ReceivedToolResult
import ai.koog.agents.features.eventHandler.feature.handleEvents
import ai.koog.prompt.executor.llms.all.simpleOpenAIExecutor
import kotlinx.coroutines.*
import ai.koog.rag.base.files.JVMFileSystemProvider
import org.msgpack.core.MessagePack
import org.msgpack.core.MessagePacker
import org.msgpack.core.MessageUnpacker
import org.msgpack.value.ArrayValue
import org.msgpack.value.ValueType
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.HttpURLConnection
import java.net.URL

// Define the scope for background tasks
// Dispatchers.IO is best for network requests; SupervisorJob prevents one crash from killing the whole scope
private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

// Custom GPT‑5.1 model
private val GPT5_1 = OpenAIModels.Chat.GPT5.copy(id = "gpt-5.1")

private fun pickModel(name: String): ai.koog.prompt.llm.LLModel {
    return when (name.lowercase()) {
        "gpt-5.1" -> GPT5_1
        "gpt-5" -> OpenAIModels.Chat.GPT5
        else -> ai.koog.prompt.llm.LLModel(
            provider = ai.koog.prompt.llm.LLMProvider.OpenAI,
            id = name,
            capabilities = OpenAIModels.Chat.GPT5.capabilities,
            contextLength = OpenAIModels.Chat.GPT5.contextLength
        )
    }
}

private fun isReasoningModel(name: String): Boolean {
    val n = name.lowercase()
    return n.startsWith("o1") || n.startsWith("o3") || n.startsWith("gpt-5")
}

private fun extractLastUserText(body: org.msgpack.value.Value): String? {
    if (!body.isMapValue) return null
    val obj = body.asMapValue()

    // Helper to get string from map
    fun getString(map: org.msgpack.value.MapValue, key: String): String? {
        val k = org.msgpack.value.ValueFactory.newString(key)
        val v = map.map()[k] ?: return null
        return if (v.isStringValue) v.asStringValue().asString() else null
    }

    val inputKey = org.msgpack.value.ValueFactory.newString("input")
    val inputVal = obj.map()[inputKey] ?: return null
    if (!inputVal.isArrayValue) return null
    val input = inputVal.asArrayValue()

    for (i in input.size() - 1 downTo 0) {
        val item = input[i]
        if (!item.isMapValue) continue
        val itemMap = item.asMapValue()

        val type = getString(itemMap, "type") ?: continue
        if (type != "message") continue

        val role = getString(itemMap, "role") ?: ""
        if (role != "user") continue

        val contentKey = org.msgpack.value.ValueFactory.newString("content")
        val contentVal = itemMap.map()[contentKey] ?: continue
        if (!contentVal.isArrayValue) continue
        val contents = contentVal.asArrayValue()

        for (c in contents) {
            if (!c.isMapValue) continue
            val cObj = c.asMapValue()
            val cType = getString(cObj, "type")

            if (cType == "input_text" || cType == "text" || cType == "input") {
                val text = getString(cObj, "text")
                if (!text.isNullOrBlank()) return text
            }
        }
    }
    return null
}

private fun formatToolsForPrompt(toolsVal: org.msgpack.value.Value?): String {
    if (toolsVal == null || !toolsVal.isArrayValue) {
        return ""
    }

    val toolsArray = toolsVal.asArrayValue()
    val toolDescriptions = mutableListOf<String>()

    for (i in 0 until toolsArray.size()) {
        val tool = toolsArray[i]
        if (!tool.isMapValue) continue
        val toolMap = tool.asMapValue().map()

        fun getStr(key: String): String? {
            val k = org.msgpack.value.ValueFactory.newString(key)
            val v = toolMap[k]
            return if (v != null && v.isStringValue) v.asStringValue().asString() else null
        }

        val type = getStr("type")
        if (type != "function") continue

        val funcKey = org.msgpack.value.ValueFactory.newString("function")
        val funcVal = toolMap[funcKey]
        if (funcVal == null || !funcVal.isMapValue) continue

        val funcMap = funcVal.asMapValue().map()
        fun getFuncStr(key: String): String? {
            val k = org.msgpack.value.ValueFactory.newString(key)
            val v = funcMap[k]
            return if (v != null && v.isStringValue) v.asStringValue().asString() else null
        }

        val name = getFuncStr("name") ?: continue
        val description = getFuncStr("description") ?: ""

        toolDescriptions.add("- **$name**: $description")
    }

    return if (toolDescriptions.isEmpty()) {
        "No tools available."
    } else {
        toolDescriptions.joinToString("\n")
    }
}

// --- Strategy for Streaming with Tools ---

private fun streamingWithToolsStrategy() = strategy<List<Message.Request>, String>("streaming_loop") {
    val executeMultipleTools by nodeExecuteMultipleTools(parallelTools = true)
    val nodeStreaming by nodeLLMRequestStreamingAndSendResults<List<Message.Request>>()

    val applyRequestToSession by node<List<Message.Request>, List<Message.Request>> { input ->
        llm.writeSession {
            appendPrompt {
                input.filterIsInstance<Message.User>()
                    .forEach {
                        user(it.content)
                    }

                tool {
                    input.filterIsInstance<Message.Tool.Result>()
                        .forEach {
                            result(it)
                        }
                }
            }
            input
        }
    }

    val mapToolCallsToRequests by node<List<ReceivedToolResult>, List<Message.Request>> { input ->
        input.map { it.toMessage() }
    }

    // Define edges
    edge(nodeStart forwardTo applyRequestToSession)
    edge(applyRequestToSession forwardTo nodeStreaming)
    edge(nodeStreaming forwardTo executeMultipleTools onMultipleToolCalls { true })
    edge(executeMultipleTools forwardTo mapToolCallsToRequests)
    edge(mapToolCallsToRequests forwardTo applyRequestToSession)
    edge(
        nodeStreaming forwardTo nodeFinish onCondition {
            it.filterIsInstance<Message.Tool.Call>().isEmpty()
        } transformed {
            // Extract assistant message content
            it.filterIsInstance<Message.Assistant>()
                .firstOrNull()?.content ?: ""
        }
    )
}

// --- Main ---

fun main() = runBlocking {
    val inputStream = BufferedInputStream(System.`in`)
    val outputStream = BufferedOutputStream(System.out)

    val unpacker = MessagePack.newDefaultUnpacker(inputStream)
    val packer = MessagePack.newDefaultPacker(outputStream)

    while (isActive) {
        try {
            if (!unpacker.hasNext()) {
                break
            }

            // Read the next value, expected to be an array
            val value = unpacker.unpackValue()
            if (!value.isArrayValue) {
                continue
            }

            val array = value.asArrayValue()
            if (array.size() < 3) {
                continue
            }

            val type = array[0].asIntegerValue().toInt()

            if (type == 0) { // Request: [0, msgid, method, params]
                if (array.size() < 4) continue
                val msgId = array[1].asIntegerValue().toInt()
                val method = array[2].asStringValue().asString()
                val paramsArray = array[3].asArrayValue()

                handleMethod(method, paramsArray, packer)

            } else if (type == 2) { // Notification: [2, method, params]
                val method = array[1].asStringValue().asString()
                val paramsArray = array[2].asArrayValue()

                handleMethod(method, paramsArray, packer)
            }

        } catch (e: Exception) {
            System.err.println("Error in main loop: ${e.message}")
            break
        }
    }

    // Cleanup when main loop exits
    scope.cancel()
}

fun handleMethod(method: String, paramsArray: ArrayValue, packer: MessagePacker) {
    if (method == "generate") {
        // params is [ { ... } ]
        if (paramsArray.size() > 0) {
            val paramValue = paramsArray[0].toString()

            try {
                // Decode manually from the MapValue
                val paramValue = paramsArray[0]
                if (!paramValue.isMapValue) {
                    sendError("Params must be a map", packer)
                    return
                }
                val map = paramValue.asMapValue()
                val mapData = map.map()

                // Helper to extract strings safely
                fun getStr(key: String, default: String = ""): String {
                    val k = org.msgpack.value.ValueFactory.newString(key)
                    val v = mapData[k]
                    return if (v != null && v.isStringValue) v.asStringValue().asString() else default
                }

                val url = getStr("url")
                val apiKey = getStr("api_key")
                val model = getStr("model")
                val cwd = getStr("cwd", System.getProperty("user.dir") ?: ".")

                val bodyKey = org.msgpack.value.ValueFactory.newString("body")
                val body = mapData[bodyKey]

                if (body == null) {
                    sendError("Missing 'body' in params", packer)
                    return
                }

                // 2. Launch in background
                scope.launch {
                    try {
                        generate(url, apiKey, model, body, cwd, packer)
                    } catch (e: Exception) {
                        // 3. Handle generation errors inside the coroutine
                        sendError("Generation failed: ${e.message}", packer)
                    }
                }
            } catch (e: Exception) {
                // Handle parsing errors
                sendError("Invalid params: ${e.message}", packer)
            }
        }
    } else {
        // Ignore unknown methods
    }
}

// --- Generation Logic ---

suspend fun generate(
    url: String,
    apiKey: String,
    modelName: String,
    body: org.msgpack.value.Value,
    cwd: String,
    packer: MessagePacker
) {
    // Prefer envelope API key; otherwise fall back to OPENAI_API_KEY.
    val finalApiKey = apiKey.ifBlank {
        System.getenv("OPENAI_API_KEY") ?: ""
    }

    if (finalApiKey.isBlank()) {
        sendError("No API key provided", packer)
        return
    }

    if (!body.isMapValue) {
        sendError("Body must be a map/object", packer)
        return
    }

    val bodyMap = body.asMapValue().map()

    // Helper to get value from map
    fun getValue(key: String): org.msgpack.value.Value? {
        val k = org.msgpack.value.ValueFactory.newString(key)
        return bodyMap[k]
    }

    // Extract input (array of messages)
    val inputVal = getValue("input")
    if (inputVal == null || !inputVal.isArrayValue) {
        sendError("Missing or invalid 'input' field", packer)
        return
    }

    // Extract tools array (for system prompt template)
    val toolsVal = getValue("tools")

    // Read system prompt from file
    val systemPromptFile = java.io.File("lua/neoai/prompts/system_prompt.md")
    val systemPrompt = if (systemPromptFile.exists()) {
        val content = systemPromptFile.readText()
        // Replace template variables
        val toolsFormatted = formatToolsForPrompt(toolsVal)
        content
            .replace("%tools", toolsFormatted)
            .replace("%agents", "") // TODO: Read AGENTS.md if exists
    } else {
        "You are a helpful AI assistant running inside NeoVim."
    }

    // Convert msgpack input to Koog Message.Request format
    val messages = mutableListOf<Message.Request>()
    val inputArray = inputVal.asArrayValue()
    for (i in 0 until inputArray.size()) {
        val item = inputArray[i]
        if (!item.isMapValue) continue
        val itemMap = item.asMapValue().map()

        fun getItemString(key: String): String? {
            val k = org.msgpack.value.ValueFactory.newString(key)
            val v = itemMap[k] ?: return null
            return if (v.isStringValue) v.asStringValue().asString() else null
        }

        val type = getItemString("type") ?: continue
        if (type != "message") continue

        val role = getItemString("role") ?: continue

        // Extract content from the message
        val contentKey = org.msgpack.value.ValueFactory.newString("content")
        val contentVal = itemMap[contentKey]
        if (contentVal == null || !contentVal.isArrayValue) continue

        val contentParts = mutableListOf<String>()
        val contents = contentVal.asArrayValue()
        for (c in contents) {
            if (!c.isMapValue) continue
            val cObj = c.asMapValue().map()

            fun getContentString(key: String): String? {
                val k = org.msgpack.value.ValueFactory.newString(key)
                val v = cObj[k] ?: return null
                return if (v.isStringValue) v.asStringValue().asString() else null
            }

            val cType = getContentString("type")
            val text = getContentString("text")

            if ((cType == "input_text" || cType == "output_text" || cType == "text") && !text.isNullOrBlank()) {
                contentParts.add(text)
            }
        }

        val fullContent = contentParts.joinToString("\n")
        if (fullContent.isBlank()) continue

        // Only add user messages to the request list
        // Assistant messages come from LLM responses, not manual creation
        if (role == "user") {
            messages.add(Message.User(content = fullContent, metaInfo = RequestMetaInfo.Empty))
        }
    }

    if (messages.isEmpty()) {
        sendError("No valid messages in input", packer)
        return
    }

    // Create tool registry with custom path-resolving file tools
    val toolRegistry = ToolRegistry {
        tool(CustomReadFileTool(JVMFileSystemProvider.ReadOnly, cwd))
        tool(CustomListDirectoryTool<java.nio.file.Path>(cwd)) // Uses ripgrep, doesn't need FS provider
        tool(CustomEditFileTool(JVMFileSystemProvider.ReadWrite, cwd))
    }

    // Pick model
    val model = pickModel(modelName)

    // Create agent with event handlers for RPC integration
    val agent = AIAgent(
        promptExecutor = simpleOpenAIExecutor(finalApiKey),
        strategy = streamingWithToolsStrategy(),
        llmModel = model,
        systemPrompt = systemPrompt,
        toolRegistry = toolRegistry,
        installFeatures = {
            handleEvents {
                onLLMStreamingFrameReceived { context ->
                    val frame = context.streamFrame
                    when (frame) {
                        is StreamFrame.Append -> {
                            if (frame.text.isNotEmpty()) {
                                sendChunk("content", frame.text, packer)
                            }
                        }

                        is StreamFrame.ToolCall -> {
                            // Tool call streaming - send to Lua
                            sendToolCall(frame.id, frame.name, frame.content, packer)
                        }

                        is StreamFrame.End -> {
                            // End of stream chunk
                        }
                    }
                }

                onLLMStreamingCompleted {
                    // Stream completed successfully
                }

                onLLMStreamingFailed { context ->
                    sendError("Streaming failed: ${context.error.message}", packer)
                }
            }
        }
    )

    // Run the agent
    try {
        agent.run(messages)
        sendComplete(packer)
    } catch (e: Exception) {
        sendError("Agent execution failed: ${e.message}", packer)
    }
}

// --- RPC Sending Helpers ---

fun sendChunk(type: String, data: String, packer: MessagePacker) {
    synchronized(packer) {
        // Notification: [2, "nvim_exec_lua", ["NeoAI_OnChunk(...)", [{type:..., data:...}]]]

        packer.packArrayHeader(3)
        packer.packInt(2) // Notification type
        packer.packString("nvim_exec_lua")

        packer.packArrayHeader(2) // [code, args]
        packer.packString("NeoAI_OnChunk(...)")

        packer.packArrayHeader(1) // args array (1 arg)

        // The arg is a map/struct: {type: "content", data: "..."}
        // We can pack it as a map.
        packer.packMapHeader(2)
        packer.packString("type")
        packer.packString(type)
        packer.packString("data")
        packer.packString(data)

        packer.flush()
    }
}

fun sendToolCall(id: String?, name: String, arguments: String, packer: MessagePacker) {
    synchronized(packer) {
        // Notification: [2, "nvim_exec_lua", ["NeoAI_OnChunk(...)", [{type:"tool_call", data:{id:..., name:..., arguments:...}}]]]

        packer.packArrayHeader(3)
        packer.packInt(2) // Notification type
        packer.packString("nvim_exec_lua")

        packer.packArrayHeader(2) // [code, args]
        packer.packString("NeoAI_OnChunk(...)")

        packer.packArrayHeader(1) // args array (1 arg)

        // The arg is a map: {type: "tool_call", data: {id, name, arguments}}
        packer.packMapHeader(2)
        packer.packString("type")
        packer.packString("tool_call")
        packer.packString("data")

        // Nested map for tool call data
        packer.packMapHeader(3)
        packer.packString("id")
        if (id != null) {
            packer.packString(id)
        } else {
            packer.packNil()
        }
        packer.packString("name")
        packer.packString(name)
        packer.packString("arguments")
        packer.packString(arguments)

        packer.flush()
    }
}

fun sendComplete(packer: MessagePacker) {
    sendChunk("complete", "", packer)
}

fun sendError(msg: String, packer: MessagePacker) {
    sendChunk("error", msg, packer)
}