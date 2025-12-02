package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import ai.koog.agents.core.tools.validate
import ai.koog.agents.core.tools.validateNotNull
import ai.koog.rag.base.files.FileMetadata
import ai.koog.rag.base.files.FileSystemProvider
import ai.koog.rag.base.files.readText
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.io.File

class CustomReadFileTool<Path>(
    private val fs: FileSystemProvider.ReadOnly<Path>,
    private val workingDirectory: String,
) : Tool<CustomReadFileTool.Args, CustomReadFileTool.Result>() {
    @Serializable
    data class Args(
        @property:LLMDescription("Relative path to the text file")
        val path: String,
        @property:LLMDescription("First line to include (0-based, inclusive). Default is 0")
        val startLine: Int = 0,
        @property:LLMDescription("First line to exclude (0-based, exclusive). Use -1 to read until end. Default is -1")
        val endLine: Int = -1,
    )

    @Serializable
    data class Result(
        val path: String,
        val content: String,
        val totalLines: Int,
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "read_file"
    override val description: String =
        """
        # WHEN TO USE THIS TOOL

        - Use when you need to read the contents of a specific file.
        - Helpful for examining source code, configuration files, or log files.
        - Perfect for looking at text-based file formats.

        # HOW TO USE

        - Provide the `path` (relative to the current working directory).
        - Optionally specify `startLine` to begin reading from a specific line (0-based, inclusive). Default is 0.
        - Optionally specify `endLine` to stop reading (0-based, exclusive). Use -1 to read until the end of the file. Default is -1.

        # FEATURES

        - Reads from any specified line range in a file.
        - Automatically detects non-text files and refuses to read them to prevent errors.
        - Returns the total number of lines in the file along with the requested content.

        # LIMITATIONS

        - Cannot open files that do not exist or are inaccessible.
        - Only reads text files; binary files or images cannot be read.
        """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // Resolve path
        val absolutePath = File(workingDirectory, args.path).normalize().absolutePath

        // Get the path and metadata
        val path = fs.fromAbsolutePathString(absolutePath)
        val metadata =
            validateNotNull(fs.metadata(path)) {
                "File not found: $absolutePath"
            }

        validate(metadata.type == FileMetadata.FileType.File) {
            "Not a file: $absolutePath"
        }

        val contentType = fs.getFileContentType(path)
        validate(contentType == FileMetadata.FileContentType.Text) {
            "File is not a text file: $absolutePath"
        }

        // Apply line range filtering
        val startIdx = args.startLine.coerceAtLeast(0)
        // If endLine is -1, we read until the end (represented by Max Value)
        val endIdx = if (args.endLine < 0) Int.MAX_VALUE else args.endLine

        validate(startIdx <= endIdx) {
            "Invalid line range: startLine=$startIdx > endLine=$endIdx"
        }

        val contentBuilder = StringBuilder()
        var totalLines = 0

        // Stream the file to avoid loading the entire content into memory
        File(absolutePath).bufferedReader().use { reader ->
            var line = reader.readLine()
            while (line != null) {
                // Collect content only if within the requested range
                if (totalLines >= startIdx && totalLines < endIdx) {
                    if (contentBuilder.isNotEmpty()) {
                        contentBuilder.append("\n")
                    }
                    contentBuilder.append(line)
                }

                // We must continue reading to count totalLines correctly,
                // even if we have passed the endIdx.
                totalLines++
                line = reader.readLine()
            }
        }

        validate(startIdx < totalLines) {
            "startLine=$startIdx is beyond file end (file has $totalLines lines)"
        }

        return Result(
            path = absolutePath,
            content = contentBuilder.toString(),
            totalLines = totalLines,
        )
    }
}
