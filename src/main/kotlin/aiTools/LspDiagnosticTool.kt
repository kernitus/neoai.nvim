package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import com.github.kernitus.neoai.NeovimBridge
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable

class LspDiagnosticTool : Tool<LspDiagnosticTool.Args, LspDiagnosticTool.Result>() {
    @Serializable
    data class Args(
        @property:LLMDescription("Path to the file to inspect. Empty string = current buffer.")
        val filePath: String = "",
        @property:LLMDescription("If true, also retrieves available code actions.")
        val includeCodeActions: Boolean = false,
    )

    @Serializable
    data class Result(
        val output: String,
    )

    override val name = "lsp_diagnostic"
    override val description =
        """
        # WHEN TO USE
        - Use to check for compilation errors, warnings, or linter issues.
        - ALWAYS use this after editing a file to ensure no errors were introduced.
        """.trimIndent()

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()

    override suspend fun execute(args: Args): Result {
        // Map Kotlin camelCase args back to Lua snake_case args
        val luaArgs =
            mapOf(
                "file_path" to args.filePath,
                "include_code_actions" to args.includeCodeActions,
            )
        val response = NeovimBridge.callLua("neoai.ai_tools.lsp_diagnostic", "run", luaArgs)
        return Result(response.toString())
    }
}
