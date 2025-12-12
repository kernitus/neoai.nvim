package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import com.github.kernitus.neoai.NeovimBridge
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable

class SymbolIndexTool : Tool<SymbolIndexTool.Args, SymbolIndexTool.Result>() {
    @Serializable
    data class Args(
        @property:LLMDescription("Root path to scan. Use '.' for current working directory.")
        val path: String = ".",
        @property:LLMDescription("Explicit list of files to scan (relative to cwd). When non-empty, overrides path. Use empty array to auto-discover files under the path.")
        val files: List<String> = emptyList(),
        @property:LLMDescription("Only index these languages (e.g. ['lua','python']). Use empty array to include all detected languages.")
        val languages: List<String> = emptyList(),
        @property:LLMDescription("Include docstrings/comments when available.")
        val includeDocstrings: Boolean = true,
        @property:LLMDescription("Include 1-based line/col ranges.")
        val includeRanges: Boolean = true,
        @property:LLMDescription("Include basic signatures when available.")
        val includeSignatures: Boolean = true,
        @property:LLMDescription("Maximum files to process (safeguard).")
        val maxFiles: Int = 150,
        @property:LLMDescription("Maximum symbols to collect per file (safeguard).")
        val maxSymbolsPerFile: Int = 300,
        @property:LLMDescription("Fallback to textual heuristics if Tree-sitter fails.")
        val fallbackToText: Boolean = true,
    )

    @Serializable
    data class Result(
        val output: String,
    )

    override val name: String = "SymbolIndex"
    override val description: String =
        "Indexes symbols across the workspace (functions, methods, classes) using Tree-sitter with text fallbacks."

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()

    override suspend fun execute(args: Args): Result {
        val luaArgs =
            mapOf(
                "path" to args.path,
                "files" to args.files,
                "languages" to args.languages,
                "include_docstrings" to args.includeDocstrings,
                "include_ranges" to args.includeRanges,
                "include_signatures" to args.includeSignatures,
                "max_files" to args.maxFiles,
                "max_symbols_per_file" to args.maxSymbolsPerFile,
                "fallback_to_text" to args.fallbackToText,
            )
        val response = NeovimBridge.callLua("neoai.ai_tools.symbol_index", "run", luaArgs)
        return Result(response.toString())
    }
}
