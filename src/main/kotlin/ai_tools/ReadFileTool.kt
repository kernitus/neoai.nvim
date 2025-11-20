package com.github.kernitus.neoai.ai_tools

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

/**
 * Custom implementation of ReadFileTool with built-in relative path support.
 * Completely standalone - does not delegate to Koog's ReadFileTool.
 */
class CustomReadFileTool<Path>(
    private val fs: FileSystemProvider.ReadOnly<Path>,
    private val workingDirectory: String
) : Tool<CustomReadFileTool.Args, CustomReadFileTool.Result>() {

    @Serializable
    data class Args(
        @property:LLMDescription("Path to the text file (relative paths supported)")
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
        val totalLines: Int
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "__read_file__"
    override val description: String = """
        Reads a text file with optional line range selection. TEXT-ONLY - never reads binary files.
        Supports both relative and absolute paths.
        
        Use this to:
        - Read entire text files or specific line ranges
        - Get file content along with metadata
        
        Relative paths are resolved against: $workingDirectory
    """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // Resolve path
        val absolutePath = if (File(args.path).isAbsolute || args.path.startsWith("/")) {
            args.path
        } else {
            File(workingDirectory, args.path).normalize().absolutePath
        }

        // Get the path and metadata
        val path = fs.fromAbsolutePathString(absolutePath)
        val metadata = validateNotNull(fs.metadata(path)) {
            "File not found: $absolutePath"
        }

        validate(metadata.type == FileMetadata.FileType.File) {
            "Not a file: $absolutePath"
        }

        val contentType = fs.getFileContentType(path)
        validate(contentType == FileMetadata.FileContentType.Text) {
            "File is not a text file: $absolutePath"
        }

        // Read the entire file
        val fullText = fs.readText(path)
        val lines = fullText.lines()
        val totalLines = lines.size

        // Apply line range filtering
        val startIdx = args.startLine.coerceAtLeast(0)
        val endIdx = if (args.endLine < 0) totalLines else args.endLine.coerceAtMost(totalLines)

        validate(startIdx <= endIdx) {
            "Invalid line range: startLine=$startIdx > endLine=$endIdx"
        }
        validate(startIdx < totalLines) {
            "startLine=$startIdx is beyond file end (file has $totalLines lines)"
        }

        val selectedLines = lines.subList(startIdx, endIdx)
        val content = selectedLines.joinToString("\n")

        return Result(
            path = absolutePath,
            content = content,
            totalLines = totalLines
        )
    }
}