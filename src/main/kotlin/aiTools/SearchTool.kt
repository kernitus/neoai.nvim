package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import com.github.kernitus.neoai.DebugLogger
import com.github.kernitus.neoai.NeovimBridge
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.io.File
import java.io.InputStream

class SearchTool(
    private val workingDirectory: String,
) : Tool<SearchTool.Args, SearchTool.Result>() {
    @Serializable
    data class Args(
        @property:LLMDescription("The string, regex, or symbol name to search for.")
        val query: String,
        @property:LLMDescription(
            "The strategy to use:\n" +
                "- 'SMART': (Default) Tries to find the code DEFINITION first. If not found, falls back to text search.\n" +
                "- 'REFERENCES': Find all usages/references of a symbol (LSP).\n" +
                "- 'IMPLEMENTATIONS': Find implementations/overrides of an interface/class (LSP).\n" +
                "- 'TEXT': Force a literal text search (Grep). Use for comments, logs, or TODOs.\n" +
                "- 'REGEX': Force a regex search (Grep).",
        )
        val strategy: SearchStrategy = SearchStrategy.SMART,
        @property:LLMDescription("Filter by file extension (e.g. 'kt', 'lua'). Optional.")
        val fileType: String = "",
        @property:LLMDescription("Exclude files of this type from the search. Optional.")
        val excludeFileType: String = "",
    )

    @Serializable
    enum class SearchStrategy {
        SMART,
        REFERENCES,
        IMPLEMENTATIONS,
        TEXT,
        REGEX,
    }

    @Serializable
    data class Result(
        val output: String,
        val methodUsed: String,
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "search_project"
    override val description: String =
        """
        # WHEN TO USE
        - Use this for ALL search operations: finding code definitions, references, implementations, or raw text.
        - Select the appropriate 'strategy' for your goal.
        
        # STRATEGIES
        - Use 'SMART' (default) when you want to find "where is X defined?" or general code lookup.
        - Use 'REFERENCES' to see where a function or class is being used.
        - Use 'TEXT' for comments, TODOs, or partial string matches.
        """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // 1. Normalise inputs
        val finalFileType = normaliseFileType(args.fileType)
        val finalExcludeType = normaliseFileType(args.excludeFileType)
        val query = args.query.trim()

        DebugLogger.log("SearchTool: query='$query' strategy=${args.strategy} fileType=$finalFileType")

        if (query.isBlank()) {
            return Result("Error: Query must not be empty.", "Validation")
        }

        return when (args.strategy) {
            SearchStrategy.SMART -> executeSmartSearch(query, finalFileType, finalExcludeType)
            SearchStrategy.REFERENCES -> executeLspSearch(query, "references", finalFileType)
            SearchStrategy.IMPLEMENTATIONS -> executeLspSearch(query, "implementation", finalFileType)
            SearchStrategy.TEXT -> executeGrep(query, isRegex = false, finalFileType, finalExcludeType)
            SearchStrategy.REGEX -> executeGrep(query, isRegex = true, finalFileType, finalExcludeType)
        }
    }

    /**
     * Smart Search Logic:
     * 1. If query looks like text (spaces, special chars), skip LSP and use Grep.
     * 2. Try LSP Definition.
     * 3. If LSP fails or returns nothing, fallback to Grep.
     */
    private suspend fun executeSmartSearch(
        query: String,
        fileType: String,
        excludeType: String,
    ): Result {
        // Heuristic: If query contains spaces or non-code characters, it is likely text/comment.
        // We allow underscores and dots for fully qualified names.
        val isLikelyText = query.contains(" ") || !query.all { it.isLetterOrDigit() || it == '_' || it == '.' }

        if (isLikelyText) {
            DebugLogger.log("SearchTool: Query looks like text. Skipping LSP.")
            return executeGrep(query, isRegex = false, fileType, excludeType)
        }

        // Try LSP Definition
        try {
            val lspResult = runLspQuery(query, "definition", fileType)
            if (isValidLspResult(lspResult)) {
                return Result(lspResult, "LSP (Definition)")
            }
        } catch (e: Exception) {
            DebugLogger.log("SearchTool: LSP search failed silently: ${e.message}")
        }

        // Fallback
        DebugLogger.log("SearchTool: LSP returned no results. Falling back to Grep.")
        val grepResult = executeGrep(query, isRegex = false, fileType, excludeType)
        return grepResult.copy(methodUsed = "Grep (Fallback from Smart)")
    }

    private suspend fun executeLspSearch(
        query: String,
        lspType: String,
        fileType: String,
    ): Result {
        val output = runLspQuery(query, lspType, fileType)

        if (!isValidLspResult(output)) {
            // If explicit LSP strategy was requested but failed, we do NOT fallback to grep automatically,
            // as grepping for "references" is semantically different.
            return Result("No $lspType found for symbol '$query'.", "LSP ($lspType)")
        }
        return Result(output, "LSP ($lspType)")
    }

    private suspend fun runLspQuery(
        query: String,
        type: String,
        fileType: String,
    ): String {
        // Map the file extension (e.g. "kt") to the full language name (e.g. "kotlin") for the Lua bridge
        val lang = mapExtensionToLang(fileType)

        val luaArgs =
            mapOf(
                "query" to query,
                "type" to type,
                "language" to lang,
            )

        val response = NeovimBridge.callLua("neoai.ai_tools.find_symbol", "run", luaArgs)
        return response.toString()
    }

    private fun executeGrep(
        query: String,
        isRegex: Boolean,
        fileType: String,
        excludeFileType: String,
    ): Result {
        try {
            val initialResult = runRipgrep(query, isRegex, fileType, excludeFileType)

            // Check for regex failure (user might have provided invalid regex)
            val regexFailed =
                isRegex && (
                    initialResult.exitCode > 1 ||
                        initialResult.stderr.contains("regex parse error", ignoreCase = true)
                )

            if (regexFailed) {
                DebugLogger.log("SearchTool: Regex failed. Retrying as literal string.")
                val fallbackResult = runRipgrep(query, false, fileType, excludeFileType)
                if (fallbackResult.stdout.isNotBlank()) {
                    return Result(formatOutput(fallbackResult.stdout), "Grep (Fallback: Literal)")
                }
                return Result("Error parsing regex: ${initialResult.stderr}", "Grep (Error)")
            }

            if (initialResult.exitCode > 1) {
                return Result("Error running grep: ${initialResult.stderr}", "Grep (Error)")
            }

            if (initialResult.stdout.isBlank()) {
                return Result("No matches found for: $query", "Grep")
            }

            return Result(formatOutput(initialResult.stdout), "Grep")
        } catch (t: Throwable) {
            DebugLogger.log("SearchTool: CRASH: ${t.message}")
            return Result("TOOL CRASHED: ${t.message}", "Error")
        }
    }

    // --- Helpers ---

    private fun isValidLspResult(output: String): Boolean =
        output.isNotBlank() &&
            !output.contains("No matches found", ignoreCase = true) &&
            !output.contains("Error", ignoreCase = true)

    private fun formatOutput(content: String): String = "```txt\n$content\n```"

    /**
     * Maps common AI guesses (extensions or full names) to the specific type alias required by ripgrep.
     */
    private fun normaliseFileType(input: String): String {
        if (input.isBlank()) return ""
        val lower = input.lowercase().trim()
        val clean = if (lower.startsWith(".")) lower.substring(1) else lower

        return when (clean) {
            "kt" -> "kotlin"
            "py" -> "python"
            "rs" -> "rust"
            "md" -> "markdown"
            "rb" -> "ruby"
            "sh", "bash", "shell" -> "sh"
            "yml" -> "yaml"
            "tsx", "typescript" -> "ts"
            "jsx", "javascript" -> "js"
            "golang" -> "go"
            else -> clean
        }
    }

    /**
     * Maps the normalised file type (ripgrep style) back to full language names for LSP/Lua.
     */
    private fun mapExtensionToLang(ext: String): String =
        when (ext) {
            "kt", "kotlin" -> "kotlin"
            "ts" -> "typescript"
            "js" -> "javascript"
            "py" -> "python"
            "rs" -> "rust"
            "go" -> "go"
            "lua" -> "lua"
            else -> ext
        }

    private data class ProcessResult(
        val stdout: String,
        val stderr: String,
        val exitCode: Int,
    )

    private fun runRipgrep(
        query: String,
        useRegex: Boolean,
        fileType: String,
        excludeFileType: String,
    ): ProcessResult {
        // Note: "color" spelling is required for the ripgrep flag
        val command = mutableListOf("rg", "--vimgrep", "--color", "never")

        if (!useRegex) {
            command.add("--fixed-strings")
        }
        if (fileType.isNotBlank()) {
            command.add("-t")
            command.add(fileType)
        }
        if (excludeFileType.isNotBlank()) {
            command.add("-T")
            command.add(excludeFileType)
        }

        // Cap matches to prevent context flooding
        command.add("--max-count=200")
        command.add("-e")
        command.add(query)

        // Search current working directory
        command.add(".")

        DebugLogger.log("SearchTool: launching ${command.joinToString(" ")} in $workingDirectory")

        val processBuilder = ProcessBuilder(command)
        processBuilder.directory(File(workingDirectory))

        val process = processBuilder.start()

        // Close stdin immediately. We are not writing to the process.
        // This frees one file descriptor immediately.
        process.outputStream.close()

        val stdout = readStreamWithLimit(process.inputStream, 100 * 1024)
        val exitCode = process.waitFor()

        var stderr = ""
        if (exitCode > 1) {
            stderr = process.errorStream.bufferedReader().use { it.readText() }
        } else {
            // Even if we didn't read it, we must close it to free the FD
            process.errorStream.close()
        }

        return ProcessResult(stdout, stderr, exitCode)
    }

    private fun readStreamWithLimit(
        inputStream: InputStream,
        limitBytes: Int,
    ): String =
        inputStream.bufferedReader().use { reader ->
            val buffer = CharArray(1024)
            val output = StringBuilder()
            var totalRead = 0
            var bytesRead: Int

            while (reader.read(buffer).also { bytesRead = it } != -1) {
                if (totalRead + bytesRead > limitBytes) {
                    output.append(buffer, 0, limitBytes - totalRead)
                    output.append("\n... [Output truncated: too large]...")
                    break
                }
                output.append(buffer, 0, bytesRead)
                totalRead += bytesRead
            }
            output.toString()
        }
}
