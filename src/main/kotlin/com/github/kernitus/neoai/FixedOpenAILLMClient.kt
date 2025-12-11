package com.github.kernitus.neoai

import ai.koog.agents.core.tools.ToolDescriptor
import ai.koog.prompt.dsl.Prompt
import ai.koog.prompt.executor.clients.openai.OpenAIClientSettings
import ai.koog.prompt.executor.clients.openai.OpenAILLMClient
import ai.koog.prompt.executor.clients.openai.OpenAIResponsesParams
import ai.koog.prompt.executor.clients.openai.base.models.ReasoningEffort
import ai.koog.prompt.executor.clients.openai.models.ReasoningSummary
import ai.koog.prompt.llm.LLModel
import ai.koog.prompt.message.Message
import ai.koog.prompt.message.ResponseMetaInfo
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
    private val baseClient: HttpClient? = null,
    private val responseJson: Json =
        Json {
            ignoreUnknownKeys = true
            encodeDefaults = false
        },
) : OpenAILLMClient(apiKey, settings) {
    // Uses the shared baseClient if available to prevent resource leaks
    private val myHttpClient =
        baseClient?.config {
            install(ContentNegotiation)
            install(DefaultRequest) {
                headers.append("Authorization", "Bearer $apiKey")
            }
        }
            ?: HttpClient {
                install(ContentNegotiation)
                install(DefaultRequest) {
                    headers.append("Authorization", "Bearer $apiKey")
                }
            }

    // Track mapping between ephemeral item_id and stable call_id
    private val itemIdToCallId = java.util.concurrent.ConcurrentHashMap<String, String>()

    override fun executeStreaming(
        prompt: Prompt,
        model: LLModel,
        tools: List<ToolDescriptor>,
    ): Flow<StreamFrame> {
        val params = prompt.params

        if (params !is OpenAIResponsesParams) {
            return super.executeStreaming(prompt, model, tools)
        }

        var reasoningSummaryStreamed = false

        return flow {
            val apiTools =
                tools.map { tool ->
                    FixedTool(
                        type = "function",
                        name = tool.name,
                        description = tool.description,
                        parameters = tool.paramsToJsonObject(),
                    )
                }

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

                        is Message.Reasoning -> {
                            FixedItem(
                                type = "reasoning",
                                id = msg.id,
                                encrypted = msg.encrypted,
                                summary =
                                    if (msg.content.isNotBlank()) {
                                        listOf(FixedSummaryPart(type = "summary_text", text = msg.content))
                                    } else {
                                        null
                                    },
                            )
                        }
                    }
                }

            val request =
                FixedRequest(
                    model = model.id,
                    input = inputItems,
                    tools = apiTools,
                    stream = true,
                    toolChoice = "auto",
                    maxOutputTokens = params.maxTokens,
                    reasoning =
                        params.reasoning?.let {
                            FixedReasoning(
                                effort =
                                    it.effort?.name?.uppercase()?.let { effortName ->
                                        ReasoningEffort.entries.find { enumValue -> enumValue.name == effortName }
                                    } ?: ReasoningEffort.MEDIUM,
                                summary = ReasoningSummary.AUTO,
                            )
                        },
                    store = false,
                    include = listOf("reasoning.encrypted_content"),
                )

            val requestBody = responseJson.encodeToString(request)

            var urlStr = settings.baseUrl.trimEnd('/')
            if (!urlStr.endsWith("/responses") && "responses" !in urlStr) {
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
                                    // Log raw event for debugging
                                    DebugLogger.log("<<< EVENT: $data")

                                    val event = responseJson.decodeFromString<FixedStreamEvent>(data)

                                    when (event.type) {
                                        "response.output_text.delta" -> {
                                            if (event.delta != null) {
                                                emit(StreamFrame.Append(event.delta))
                                            }
                                        }

                                        "response.reasoning_summary_text.delta" -> {
                                            if (event.delta != null) {
                                                reasoningSummaryStreamed = true
                                                // Tunnel reasoning through a special prefix
                                                emit(StreamFrame.Append("|||REASONING|||${event.delta}"))
                                            }
                                        }

                                        "response.output_item.added" -> {
                                            val item = event.item
                                            // Map item.id to call_id for tool calls so we can track progress later
                                            if (item?.id != null && item.callId != null) {
                                                itemIdToCallId[item.id] = item.callId
                                            }
                                        }

                                        "response.function_call_arguments.delta" -> {
                                            val itemId = event.itemId
                                            val delta = event.delta
                                            if (itemId != null && delta != null) {
                                                val callId = itemIdToCallId[itemId] ?: "unknown"
                                                val bytes = delta.length
                                                // Emit progress heartbeat: |||TOOL_PROGRESS|||call_id|bytes
                                                emit(StreamFrame.Append("|||TOOL_PROGRESS|||$callId|$bytes"))
                                            }
                                        }

                                        "response.function_call_arguments.done" -> {
                                            val itemId = event.itemId
                                            if (itemId != null) {
                                                val callId = itemIdToCallId[itemId] ?: "unknown"
                                                // Tunnel a lightweight 'tool done' marker to the UI.
                                                emit(StreamFrame.Append("|||TOOL_DONE|||$callId"))
                                            }
                                        }

                                        "response.output_item.done" -> {
                                            val item = event.item
                                            if (item != null) {
                                                when (item.type) {
                                                    "reasoning" -> {
                                                        DebugLogger.log("<<< REASONING ITEM RECEIVED (id=${item.id})")
                                                        // Tunnel the encrypted reasoning through Append with a new prefix
                                                        val encryptedContent = item.encrypted ?: ""
                                                        val summary = item.summary?.joinToString("\n") { it.text ?: "" } ?: ""

                                                        // Format: |||REASONING_ITEM|||id|encrypted|summary
                                                        emit(
                                                            StreamFrame.Append(
                                                                "|||REASONING_ITEM|||${item.id}|$encryptedContent|$summary",
                                                            ),
                                                        )
                                                    }

                                                    "function_call" -> {
                                                        DebugLogger.log("<<< TOOL CALL COMPLETE: ${item.name}")
                                                        emit(
                                                            StreamFrame.ToolCall(
                                                                id = item.callId ?: "",
                                                                name = item.name ?: "",
                                                                content = item.arguments ?: "",
                                                            ),
                                                        )
                                                    }
                                                }
                                            }
                                        }

                                        "response.completed" -> {
                                            if (!reasoningSummaryStreamed) {
                                                val fullSummary =
                                                    event.response
                                                        ?.output
                                                        ?.firstOrNull { it.type == "reasoning" }
                                                        ?.summary
                                                        ?.joinToString(separator = "") { it.text.orEmpty() }

                                                if (!fullSummary.isNullOrBlank()) {
                                                    emit(StreamFrame.Append("|||REASONING_FULL|||$fullSummary"))
                                                }
                                            }
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

    @Serializable
    private data class FixedRequest(
        val model: String,
        val input: List<FixedItem>,
        val tools: List<FixedTool>,
        val stream: Boolean,
        @SerialName("tool_choice") val toolChoice: String? = null,
        @SerialName("max_output_tokens") val maxOutputTokens: Int? = null,
        val reasoning: FixedReasoning? = null,
        val store: Boolean = false,
        val include: List<String>? = null,
    )

    @Serializable
    private data class FixedReasoning(
        val effort: ReasoningEffort,
        val summary: ReasoningSummary? = null,
    )

    @Serializable
    private data class FixedItem(
        val id: String? = null,
        val type: String,
        val role: String? = null,
        val content: List<FixedContent>? = null,
        @SerialName("call_id") val callId: String? = null,
        val output: String? = null,
        val name: String? = null,
        val arguments: String? = null,
        @SerialName("encrypted_content") val encrypted: String? = null,
        val summary: List<FixedSummaryPart>? = null,
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
        @SerialName("item_id") val itemId: String? = null,
        val response: FixedResponse? = null,
    )

    @Serializable
    private data class FixedResponse(
        val output: List<FixedOutputItem> = emptyList(),
    )

    @Serializable
    private data class FixedOutputItem(
        val id: String,
        val type: String,
        val summary: List<FixedSummaryPart>? = null,
    )

    @Serializable
    private data class FixedSummaryPart(
        val type: String,
        val text: String? = null,
    )
}
