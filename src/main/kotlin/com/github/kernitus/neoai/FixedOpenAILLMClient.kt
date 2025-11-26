package com.github.kernitus.neoai

import ai.koog.agents.core.tools.ToolDescriptor
import ai.koog.prompt.dsl.Prompt
import ai.koog.prompt.executor.clients.openai.OpenAIClientSettings
import ai.koog.prompt.executor.clients.openai.OpenAILLMClient
import ai.koog.prompt.executor.clients.openai.OpenAIResponsesParams
import ai.koog.prompt.llm.LLModel
import ai.koog.prompt.message.Message
import ai.koog.prompt.message.ResponseMetaInfo
import ai.koog.prompt.params.LLMParams
import ai.koog.prompt.streaming.StreamFrame
import io.ktor.client.HttpClient
import io.ktor.client.plugins.DefaultRequest
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.utils.io.readUTF8Line
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

class FixedOpenAILLMClient(
    apiKey: String,
    private val settings: OpenAIClientSettings,
    private val responseJson: Json =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = false
        },
) : OpenAILLMClient(apiKey, settings) {
    private val myHttpClient =
        HttpClient {
            install(ContentNegotiation)
            install(DefaultRequest) {
                headers.append("Authorization", "Bearer $apiKey")
            }
        }

    override fun executeStreaming(
        prompt: Prompt,
        model: LLModel,
        tools: List<ToolDescriptor>,
    ): Flow<StreamFrame> {
        val params = prompt.params

        if (params !is OpenAIResponsesParams) {
            return super.executeStreaming(prompt, model, tools)
        }

        return flow {
            // ... 1. Map Tools (Same as before) ...
            val apiTools =
                tools.map { tool ->
                    FixedTool(
                        type = "function",
                        name = tool.name,
                        description = tool.description,
                        parameters = tool.paramsToJsonObject(),
                    )
                }

            // ... 2. Map Messages (Same as before) ...
            val inputItems: List<FixedItem> =
                prompt.messages.mapNotNull { msg ->
                    when (msg) {
                        is Message.System -> {
                            FixedItem(
                                type = "message",
                                role = "developer",
                                content = listOf(FixedContent(type = "input_text", text = msg.content)),
                            )
                        }

                        is Message.User -> {
                            FixedItem(
                                type = "message",
                                role = "user",
                                content = listOf(FixedContent(type = "input_text", text = msg.content)),
                            )
                        }

                        is Message.Assistant -> {
                            FixedItem(
                                type = "message",
                                role = "assistant",
                                content = listOf(FixedContent(type = "output_text", text = msg.content)),
                            )
                        }

                        is Message.Tool.Result -> {
                            FixedItem(
                                type = "function_call_output",
                                callId = msg.id,
                                output = msg.content,
                            )
                        }

                        is Message.Tool.Call -> {
                            FixedItem(
                                type = "function_call",
                                callId = msg.id,
                                name = msg.tool,
                                arguments = msg.content,
                            )
                        }

                        else -> {
                            null
                        }
                    }
                }

                        val request = FixedRequest(
                model = model.id,
                input = inputItems,
                tools = apiTools,
                stream = true,
                toolChoice = "auto",
                maxOutputTokens = params.maxTokens,
                reasoning = params.reasoning?.let {
                    FixedReasoning(
                        effort = it.effort?.name?.lowercase() ?: "medium",
                        summary = "auto" 
                    )
                }
            )

            val requestBody = responseJson.encodeToString(request)

            // LOG REQUEST
            DebugLogger.log(">>> REQUEST: $requestBody")

            // 4. Execute Request
            var urlStr = settings.baseUrl.trimEnd('/')
            if (!urlStr.endsWith("/responses") && !urlStr.contains("responses")) {
                urlStr = "$urlStr/responses"
            }

            myHttpClient
                .preparePost {
                    url(urlStr)
                    contentType(ContentType.Application.Json)
                    setBody(requestBody)
                }.execute { response ->
                    if (response.status.value != 200) {
                        val err = response.bodyAsText()
                        DebugLogger.log("!!! HTTP ERROR: ${response.status} - $err")
                        throw Exception("HTTP ${response.status}: $err")
                    }

                    val channel = response.bodyAsChannel()
                    while (!channel.isClosedForRead) {
                        val line = channel.readUTF8Line() ?: break

                        if (line.startsWith("data: ")) {
                            val data = line.removePrefix("data: ").trim()
                            if (data != "[DONE]") {
                                try {
                                    // LOG RAW EVENT
                                    DebugLogger.log("<<< EVENT: $data")

                                    val event = responseJson.decodeFromString<FixedStreamEvent>(data)

                                    when (event.type) {
                                        "response.output_text.delta" -> {
                                            if (event.delta != null) {
                                                emit(StreamFrame.Append(event.delta))
                                            }
                                        }

                                        "response.output_item.done" -> {
                                            val item = event.item
                                            if (item != null && item.type == "function_call") {
                                                DebugLogger.log("<<< TOOL CALL DETECTED: ${item.name}")
                                                emit(
                                                    StreamFrame.ToolCall(
                                                        id = item.callId ?: "",
                                                        name = item.name ?: "",
                                                        content = item.arguments ?: "",
                                                    ),
                                                )
                                            }
                                        }

                                        "response.completed" -> {
                                            emit(StreamFrame.End(null, ResponseMetaInfo.Empty))
                                        }
                                    }
                                } catch (e: Exception) {
                                    DebugLogger.log("!!! PARSE ERROR: ${e.message}")
                                }
                            }
                        }
                    }
                }
        }
    }

    // --- DTOs ---

    @Serializable
    private data class FixedRequest(
        val model: String,
        val input: List<FixedItem>,
        val tools: List<FixedTool>,
        val stream: Boolean,
        @SerialName("tool_choice") val toolChoice: String? = null,
        @SerialName("max_output_tokens") val maxOutputTokens: Int? = null,
        val reasoning: FixedReasoning? = null,
    )

    @Serializable
private data class FixedReasoning(
    val effort: String,
    val summary: String? = null // Add this field
)

    @Serializable
    private data class FixedItem(
        val type: String,
        val role: String? = null,
        val content: List<FixedContent>? = null,
        @SerialName("call_id") val callId: String? = null,
        val output: String? = null,
        val name: String? = null,
        val arguments: String? = null,
    )

    @Serializable
    private data class FixedContent(
        val type: String,
        val text: String? = null,
    )

    @Serializable
    private data class FixedTool(
        val type: String,
        val name: String,
        val description: String?,
        val parameters: JsonObject,
    )

    @Serializable
    private data class FixedStreamEvent(
        val type: String,
        val delta: String? = null,
        val item: FixedItem? = null,
    )
}
