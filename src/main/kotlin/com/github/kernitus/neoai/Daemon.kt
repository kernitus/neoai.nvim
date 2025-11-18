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
import kotlinx.coroutines.*
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import org.msgpack.core.MessagePack
import org.msgpack.core.MessagePacker
import org.msgpack.core.MessageUnpacker
import org.msgpack.value.ArrayValue
import org.msgpack.value.ValueType
import java.io.BufferedInputStream
import java.io.BufferedOutputStream

// --- Data Models ---

@Serializable
data class GenerateParams(
    val url: String,
    @SerialName("api_key") val apiKey: String,
    @SerialName("api_key_header") val apiKeyHeader: String = "Authorization",
    @SerialName("api_key_format") val apiKeyFormat: String = "Bearer %s",
    val model: String,
    val body: JsonElement
)

// --- Helpers ---

private val json = Json { ignoreUnknownKeys = true }

// Custom GPT‑5.1 model
private val GPT5_1 = OpenAIModels.Chat.GPT5.copy(id = "gpt-5.1")

private fun pickModel(name: String): ai.koog.prompt.llm.LLModel {
    return when (name.lowercase()) {
        "gpt-5.1" -> GPT5_1
        "gpt-5" -> OpenAIModels.Chat.GPT5
        else -> GPT5_1
    }
}

private fun extractLastUserText(body: JsonElement): String? {
    val obj = body as? JsonObject ?: return null
    val input = obj["input"] as? JsonArray ?: return null
    for (i in input.size - 1 downTo 0) {
        val item = input[i] as? JsonObject ?: continue
        val type = item["type"]?.jsonPrimitive?.contentOrNull ?: continue
        if (type != "message") continue
        val role = item["role"]?.jsonPrimitive?.contentOrNull ?: ""
        if (role != "user") continue
        val contents = item["content"] as? JsonArray ?: continue
        for (c in contents) {
            val cObj = c as? JsonObject ?: continue
            val cType = cObj["type"]?.jsonPrimitive?.contentOrNull
            if (cType == "input_text" || cType == "text" || cType == "input") {
                val text = cObj["text"]?.jsonPrimitive?.contentOrNull
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
}

fun handleMethod(method: String, paramsArray: ArrayValue, packer: MessagePacker) {
    if (method == "generate") {
        // params is [ { ... } ]
        if (paramsArray.size() > 0) {
            val paramValue = paramsArray[0].toString() 
            
            try {
                val generateParams = json.decodeFromString<GenerateParams>(paramValue)
                // Launch in background
                GlobalScope.launch {
                    generate(generateParams, packer)
                }
            } catch (e: Exception) {
                sendError("Invalid params: ${e.message}", packer)
            }
        }
    } else {
        // Ignore unknown methods
    }
}

// --- Generation Logic ---

suspend fun generate(env: GenerateParams, packer: MessagePacker) {
    try {
        // Prefer envelope API key; otherwise fall back to OPENAI_API_KEY.
        val apiKey = if (env.apiKey.isNotBlank()) {
            env.apiKey
        } else {
            System.getenv("OPENAI_API_KEY") ?: ""
        }

        if (apiKey.isBlank()) {
            sendError("No API key provided", packer)
            return
        }

        val userText = extractLastUserText(env.body) ?: run {
            sendError("Could not extract last user message", packer)
            return
        }

        val baseUrl = env.url.substringBefore("/v1")
        val settings = OpenAIClientSettings(baseUrl = baseUrl)
        val client = OpenAILLMClient(apiKey, settings)

        val params = OpenAIResponsesParams(
            reasoning = ReasoningConfig(
                effort = ReasoningEffort.HIGH,
                summary = ReasoningSummary.AUTO
            )
        )

        val prompt = prompt("neoai", params) {
            system("You are a helpful AI assistant running inside NeoVim.")
            user(userText)
        }

        val model = pickModel(env.model)

        // Execute (blocking for now to fix build)
        val responses = client.execute(prompt = prompt, model = model, tools = emptyList())

        for (resp in responses) {
             when (resp) {
                is Message.Reasoning -> {
                    if (resp.content.isNotBlank()) {
                        sendChunk("reasoning", resp.content, packer)
                    }
                }
                is Message.Assistant -> {
                    if (resp.content.isNotBlank()) {
                        sendChunk("content", resp.content, packer)
                    }
                }
                else -> {}
            }
        }
        
        sendComplete(packer)

    } catch (e: Exception) {
        sendError(e.message ?: "Unknown error", packer)
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

fun sendComplete(packer: MessagePacker) {
    sendChunk("complete", "", packer)
}

fun sendError(msg: String, packer: MessagePacker) {
    sendChunk("error", msg, packer)
}
