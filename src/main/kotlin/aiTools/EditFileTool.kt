package com.github.kernitus.neoai.aiTools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import ai.koog.agents.core.tools.validate
import ai.koog.rag.base.files.FileMetadata
import ai.koog.rag.base.files.FileSystemProvider
import ai.koog.rag.base.files.readText
import ai.koog.rag.base.files.writeText
import com.github.kernitus.neoai.aiTools.patch.FilePatch
import com.github.kernitus.neoai.aiTools.patch.applyTokenNormalisedPatch
import com.github.kernitus.neoai.aiTools.patch.isSuccess
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.io.File

class CustomEditFileTool<Path>(
    private val fs: FileSystemProvider.ReadWrite<Path>,
    private val workingDirectory: String,
) : Tool<CustomEditFileTool.Args, CustomEditFileTool.Result>() {
    @Serializable
    data class Args(
        @property:LLMDescription("Relative path to the file. If it doesn't exist, it will be created.")
        val path: String,
        @property:LLMDescription("The exact text block to replace. Use empty string for new files or full rewrites.")
        val original: String,
        @property:LLMDescription("The new text content that will replace the original text block.")
        val replacement: String,
    )

    @Serializable
    data class Result(
        val applied: Boolean,
        val reason: String? = null,
        val path: String,
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "edit_file"
    override val description: String =
        """
        Makes an edit to a target file by applying a single text replacement patch.
        Works with paths relative to the current neovim project working directory.
        
        Key Requirements:
        - The 'original' text must match text in the file (whitespaces and line endings are fuzzy matched)
        - Only ONE replacement per tool call
        - Use empty string ("") for 'original' when creating new files or performing complete rewrites
        """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // Resolve path
        // We keep the File reference to create directories later if needed
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

        // Apply patch
        val patch = FilePatch(args.original, args.replacement)
        val patchApplyResult = applyTokenNormalisedPatch(content, patch)

        if (patchApplyResult.isSuccess()) {
            fileHandle.parentFile?.mkdirs()

            fs.writeText(path, patchApplyResult.updatedContent)
            return Result(applied = true, path = absolutePath)
        } else {
            return Result(applied = false, reason = patchApplyResult.reason, path = absolutePath)
        }
    }
}
