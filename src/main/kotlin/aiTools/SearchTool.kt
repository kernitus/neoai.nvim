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
        CRITICAL: Do NOT repeat a search query you have already tried.
        If a search returned "No matches found", the code does not exist. Do not retry.

        # WHEN TO USE
        - Use this tool for all project‑wide search operations: finding definitions, usages, or text.
        - In almost all cases you should use **SMART**. Only choose a different strategy when it is clearly required.
        # STRATEGIES
        - **SMART (preferred, default)**:
          - Use for almost everything:
            - "Where is X defined?"
            - "Where is X used?"
            - Discovering related files or state.
            - Searching for comments, log messages, or other text.
          - SMART will choose the best method (LSP definition where possible, otherwise plain text search). You do not need to decide this yourself.
        - **REFERENCES**:
          - Use only when you *specifically* want all usages/references of a known symbol via LSP.
          - Example: "show me every place `handleSubmit` is called".
        - **IMPLEMENTATIONS**:
          - Use only when you *specifically* want implementations or overrides of an interface, abstract method, or class via LSP.
        - **REGEX (advanced / rare)**:
          - Use *only* when the user has explicitly requested a regular expression search, or when you genuinely need pattern‑based matching (for example many similar variants in one query).
          - Do **not** use REGEX as a replacement for SMART or ordinary text search.
          - If you are not confident that you are writing a correct regular expression, do not use this strategy.
        # GENERAL GUIDANCE
        - If you are unsure which strategy to choose, always pick **SMART**.
        - Do **not** switch to REGEX just because SMART found no results; instead, reconsider the query or explain that nothing was found.
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
        val isLikelyText = " " in query || !query.all { it.isLetterOrDigit() || it == '_' || it == '.' }

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

    private fun isValidLspResult(output: String): Boolean {
        if (output.isBlank()) return false

        val lower = output.lowercase()
        if ("error" in lower) return false
        if ("no matches found" in lower) return false
        if ("no definitions found" in lower) return false
        if ("no references found" in lower) return false
        if ("no implementations found" in lower) return false

        return true
    }

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

        command.add("--max-count=100")
        command.add("-e")
        command.add(query)
        command.add(".")

        DebugLogger.log("SearchTool: launching ${command.joinToString(" ")} in $workingDirectory")

                val processBuilder = ProcessBuilder(command)
                processBuilder.directory(File(workingDirectory))

                val process = processBuilder.start()

                try {
                    // No stdin needed for ripgrep
                    process.outputStream.close()

                    val stdout = readStreamWithLimit(process.inputStream, 100 * 1024)
                    val stderr = readStreamWithLimit(process.errorStream, 32 * 1024)
                    val exitCode = process.waitFor()

                    return ProcessResult(
                        stdout = if (exitCode <= 1) stdout else "",
                        stderr = if (exitCode > 1) stderr else "",
                        exitCode = exitCode,
                    )
                } finally {
                    runCatching { process.inputStream.close() }
                    runCatching { process.errorStream.close() }
                    runCatching { process.outputStream.close() }
                    process.destroyForcibly()
                }
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
                            output.appendRange(buffer, 0, limitBytes - totalRead)
                            output.append("\n... [Output truncated: too large]...")
                            break
                        }
                        output.appendRange(buffer, 0, bytesRead)
                        totalRead += bytesRead
                    }
                    output.toString()
                }
        }

