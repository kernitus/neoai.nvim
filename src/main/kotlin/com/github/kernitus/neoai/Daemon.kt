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
import ai.koog.prompt.streaming.StreamFrame
import kotlinx.coroutines.*
import org.msgpack.core.MessagePack
import org.msgpack.core.MessagePacker
import org.msgpack.core.MessageUnpacker
import org.msgpack.value.ArrayValue
import org.msgpack.value.ValueType
import java.io.BufferedInputStream
import java.io.BufferedOutputStream

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

                val bodyKey = org.msgpack.value.ValueFactory.newString("body")
                val body = mapData[bodyKey]

                if (body == null) {
                    sendError("Missing 'body' in params", packer)
                    return
                }

                // 2. Launch in background
                scope.launch {
                    try {
                        generate(url, apiKey, model, body, packer)
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

    val userText = extractLastUserText(body) ?: run {
        sendError("Could not extract last user message", packer)
        return
    }

    val baseUrl = url.substringBefore("/v1")
    val settings = OpenAIClientSettings(baseUrl = baseUrl)
    val client = OpenAILLMClient(finalApiKey, settings)

    val params = if (isReasoningModel(modelName)) {
        // Extract reasoning options from body
        var effortStr: String? = null

        if (body.isMapValue) {
            val map = body.asMapValue().map()
            val keyEffort = org.msgpack.value.ValueFactory.newString("reasoning_effort")
            val valEffort = map[keyEffort]
            if (valEffort != null && valEffort.isStringValue) {
                effortStr = valEffort.asStringValue().asString()
            }
        }

        val effort = when (effortStr?.lowercase()) {
            "low" -> ReasoningEffort.LOW
            "high" -> ReasoningEffort.HIGH
            else -> ReasoningEffort.MEDIUM // Default
        }

        OpenAIResponsesParams(
            reasoning = ReasoningConfig(
                effort = effort,
                summary = ReasoningSummary.AUTO
            )
        )
    } else {
        OpenAIResponsesParams()
    }

    val prompt = prompt("neoai", params) {
        system("You are a helpful AI assistant running inside NeoVim.")
        user(userText)
    }

    val model = pickModel(modelName)

    // Execute streaming
    try {
        val stream = client.executeStreaming(prompt = prompt, model = model, tools = emptyList())

        stream.collect { frame ->
            when (frame) {
                is StreamFrame.Append -> {
                    // Check if it's reasoning or content
                    // The API might distinguish, or we might need to check the frame properties if available.
                    // For now, assuming text is content. 
                    // If reasoning is supported, it might come as a different frame type or property.
                    // Looking at the docs: "is StreamFrame.Append -> print(frame.text)"
                    // Let's assume it's content for now.
                    if (frame.text.isNotEmpty()) {
                        sendChunk("content", frame.text, packer)
                    }
                }

                is StreamFrame.End -> {
                    // End of stream
                }

                else -> {
                    // Ignore other frames (ToolCall, etc. for now)
                }
            }
        }
    } catch (e: Exception) {
        sendError("Streaming failed: ${e.message}", packer)
        return
    }

    sendComplete(packer)
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

fun sendComplete(packer: MessagePacker) {
    sendChunk("complete", "", packer)
}

fun sendError(msg: String, packer: MessagePacker) {
    sendChunk("error", msg, packer)
}