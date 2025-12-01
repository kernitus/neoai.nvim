package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import ai.koog.agents.core.tools.validate
import com.github.kernitus.neoai.DebugLogger
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.io.File
import java.io.InputStream

class GrepTool(
    private val workingDirectory: String,
) : Tool<GrepTool.Args, GrepTool.Result>() {
    @Serializable
    data class Args(
        @property:LLMDescription("The search query for ripgrep. Must not be empty.")
        val queryString: String,
        @property:LLMDescription("When true, treat query_string as a ripgrep regex. When false, use literal/fixed-string search.")
        val useRegex: Boolean = false,
        @property:LLMDescription(
            "Restrict search to files of this type (e.g. 'kotlin', 'python', 'javascript'). Use empty string for no restriction.",
        )
        val fileType: String = "",
        @property:LLMDescription(
            "Exclude files of this type from the search. Use empty string for no exclusion.",
        )
        val excludeFileType: String = "",
    )

    @Serializable
    data class Result(
        val output: String,
        val paramsLine: String,
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "grep"
    override val description: String =
        """
        # WHEN TO USE THIS TOOL
        - Use Grep for raw text searches across multiple files.
        # FEATURES
        - Fast, recursive search using `ripgrep` (rg).
        - Respects .gitignore.
        """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // 1. Normalise the file types before logging or executing
        val finalFileType = normaliseFileType(args.fileType)
        val finalExcludeType = normaliseFileType(args.excludeFileType)

        DebugLogger.log(
            "GrepTool.execute: START query=${args.queryString} " +
                "useRegex=${args.useRegex} fileType=$finalFileType (raw: ${args.fileType}) excludeFileType=$finalExcludeType",
        )
        try {
            validate(args.queryString.isNotBlank()) { "Error: 'queryString' is required." }

            val paramsLine = makeParamsLine(args.queryString, args.useRegex, finalFileType, finalExcludeType)

            val initialResult =
                runRipgrep(
                    query = args.queryString,
                    useRegex = args.useRegex,
                    fileType = finalFileType,
                    excludeFileType = finalExcludeType,
                )

            // Regex failure check
            val regexFailed =
                args.useRegex && (
                    initialResult.exitCode > 1 ||
                        initialResult.stderr.contains("regex parse error", ignoreCase = true)
                )

            if (regexFailed) {
                val fallbackResult =
                    runRipgrep(
                        query = args.queryString,
                        useRegex = false,
                        fileType = finalFileType,
                        excludeFileType = finalExcludeType,
                    )
                if (fallbackResult.stdout.isNotBlank()) {
                    return Result(formatOutput(fallbackResult.stdout), paramsLine + " (Fallback: Literal)")
                }
            }

            if (initialResult.exitCode > 1) {
                // If rg fails due to a type error despite normalisation, we return the error so the AI knows.
                return Result("Error running rg: ${initialResult.stderr}", paramsLine)
            }

            if (initialResult.stdout.isBlank()) {
                return Result("No matches found for: ${args.queryString}", paramsLine)
            }

            DebugLogger.log("GrepTool.execute: RETURN success")
            return Result(formatOutput(initialResult.stdout), paramsLine)
        } catch (t: Throwable) {
            DebugLogger.log("GrepTool.execute: CRASH: ${t::class.qualifiedName}: ${t.message}")
            DebugLogger.log(t.stackTraceToString())
            return Result(
                output = "TOOL CRASHED: ${t.message}\n${t.stackTraceToString()}",
                paramsLine = "Error executing grep",
            )
        }
    }

    /**
     * Maps common AI guesses (extensions or full names) to the specific type alias required by ripgrep.
     * This is because ripgrep doesn't have consistent naming, e.g. uses "markdown" but then "js".
     */
    private fun normaliseFileType(input: String): String {
        if (input.isBlank()) return ""
        val lower = input.lowercase().trim()

        // Remove leading dot if the AI provided an extension like ".kt"
        val clean = if (lower.startsWith(".")) lower.substring(1) else lower

        return when (clean) {
            // Map Extensions -> Ripgrep Type Name
            "kt" -> "kotlin"

            "py" -> "python"

            "rs" -> "rust"

            "md" -> "markdown"

            "rb" -> "ruby"

            "sh" -> "sh"

            // rg uses 'sh' for bash/zsh/etc
            "yml" -> "yaml"

            "tsx" -> "ts"

            "jsx" -> "js"

            // Map Full Names -> Ripgrep Short Codes
            "javascript" -> "js"

            "typescript" -> "ts"

            "golang" -> "go"

            "bash" -> "sh"

            "shell" -> "sh"

            // Pass through everything else (java, lua, json, go, etc. match correctly)
            else -> clean
        }
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

        // Cap matches so we never spam the model
        command.add("--max-count=200")
        command.add("-e")
        command.add(query)

        // Make sure it searched cwd and not stdin
        command.add(".")

        DebugLogger.log("GrepTool.runRipgrep: launching ${command.joinToString(" ")} in $workingDirectory")

        val processBuilder = ProcessBuilder(command)
        processBuilder.directory(File(workingDirectory))

        val process = processBuilder.start()

        // Same pattern as list_directory, but bounded
        val stdout = readStreamWithLimit(process.inputStream, 100 * 1024)

        val exitCode = process.waitFor()

        var stderr = ""
        if (exitCode > 1) {
            stderr = process.errorStream.bufferedReader().use { it.readText() }
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
                    output.append("\n... [Output truncated: too large] ...")
                    break
                }
                output.append(buffer, 0, bytesRead)
                totalRead += bytesRead
            }
            output.toString()
        }

    private fun makeParamsLine(
        q: String,
        r: Boolean,
        ft: String,
        eft: String,
    ): String = "query=$q regex=$r fileType=$ft exclude=$eft"

    private fun formatOutput(content: String): String = "```txt\n$content\n```"
}
