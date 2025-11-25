package com.github.kernitus.neoai

import ai.koog.agents.core.tools.ToolDescriptor
import ai.koog.prompt.dsl.Prompt
import ai.koog.prompt.executor.clients.openai.OpenAIClientSettings
import ai.koog.prompt.executor.clients.openai.OpenAILLMClient
import ai.koog.prompt.executor.clients.openai.OpenAIResponsesParams
import ai.koog.prompt.llm.LLModel
import ai.koog.prompt.message.Message
import ai.koog.prompt.message.ResponseMetaInfo
import ai.koog.prompt.streaming.StreamFrame
import io.ktor.client.HttpClient
import io.ktor.client.plugins.DefaultRequest
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * A custom client that fixes the missing tools behaviour in the official OpenAILLMClient
 * for the Responses API streaming endpoint.
 */
class FixedOpenAILLMClient(
    apiKey: String,
    private val settings: OpenAIClientSettings,
    // encodeDefaults = false removes null fields from the JSON output
    private val responseJson: Json = Json { ignoreUnknownKeys = true; encodeDefaults = false }
) : OpenAILLMClient(apiKey, settings) {

    private val myHttpClient = HttpClient {
        install(ContentNegotiation)
        install(DefaultRequest) {
            headers.append("Authorization", "Bearer $apiKey")
        }
    }

    override fun executeStreaming(
        prompt: Prompt,
        model: LLModel,
        tools: List<ToolDescriptor>
    ): Flow<StreamFrame> {
        val params = prompt.params

        if (params !is OpenAIResponsesParams) {
            return super.executeStreaming(prompt, model, tools)
        }

        return flow {
            // 1. Map Tools
            val apiTools = tools.map { tool ->
                FixedTool(
                    type = "function",
                    function = FixedFunction(
                        name = tool.name,
                        description = tool.description,
                        parameters = tool.paramsToJsonObject()
                    )
                )
            }

            // 2. Map Messages to Input Items
            val inputItems: List<FixedItem> = prompt.messages.mapNotNull { msg ->
                when (msg) {
                    is Message.System -> FixedItem(
                        type = "message",
                        role = "developer",
                        content = listOf(FixedContent(type = "input_text", text = msg.content))
                    )

                    is Message.User -> FixedItem(
                        type = "message",
                        role = "user",
                        content = listOf(FixedContent(type = "input_text", text = msg.content))
                    )

                    is Message.Assistant -> FixedItem(
                        type = "message",
                        role = "assistant",
                        content = listOf(FixedContent(type = "text", text = msg.content))
                    )

                    is Message.Tool.Result -> FixedItem(
                        type = "function_call_output",
                        callId = msg.id,
                        output = msg.content
                    )

                    is Message.Tool.Call -> FixedItem(
                        type = "function_call",
                        callId = msg.id,
                        name = msg.tool,
                        arguments = msg.content
                    )

                    else -> null
                }
            }

            // 3. Construct Request
            val request = FixedRequest(
                model = model.id,
                input = inputItems,
                tools = apiTools,
                stream = true,
                reasoning = params.reasoning?.let {
                    FixedReasoning(
                        effort = it.effort?.name?.lowercase() ?: "medium"
                    )
                }
            )

            val requestBody = responseJson.encodeToString(request)

            // 4. Execute Request
            // Fix URL construction to avoid double paths (e.g. /v1/v1/responses)
            var urlStr = settings.baseUrl.trimEnd('/')
            val path = settings.responsesAPIPath

            // If the baseUrl already ends with the path (common in custom configs), use it as is.
            // Otherwise, append the path intelligently.
            if (!urlStr.endsWith(path)) {
                // If baseUrl ends in /v1 and path starts with v1/, strip one to avoid duplication
                if (urlStr.endsWith("/v1") && path.startsWith("v1/")) {
                    urlStr = urlStr.removeSuffix("/v1")
                }
                urlStr = "$urlStr/$path"
            }

            myHttpClient.post {
                url(urlStr)
                contentType(ContentType.Application.Json)
                setBody(requestBody)
            }.bodyAsText().lineSequence().forEach { line ->
                if (line.startsWith("data: ")) {
                    val data = line.removePrefix("data: ").trim()
                    if (data != "[DONE]") {
                        try {
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
                                        emit(
                                            StreamFrame.ToolCall(
                                                id = item.callId ?: "",
                                                name = item.name ?: "",
                                                content = item.arguments ?: ""
                                            )
                                        )
                                    }
                                }

                                "response.completed" -> {
                                    emit(StreamFrame.End(null, ResponseMetaInfo.Empty))
                                }

                                else -> {}
                            }
                        } catch (e: Exception) {
                            // Ignore parsing errors
                        }
                    }
                }
            }
        }
    }

    // --- PRIVATE DTOs ---

    @Serializable
    private data class FixedRequest(
        val model: String,
        val input: List<FixedItem>,
        val tools: List<FixedTool>,
        val stream: Boolean,
        val reasoning: FixedReasoning? = null
    )

    @Serializable
    private data class FixedReasoning(val effort: String)

    @Serializable
    private data class FixedItem(
        val type: String,
        val role: String? = null,
        val content: List<FixedContent>? = null,
        @SerialName("call_id") val callId: String? = null,
        val output: String? = null,
        val name: String? = null,
        val arguments: String? = null
    )

    @Serializable
    private data class FixedContent(
        val type: String,
        val text: String? = null
    )

    @Serializable
    private data class FixedTool(
        val type: String,
        val function: FixedFunction
    )

    @Serializable
    private data class FixedFunction(
        val name: String,
        val description: String?,
        val parameters: JsonObject
    )

    @Serializable
    private data class FixedStreamEvent(
        val type: String,
        val delta: String? = null,
        val item: FixedItem? = null
    )
}

