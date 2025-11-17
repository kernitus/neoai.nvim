package com.github.kernitus.neoai

import ai.koog.prompt.executor.clients.openai.OpenAIResponsesParams
import ai.koog.prompt.executor.clients.openai.models.ReasoningConfig
import ai.koog.prompt.executor.clients.openai.models.ReasoningSummary
import ai.koog.prompt.executor.clients.openai.base.models.ReasoningEffort


import ai.koog.prompt.dsl.prompt
import ai.koog.prompt.executor.clients.openai.OpenAIClientSettings
import ai.koog.prompt.executor.clients.openai.OpenAILLMClient
import ai.koog.prompt.executor.clients.openai.OpenAIModels
import ai.koog.prompt.message.Message
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable
data class Envelope(
    val url: String,
    @SerialName("api_key") val apiKey: String,
    @SerialName("api_key_header") val apiKeyHeader: String = "Authorization",
    @SerialName("api_key_format") val apiKeyFormat: String = "Bearer %s",
    val model: String,
    val body: JsonElement
)

private val json = Json { ignoreUnknownKeys = true }

/**
 * Extract the text of the last user message from a Responses-style payload:
 * body.input is an array of items; we want the last item with
 *   type == "message", role == "user"
 * then the first content element with type == "input_text".
 */
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
                if (!text.isNullOrBlank()) {
                    return text
                }
            }
        }
    }
    return null
}

// Custom GPT‑5.1 model: reuse GPT‑5 capabilities but send id "gpt-5.1".
private val GPT5_1 = OpenAIModels.Chat.GPT5.copy(id = "gpt-5.1")

private fun pickModel(name: String): ai.koog.prompt.llm.LLModel {
    return when (name.lowercase()) {
        "gpt-5.1" -> GPT5_1
        "gpt-5" -> OpenAIModels.Chat.GPT5
        else -> GPT5_1
    }
}

fun main() = runBlocking {
    val stdin = generateSequence(::readLine).joinToString("\n").trim()
    if (stdin.isEmpty()) {
        println("""{"kind":"error","message":"Empty stdin (no envelope received)"}""")
        return@runBlocking
    }

    val env = try {
        json.decodeFromString<Envelope>(stdin)
    } catch (e: Exception) {
        val msg = e.message ?: e.toString()
        val msgJson = json.encodeToString(msg)
        println("""{"kind":"error","message":$msgJson}""")
        return@runBlocking
    }

    // Prefer envelope API key; otherwise fall back to OPENAI_API_KEY.
    val apiKey = if (env.apiKey.isNotBlank()) {
        env.apiKey
    } else {
        System.getenv("OPENAI_API_KEY") ?: run {
            val msg = "No API key provided (api_key empty and OPENAI_API_KEY not set)"
            val msgJson = json.encodeToString(msg)
            println("""{"kind":"error","message":$msgJson}""")
            return@runBlocking
        }
    }

    val userText = extractLastUserText(env.body) ?: run {
        val msg = "Could not extract last user message from payload"
        val msgJson = json.encodeToString(msg)
        println("""{"kind":"error","message":$msgJson}""")
        return@runBlocking
    }

    try {
        // Configure client; allow overriding base URL from envelope if needed.
        val baseUrl = env.url.substringBefore("/v1")  // e.g. https://api.openai.com
        val settings = OpenAIClientSettings(baseUrl = baseUrl)
        val client = OpenAILLMClient(apiKey, settings)

        // LLMParams with reasoning effort; Koog will map this to Responses API ReasoningConfig.
        val params = OpenAIResponsesParams(
            reasoning = ReasoningConfig(
                effort = ReasoningEffort.HIGH,
                summary = ReasoningSummary.AUTO
            )
        )


        // Build a simple prompt: you can refine the system message as needed.
        val prompt = prompt("neoai", params) {
            system("You are a helpful AI assistant running inside NeoVim.")
            user(userText)
        }

        val model = pickModel(env.model)

        // Non-streaming call using OpenAI Responses API under the hood.
        val responses: List<Message.Response> = client.execute(
            prompt = prompt,
            model = model,
            tools = emptyList()
        )

        // Map Koog responses to our simple chunk protocol.
        for (resp in responses) {
            when (resp) {
                is Message.Reasoning -> {
                    val text = resp.content
                    if (text.isNotBlank()) {
                        val dataJson = json.encodeToString(text)
                        println("""{"kind":"chunk","type":"reasoning","data":$dataJson}""")
                    }
                }

                is Message.Assistant -> {
                    val text = resp.content
                    if (text.isNotBlank()) {
                        val dataJson = json.encodeToString(text)
                        println("""{"kind":"chunk","type":"content","data":$dataJson}""")
                    }
                }

                is Message.Tool.Call -> {
                    // Optional: map tool calls to 'tool_calls' chunks later.
                }
            }
        }

        println("""{"kind":"complete"}""")
    } catch (e: Exception) {
        val msg = e.message ?: e.toString()
        val msgJson = json.encodeToString(msg)
        println("""{"kind":"error","message":$msgJson}""")
    }
}

