package com.github.kernitus.neoai.ai_tools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import ai.koog.agents.core.tools.validate
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.io.File

class GrepTool(
    private val workingDirectory: String
) : Tool<GrepTool.Args, GrepTool.Result>() {

    @Serializable
    data class Args(
        @property:LLMDescription("The search query for ripgrep. Must not be empty.")
        val queryString: String,
        @property:LLMDescription("When true, treat query_string as a ripgrep regex. When false, use literal/fixed-string search.")
        val useRegex: Boolean = false,
        @property:LLMDescription("Restrict search to files of this type (e.g., 'lua', 'ts'). Use 'all' to search all known file types. Use empty string for no restriction. See `rg --type-list` for options.")
        val fileType: String = "",
        @property:LLMDescription("Exclude files of this type from the search (e.g., 'md', 'json'). Use empty string for no exclusion.")
        val excludeFileType: String = ""
    )

    @Serializable
    data class Result(
        val output: String, // The content wrapped in code blocks
        val paramsLine: String
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "grep"
    override val description: String = """
        # WHEN TO USE THIS TOOL

        - Use Grep for raw text searches across multiple files in a project. It is ideal for finding specific strings, function names, or error messages.
        - Prefer this tool over reading individual files when you don't know which file contains the information you need.
        - For structural code analysis (e.g., "find the function body of `foo`"), prefer the TreeSitterQuery tool.

        # HOW TO USE

        - Provide a search string as the `query_string` parameter.
        - By default, the search is literal (fixed string). Set `use_regex: true` to treat `query_string` as a ripgrep regular expression.
        - To search only specific kinds of files, use the `file_type` parameter (e.g., `file_type = "lua"` or `file_type = "ts"`). This respects `.gitignore`.
        - To exclude specific file types, use the `exclude_file_type` parameter (e.g., `exclude_file_type = "md"`).
        - To search all file types known to `ripgrep` while still respecting `.gitignore`, use `file_type = "all"`.
        - If you don't provide any file type filters, `ripgrep` will search all files while respecting all ignore files (`.gitignore`, etc.), which is the recommended default for general searches.

        # FEATURES

        - Fast, recursive search using `ripgrep` (rg).
        - **Respects `.gitignore` and other ignore files by default.**
        - Literal search by default to prevent common regex errors. Full regex is supported via `use_regex: true`.
        - Supports filtering by file type for inclusion (`file_type`) and exclusion (`exclude_file_type`).
        - Returns all matches in `vimgrep` format: `path:line:col:text`.

        # LIMITATIONS

        - Requires `ripgrep` (rg) to be installed and available in `PATH`.
        - Does not search binary files by default.
        - Large codebases may return many results; refine your query for best performance.
    """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // Validate input
        validate(args.queryString.isNotBlank()) { "Error: 'queryString' is required and must not be empty." }

        val paramsLine = makeParamsLine(args.queryString, args.useRegex, args.fileType, args.excludeFileType)

        // Attempt 1: Run with provided arguments
        val initialResult = runRipgrep(
            query = args.queryString,
            useRegex = args.useRegex,
            fileType = args.fileType,
            excludeFileType = args.excludeFileType
        )

        // Check for Regex failure conditions (Exit code > 1 OR specific regex error messages in output/stderr)
        val regexFailed = args.useRegex && (
                initialResult.exitCode > 1 ||
                initialResult.stderr.contains("regex parse error", ignoreCase = true) ||
                initialResult.stderr.contains("unclosed group", ignoreCase = true) ||
                initialResult.stdout.contains("regex parse error", ignoreCase = true)
        )

        if (regexFailed) {
            // Fallback: Retry with fixed strings
            val fallbackResult = runRipgrep(
                query = args.queryString,
                useRegex = false, // Force fixed string
                fileType = args.fileType,
                excludeFileType = args.excludeFileType
            )

            if (fallbackResult.stdout.isNotBlank()) {
                val fallbackParams = makeParamsLine(args.queryString, false, args.fileType, args.excludeFileType)
                return Result(
                    output = formatOutput(fallbackResult.stdout),
                    paramsLine = fallbackParams
                )
            }
        }

        // Handle standard errors from the initial run (if not a regex failure we just handled)
        if (initialResult.exitCode > 1) {
            return Result(
                output = "Error running rg: ${initialResult.stderr}",
                paramsLine = paramsLine
            )
        }

        if (initialResult.stdout.isBlank()) {
            return Result(
                output = "No matches found for: ${args.queryString}",
                paramsLine = paramsLine
            )
        }

        return Result(
            output = formatOutput(initialResult.stdout),
            paramsLine = paramsLine
        )
    }

    private data class ProcessResult(val stdout: String, val stderr: String, val exitCode: Int)

    private fun runRipgrep(
        query: String,
        useRegex: Boolean,
        fileType: String,
        excludeFileType: String
    ): ProcessResult {
        // Base ripgrep command with vimgrep-style output
        // Note: using American spelling for flags as required by the tool
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

        // Use -e to ensure the pattern is treated as the pattern argument
        command.add("-e")
        command.add(query)

        val processBuilder = ProcessBuilder(command)
        processBuilder.directory(File(workingDirectory))

        val process = processBuilder.start()
        val stdout = process.inputStream.bufferedReader().readText()
        val stderr = process.errorStream.bufferedReader().readText()
        val exitCode = process.waitFor()

        return ProcessResult(stdout, stderr, exitCode)
    }

    private fun makeParamsLine(
        query: String,
        useRegex: Boolean,
        fileType: String,
        excludeFileType: String
    ): String {
        // Mimics the Lua string.format("%q") behaviour roughly
        val q = "\"$query\""
        val ft = if (fileType.isNotBlank()) "\"$fileType\"" else "nil"
        val eft = if (excludeFileType.isNotBlank()) "\"$excludeFileType\"" else "nil"

        return "Parameters used: query_string=$q; use_regex=$useRegex; file_type=$ft; exclude_file_type=$eft"
    }

    private fun formatOutput(content: String): String {
        return """
            ```txt
            $content
            ```
        """.trimIndent()
    }
}

