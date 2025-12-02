package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import ai.koog.agents.core.tools.validate
import ai.koog.rag.base.files.FileMetadata
import ai.koog.rag.base.files.FileSystemProvider
import ai.koog.rag.base.files.readText
import ai.koog.rag.base.files.writeText
import com.github.kernitus.neoai.NeovimBridge
import com.github.kernitus.neoai.aiTools.patch.FilePatch
import com.github.kernitus.neoai.aiTools.patch.applyBatchPatches
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.io.File

class CustomEditFileTool<Path>(
    private val fs: FileSystemProvider.ReadWrite<Path>,
    private val workingDirectory: String,
) : Tool<CustomEditFileTool.Args, CustomEditFileTool.Result>() {
    companion object {
        private const val DUPLICATE_PATH_ERROR_PREFIX = "Edit tool error: multiple tool calls attempted for the same file"
    }

    private val currentTurnCallPaths: MutableSet<String> = java.util.Collections.synchronizedSet(mutableSetOf())

    private data class DiagnosticsPayload(
        val diagnostics: String?,
        val count: Int,
    )

    fun resetTurnState() {
        currentTurnCallPaths.clear()
    }

    @Serializable
    data class Args(
        @property:LLMDescription("Relative path to the file. If it doesn't exist, it will be created.")
        val path: String,
        @property:LLMDescription(
            "List of edit operations to apply to this file. All edits for a file must be supplied in this single call; the engine applies them order-invariantly and resolves overlaps.",
        )
        val edits: List<EditOperation>,
    ) {
        init {
            validate(edits.isNotEmpty()) { "Edits array must contain at least one operation." }
        }
    }

    @Serializable
    data class EditOperation(
        @property:LLMDescription("The exact text block to replace. Use empty string to insert at beginning of file.")
        val original: String,
        @property:LLMDescription("The new text content.")
        val replacement: String,
    )

    @Serializable
    data class Result(
        val appliedCount: Int,
        val skippedCount: Int,
        val path: String,
        val message: String,
        val diagnostics: String? = null,
        val diagnosticCount: Int = 0,
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "edit_file"
    override val description: String =
        """
        Makes edits to a target file by applying text replacement patches.
        Works with paths relative to the current neovim project working directory.
        
        Key Requirements:
        - The 'original' text must match text in the file (whitespaces and line endings are fuzzy matched).
        - You can provide multiple edits in one call.
        - Use empty string ("") for 'original' to insert text at the beginning of the file.
        """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // Resolve path
        val fileHandle = File(workingDirectory, args.path).normalize()
        val absolutePath = fileHandle.absolutePath
        val path = fs.fromAbsolutePathString(absolutePath)

        // Check if file exists and is text
        if (fs.exists(path)) {
            val fileContentType = fs.getFileContentType(path)
            validate(fileContentType == FileMetadata.FileContentType.Text) {
                "Can not edit non-text files, tried editing: $absolutePath, which is a $fileContentType"
            }
        }

        // Read content (empty if new file)
        val content = if (fs.exists(path)) fs.readText(path) else ""

        // Convert Args to internal FilePatch objects
        val patches = args.edits.map { FilePatch(it.original, it.replacement) }

        // Apply patches using the multi-pass batch logic
        val result = applyBatchPatches(content, patches)

        if (result.appliedCount > 0 || result.finalContent != content) {
            fileHandle.parentFile?.mkdirs()
            fs.writeText(path, result.finalContent)
        }

        val diagnosticsResult = runDiagnosticsInline(args.path)

        val msg =
            buildString {
                append("Queued edits for review in ${args.path}. ")
                append("Applied ${result.appliedCount}, skipped ${result.skippedCount} (already applied).")
                if (result.unappliedCount > 0) {
                    append("\nWarning: ${result.unappliedCount} edits could not be applied after multiple passes.")
                }
                if (diagnosticsResult.diagnostics.isNullOrBlank()) {
                    append("\nNo diagnostics were returned.")
                } else {
                    append("\nDiagnostics summary: ${diagnosticsResult.diagnostics}")
                }
            }

        return Result(
            appliedCount = result.appliedCount,
            skippedCount = result.skippedCount,
            path = absolutePath,
            message = msg,
            diagnostics = diagnosticsResult.diagnostics,
            diagnosticCount = diagnosticsResult.count,
        )
    }

    private suspend fun runDiagnosticsInline(relativePath: String): DiagnosticsPayload {
        val payload =
            mapOf(
                "file_path" to relativePath,
                "include_code_actions" to false,
            )
        val response = NeovimBridge.callLua("neoai.ai_tools.lsp_diagnostic", "run", payload)
        val output = response?.toString()?.trim()
        val count = parseDiagnosticCount(output)
        return DiagnosticsPayload(output, count)
    }

    private fun parseDiagnosticCount(output: String?): Int {
        if (output.isNullOrBlank()) return 0
        val lines = output.lines().filter { it.isNotBlank() }
        if (lines.size == 1 && lines.first().contains("No diagnostics", ignoreCase = true)) {
            return 0
        }
        return lines.size
    }
}
