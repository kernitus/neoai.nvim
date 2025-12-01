package com.github.kernitus.neoai.aiTools.patch

import kotlinx.serialization.Serializable
import kotlin.contracts.ExperimentalContracts
import kotlin.contracts.contract
import kotlin.math.min

internal data class BatchPatchResult(
    val finalContent: String,
    val appliedCount: Int,
    val skippedCount: Int,
    val unappliedCount: Int,
)

internal fun applyBatchPatches(
    initialContent: String,
    patches: List<FilePatch>,
): BatchPatchResult {
    var currentContent = initialContent
    val pending = patches.toMutableList()
    var appliedCount = 0
    var skippedCount = 0

    // 1. Handle Inserts
    val inserts = pending.filter { it.original.isEmpty() }
    pending.removeAll(inserts)

    if (inserts.isNotEmpty()) {
        val combinedInserts = inserts.joinToString("\n") { it.replacement }
        currentContent =
            if (currentContent.isEmpty()) {
                combinedInserts
            } else {
                combinedInserts + "\n" + currentContent
            }
        appliedCount += inserts.size
    }

    // 2. Handle Replacements
    val maxPasses = 3
    for (pass in 1..maxPasses) {
        if (pending.isEmpty()) break

        val tokens = TokenList(tokenize(currentContent))
        val candidates = mutableListOf<MatchCandidate>()
        val stillPending = mutableListOf<FilePatch>()

        // A. Find matches
        for (patch in pending) {
            // Lua-style "dedent" for search is handled implicitly by token matching
            // ignoring specific whitespace characters.
            val originalTokens = TokenList(tokenize(patch.original))

            val matchRange =
                tokens.find(originalTokens) { fst, snd ->
                    if (fst.isWhitespace && snd.isWhitespace) {
                        true
                    } else {
                        fst.content.equals(snd.content, ignoreCase = true)
                    }
                }

            if (matchRange != null) {
                candidates.add(MatchCandidate(patch, matchRange))
            } else {
                val replacementTokens = TokenList(tokenize(patch.replacement))
                if (tokens.find(replacementTokens) != null) {
                    skippedCount++
                } else {
                    stillPending.add(patch)
                }
            }
        }

        // B. Sort & C. Select non-overlapping
        candidates.sortBy { it.range.first }
        val toApply = mutableListOf<MatchCandidate>()
        var lastEnd = -1

        for (candidate in candidates) {
            if (candidate.range.first > lastEnd) {
                toApply.add(candidate)
                lastEnd = candidate.range.last
            } else {
                stillPending.add(candidate.patch)
            }
        }

        if (toApply.isEmpty()) {
            pending.clear()
            pending.addAll(stillPending)
            break
        }

        // D. Apply Bottom-Up
        toApply.sortByDescending { it.range.first }

        var currentTokens = tokens
        for (match in toApply) {
            // --- SMART INDENTATION LOGIC START ---
            // 1. Find the indentation of the line where the match starts in the original file
            val startTokenIndex = match.range.first
            val startToken = currentTokens.tokens[startTokenIndex]

            // We need the raw text to look backwards for newlines
            val matchStartIndex = startToken.range.first
            val indentation = detectIndentation(currentContent, matchStartIndex)

            // 2. Adjust the replacement string to match that indentation
            val adjustedReplacement = adjustReplacementIndentation(match.patch.replacement, indentation)
            // --- SMART INDENTATION LOGIC END ---

            val replacementTokens = TokenList(tokenize(adjustedReplacement))
            currentTokens = currentTokens.replace(match.range, replacementTokens)
            appliedCount++
        }

        currentContent = currentTokens.text
        pending.clear()
        pending.addAll(stillPending)
    }

    return BatchPatchResult(
        finalContent = currentContent,
        appliedCount = appliedCount,
        skippedCount = skippedCount,
        unappliedCount = pending.size,
    )
}

/**
 * Looks backwards from [startIndex] in [content] to find the beginning of the line
 * and returns the whitespace prefix of that line.
 */
private fun detectIndentation(
    content: String,
    startIndex: Int,
): String {
    if (startIndex <= 0) return ""

    var i = startIndex - 1
    while (i >= 0) {
        val char = content[i]
        if (char == '\n' || char == '\r') {
            break
        }
        i--
    }

    // i is now at the newline (or -1). The line starts at i + 1.
    val lineStart = i + 1
    if (lineStart >= content.length) return ""

    val sb = StringBuilder()
    for (j in lineStart until content.length) {
        val c = content[j]
        if (c == ' ' || c == '\t') {
            sb.append(c)
        } else {
            break
        }
    }
    return sb.toString()
}

/**
 * Dedents the replacement block (removes common leading whitespace)
 * and then re-indents it with the [targetIndentation].
 */
private fun adjustReplacementIndentation(
    replacement: String,
    targetIndentation: String,
): String {
    if (replacement.isEmpty()) return ""

    val lines = replacement.lines()
    if (lines.isEmpty()) return ""

    // 1. Calculate minimum common indent in the replacement block
    // (ignoring empty lines)
    var minIndent = Int.MAX_VALUE
    var hasContent = false

    for (line in lines) {
        if (line.isNotBlank()) {
            hasContent = true
            val indentLen = line.takeWhile { it == ' ' || it == '\t' }.length
            minIndent = min(minIndent, indentLen)
        }
    }

    if (!hasContent) return replacement // All whitespace or empty

    // 2. Reconstruct with new indentation
    return lines.joinToString("\n") { line ->
        if (line.isBlank()) {
            ""
        } else {
            // Remove the common indent, then add the target indent
            val stripped = if (line.length >= minIndent) line.substring(minIndent) else line
            targetIndentation + stripped
        }
    }
}

private data class MatchCandidate(
    val patch: FilePatch,
    val range: IntRange,
)

internal fun applyTokenNormalisedPatch(
    content: String,
    patch: FilePatch,
): PatchApplyResult {
    // Reuse the batch logic for consistency, even for single edits
    val result = applyBatchPatches(content, listOf(patch))

    return if (result.appliedCount > 0) {
        PatchApplyResult.Success(result.finalContent)
    } else if (result.skippedCount > 0) {
        PatchApplyResult.Failure.OriginalNotFound // Or a specific "AlreadyApplied" if you want to add that state
    } else {
        PatchApplyResult.Failure.OriginalNotFound
    }
}

/**
 * Represents the result of applying a patch to a file
 */
@Serializable
public sealed interface PatchApplyResult {
    @Serializable
    public data class Success(
        val updatedContent: String,
    ) : PatchApplyResult

    @Serializable
    public sealed class Failure(
        public val reason: String,
    ) : PatchApplyResult {
        @Serializable
        public object OriginalNotFound : Failure(
            """
            The original text to replace was not found in the file content. 
            Consider re-reading the file to check if the original has changed since last read.
            """,
        )
    }
}

@OptIn(ExperimentalContracts::class)
internal fun PatchApplyResult.isSuccess(): Boolean {
    contract {
        returns(true) implies (this@isSuccess is PatchApplyResult.Success)
        returns(false) implies (this@isSuccess is PatchApplyResult.Failure)
    }
    return this is PatchApplyResult.Success
}

internal fun tokenize(
    text: String,
    separatorPattern: Regex = Regex("(\\r\\n|\\r|\\n)|[\\t ]+|[(){}\\[\\];,.:=<>/\\\\^$\"']"),
): List<Token> {
    val tokens = mutableListOf<Token>()
    var start = 0
    val separators = separatorPattern.findAll(text)
    for (separator in separators) {
        if (separator.range.isEmpty()) continue
        tokens.add(Token(text.substring(start, separator.range.first), start until separator.range.first))
        tokens.add(Token(separator.value, separator.range))
        start = separator.range.endInclusive + 1
    }
    if (start < text.length) {
        tokens.add(Token(text.substring(start), start until text.length))
    }
    return tokens.filterNot { it.range.isEmpty() }
}

internal data class TokenList(
    val tokens: List<Token>,
) {
    val text = tokens.joinToString("") { it.content }

    fun find(
        other: TokenList,
        equals: (fst: Token, snd: Token) -> Boolean = { fst, snd -> fst.content == snd.content },
    ): IntRange? {
        if (other.tokens.isEmpty()) return null
        outer@ for (i in 0..(tokens.size - other.tokens.size)) {
            for (j in other.tokens.indices) {
                if (!equals(tokens[i + j], other.tokens[j])) {
                    continue@outer
                }
            }
            return i until (i + other.tokens.size)
        }
        return null
    }

    fun replace(
        range: IntRange,
        replacement: TokenList,
    ): TokenList =
        TokenList(
            tokens.subList(0, range.start) + replacement.tokens +
                tokens.subList(
                    range.endInclusive + 1,
                    this.tokens.size,
                ),
        )
}

internal data class Token(
    val content: String,
    val range: IntRange,
) {
    val isWhitespace: Boolean = content.isBlank()
}
