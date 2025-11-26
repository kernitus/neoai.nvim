package com.github.kernitus.neoai.ai_tools

import ai.koog.agents.core.tools.Tool
import ai.koog.agents.core.tools.annotations.LLMDescription
import ai.koog.agents.core.tools.validate
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import java.io.File

class CustomListDirectoryTool<Path>(
    private val workingDirectory: String
) : Tool<CustomListDirectoryTool.Args, CustomListDirectoryTool.Result>() {

    @Serializable
    data class Args(
        @property:LLMDescription("Relative path to the directory (Use '.' for current directory)")
        val path: String = ".",
        @property:LLMDescription("Maximum depth to display. Automatically adapts based on repository size.")
        val depth: Int = 3
    )

    @Serializable
    data class Result(
        val output: String, // The rendered visual tree
        val totalFiles: Int
    )

    override val argsSerializer: KSerializer<Args> = Args.serializer()
    override val resultSerializer: KSerializer<Result> = Result.serializer()
    override val name: String = "list_directory"
    override val description: String = """
        Lists project structure using ripgrep (automatically respects .gitignore).
        
        Returns a visual tree representation.
    """.trimIndent()

    override suspend fun execute(args: Args): Result {
        // Resolve path
        val targetPath = File(workingDirectory, args.path).normalize().absolutePath

        // Use ripgrep to get all files (respects .gitignore)
        val processBuilder = ProcessBuilder("rg", "--files", targetPath)
        processBuilder.directory(File(workingDirectory))

        val process = processBuilder.start()
        val output = process.inputStream.bufferedReader().readText()
        val exitCode = process.waitFor()

        if (exitCode > 1) {
            val error = process.errorStream.bufferedReader().readText()
            validate(false) { "ripgrep failed: $error" }
        }

        val files = output.lines().filter { it.isNotBlank() }

        if (files.isEmpty()) {
            return Result(
                output = "No files found in '$targetPath' (respecting .gitignore).",
                totalFiles = 0
            )
        }

        // Determine effective depth based on repo size
        val effectiveDepth = when {
            files.size <= 50 -> 999 // Show everything for small repos
            files.size >= 400 -> minOf(args.depth, 2) // Clamp for large repos
            else -> args.depth
        }

        // Build tree from file list
        val rootMap = buildMapFromFiles(files, targetPath)

        // Render tree
        val sb = StringBuilder()
        sb.appendLine("🔍 Project structure for: $targetPath")

        // If single file
        if (files.size == 1 && File(files[0]).isFile) {
            sb.appendLine("📄 ${files[0]}")
        } else {
            renderMap(rootMap, sb, "", 1, effectiveDepth)
        }

        return Result(
            output = sb.toString(),
            totalFiles = files.size
        )
    }

    private fun buildMapFromFiles(files: List<String>, basePath: String): Map<String, Any> {
        val root = mutableMapOf<String, Any>()

        for (file in files) {
            // Make path relative to base
            val relativePath = File(file).relativeTo(File(basePath)).path
            val parts = relativePath.split(File.separator)

            var current = root
            for ((index, part) in parts.withIndex()) {
                if (index == parts.lastIndex) {
                    // It's a file
                    current[part] = true
                } else {
                    // It's a directory
                    @Suppress("UNCHECKED_CAST")
                    current = current.getOrPut(part) { mutableMapOf<String, Any>() } as MutableMap<String, Any>
                }
            }
        }
        return root
    }

    @Suppress("UNCHECKED_CAST")
    private fun renderMap(
        node: Map<String, Any>,
        sb: StringBuilder,
        prefix: String,
        currentDepth: Int,
        maxDepth: Int
    ) {
        val keys = node.keys.sortedWith(compareBy<String> { key ->
            // Directories first, then files
            if (node[key] is Boolean) 1 else 0
        }.thenBy { it })

        for ((index, key) in keys.withIndex()) {
            val value = node[key]
            val isLast = index == keys.lastIndex
            val entryPrefix = prefix + if (isLast) "└── " else "├── "
            val nextPrefix = prefix + if (isLast) "    " else "│   "

            if (value is Boolean) {
                // File
                sb.appendLine("$entryPrefix📄 $key")
            } else {
                // Directory
                val subMap = value as Map<String, Any>
                if (currentDepth >= maxDepth) {
                    // Collapsed
                    val (dirs, files) = countDescendants(subMap)
                    sb.appendLine("$entryPrefix📁 $key … ($dirs dirs, $files files)")
                } else {
                    // Expanded
                    sb.appendLine("$entryPrefix📁 $key")
                    renderMap(subMap, sb, nextPrefix, currentDepth + 1, maxDepth)
                }
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun countDescendants(node: Map<String, Any>): Pair<Int, Int> {
        var dirs = 0
        var files = 0

        for (value in node.values) {
            if (value is Boolean) {
                files++
            } else {
                dirs++
                val (d, f) = countDescendants(value as Map<String, Any>)
                dirs += d
                files += f
            }
        }
        return dirs to files
    }
}
