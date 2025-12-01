package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import com.github.kernitus.neoai.NeovimBridge
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable

class FindSymbolTool : Tool<FindSymbolTool.Args, FindSymbolTool.Result>() {
    @Serializable
    data class Args(
        @property:LLMDescription("The name of the symbol to find (e.g. 'StorageManager', 'loadMessages').")
        val name: String,
        @property:LLMDescription("The type of search to perform. Default is 'definition'.")
        val type: SearchType = SearchType.definition,
        @property:LLMDescription("Filter by language (e.g. 'kotlin', 'lua'). Optional.")
        val language: String = "",
    )

    @Serializable
    @Suppress("EnumEntryName")
    enum class SearchType {
        definition,
        // TODO add 'references' and 'implementations'
    }

    @Serializable
    data class Result(
        val output: String,
    )

    override val name = "find_symbol"
    override val description =
        """
        # WHEN TO USE
        - Use this to locate where a class, function, or variable is DEFINED.
        - PREFER THIS over 'grep'.
        - It uses a combination of LSP, Tree-sitter, and heuristic text search to find definitions.
        """.trimIndent()

    override val argsSerializer = Args.serializer()
    override val resultSerializer = Result.serializer()

    override suspend fun execute(args: Args): Result {
        val lang =
            when (args.language.lowercase()) {
                "kt" -> "kotlin"
                "ts" -> "typescript"
                "js" -> "javascript"
                "py" -> "python"
                else -> args.language
            }

        val luaArgs =
            mapOf(
                "query" to args.name,
                "type" to args.type.name,
                "language" to lang,
            )

        val response = NeovimBridge.callLua("neoai.ai_tools.find_symbol", "run", luaArgs)
        return Result(response.toString())
    }
}
