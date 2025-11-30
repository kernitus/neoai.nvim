package com.github.kernitus.neoai
package com.github.kernitus.neoai

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentHashMap

@Serializable
data class SessionInfo(
    val id: String,
    val title: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("workspace_path") val workspacePath: String,
    @SerialName("database_path") val databasePath: String,
    @SerialName("message_count") val messageCount: Long,
)

@Serializable
data class MessageRecord(
    val id: Long,
    val type: String,
    val content: String,
    val metadata: JsonElement? = null,
    @SerialName("tool_call_id") val toolCallId: String? = null,
    @SerialName("tool_calls") val toolCalls: JsonElement? = null,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
data class AppendResponse(
    val message: MessageRecord,
    val session: SessionInfo,
)

@Serializable
data class LoadResponse(
    val messages: List<MessageRecord>,
    val total: Long,
    val session: SessionInfo,
)

@Serializable
data class ClearResponse(
    val cleared: Boolean = true,
    val session: SessionInfo,
)

@Serializable
data class StatsResponse(
    @SerialName("database_path") val databasePath: String,
    val messages: Long,
    val bytes: Long,
    val session: SessionInfo,
)

data class IncomingMessage(
    val type: String,
    val content: String,
    val metadataJson: String?,
    val toolCallId: String?,
    val toolCallsJson: String?,
    val createdAt: String?,
)

/**
 * Persistent chat storage backed by newline-delimited JSON files.
 * Each workspace (git project or Neovim cwd) maps to its own file so we never need a sessions index.
 */
object StorageManager {
    internal val json = Json {
        prettyPrint = false
        encodeDefaults = false
        ignoreUnknownKeys = true
    }

    private val isoFormatter: DateTimeFormatter = DateTimeFormatter.ISO_OFFSET_DATE_TIME
    private val stores = ConcurrentHashMap<String, WorkspaceStore>()

    private fun nowIso(): String = isoFormatter.format(Instant.now().atOffset(ZoneOffset.UTC))

    private fun slugFor(path: String): String {
        val digest = MessageDigest.getInstance("SHA-1")
        val bytes = digest.digest(path.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun resolveBase(path: String): File {
        if (path.isBlank()) {
            val fallback = File(System.getProperty("user.home"), ".neoai_chats")
            fallback.mkdirs()
            return fallback
        }
        val raw = File(path)
        if (raw.isDirectory) {
            raw.mkdirs()
            return raw
        }
        val parent = raw.parentFile ?: File(System.getProperty("user.home"))
        val stem = raw.name.substringBeforeLast('.')
        val dir = File(parent, if (stem.isBlank()) "neoai_chats" else "${stem}_sessions")
        dir.mkdirs()
        return dir
    }

    fun initialiseStorage(basePath: String, workspacePath: String): SessionInfo {
        val resolvedBase = resolveBase(basePath)
        val key = workspacePath.ifBlank { resolvedBase.absolutePath }
        val store = stores.compute(key) { _, existing ->
            existing?.takeIf { it.baseDir.absolutePath == resolvedBase.absolutePath }
                ?: WorkspaceStore(resolvedBase, key, slugFor(key), json, ::nowIso)
        } ?: error("Failed to create workspace store")
        return store.sessionInfo()
    }

    private fun workspaceStore(workspacePath: String): WorkspaceStore {
        val key = workspacePath.ifBlank { stores.keys.firstOrNull() }
            ?: throw IllegalStateException("Storage not initialised for workspace: $workspacePath")
        return stores[key] ?: throw IllegalStateException("Storage key not found: $key")
    }

    fun appendMessage(workspacePath: String, incoming: IncomingMessage): AppendResponse {
        val store = workspaceStore(workspacePath)
        val stored = store.append(incoming)
        return AppendResponse(
            message = stored.toRecord(json),
            session = store.sessionInfo(),
        )
    }

    fun loadMessages(workspacePath: String, limit: Int?): LoadResponse {
        val store = workspaceStore(workspacePath)
        val records = store.read(limit).map { it.toRecord(json) }
        return LoadResponse(
            messages = records,
            total = store.messageCount,
            session = store.sessionInfo(),
        )
    }

    fun clear(workspacePath: String): ClearResponse {
        val store = workspaceStore(workspacePath)
        store.clear()
        return ClearResponse(cleared = true, session = store.sessionInfo())
    }

    fun stats(workspacePath: String): StatsResponse {
        val store = workspaceStore(workspacePath)
        return StatsResponse(
            databasePath = store.filePath,
            messages = store.messageCount,
            bytes = store.fileSize,
            session = store.sessionInfo(),
        )
    }
}

private class WorkspaceStore(
    val baseDir: File,
    private val workspacePath: String,
    private val slug: String,
    private val json: Json,
    private val nowFn: () -> String,
) {
    private val lock = Any()
    private val file = File(baseDir, "$slug.jsonl")
    private var meta = ChatMeta(
        sessionId = slug,
        workspacePath = workspacePath,
        title = deriveTitle(workspacePath),
        createdAt = nowFn(),
    )
    var messageCount: Long = 0
        private set
    var fileSize: Long = 0
        private set
    var filePath: String = file.absolutePath
        private set
    private var lastId: Long = 0

    init {
        baseDir.mkdirs()
        if (!file.exists()) {
            writeMeta(overwrite = true)
        } else {
            loadExisting()
        }
    }

    private fun deriveTitle(path: String): String {
        val trimmed = path.trim().trimEnd('/', '\\')
        if (trimmed.isEmpty()) return "NeoAI Chat"
        val idx = trimmed.indexOfLast { it == '/' || it == '\\' }
        return if (idx == -1) trimmed else trimmed.substring(idx + 1)
    }

    private fun loadExisting() {
        if (file.length() == 0L) {
            writeMeta(overwrite = true)
            return
        }
        val firstLine = file.bufferedReader().use { it.readLine() }
        val parsedMeta = runCatching {
            json.decodeFromString(ChatMeta.serializer(), firstLine?.trim().orEmpty())
        }.getOrNull()
        if (parsedMeta == null || parsedMeta.kind != "meta") {
            writeMeta(overwrite = false)
        } else {
            meta = parsedMeta
        }
        refreshCounters()
    }

    private fun writeMeta(overwrite: Boolean) {
        val metaLine = json.encodeToString(meta)
        synchronized(lock) {
            if (overwrite) {
                file.writeText(metaLine + "\n")
            } else {
                val existing = file.readText()
                file.writeText(metaLine + "\n" + existing)
            }
            messageCount = 0
            lastId = 0
            filePath = file.absolutePath
            fileSize = file.length()
        }
    }

    private fun refreshCounters() {
        var count = 0L
        var lastLine: String? = null
        file.bufferedReader().useLines { lines ->
            lines.drop(1).forEach { line ->
                val trimmed = line.trim()
                if (trimmed.isEmpty()) return@forEach
                count++
                lastLine = trimmed
            }
        }
        messageCount = count
        lastId = lastLine?.let {
            runCatching { json.decodeFromString(StoredMessage.serializer(), it).id }.getOrNull()
        } ?: 0
        fileSize = file.length()
        filePath = file.absolutePath
    }

    fun sessionInfo(): SessionInfo = SessionInfo(
        id = meta.sessionId,
        title = meta.title,
        createdAt = meta.createdAt,
        workspacePath = meta.workspacePath,
        databasePath = file.absolutePath,
        messageCount = messageCount,
    )

    fun append(incoming: IncomingMessage): StoredMessage {
        val createdAt = incoming.createdAt?.takeIf { it.isNotBlank() } ?: nowFn()
        val stored = StoredMessage(
            id = synchronized(lock) { ++lastId },
            type = incoming.type,
            content = incoming.content,
            metadataJson = incoming.metadataJson?.takeIf { it.isNotBlank() },
            toolCallId = incoming.toolCallId?.takeIf { it.isNotBlank() },
            toolCallsJson = incoming.toolCallsJson?.takeIf { it.isNotBlank() },
            createdAt = createdAt,
        )
        val line = json.encodeToString(stored) + "\n"
        synchronized(lock) {
            file.appendText(line)
            messageCount += 1
            fileSize = file.length()
        }
        return stored
    }

    fun read(limit: Int?): List<StoredMessage> {
        if (!file.exists()) return emptyList()
        val window = ArrayDeque<String>()
        val cap = limit ?: 0
        file.bufferedReader().useLines { lines ->
            var isFirst = true
            lines.forEach { line ->
                if (isFirst) {
                    isFirst = false
                    return@forEach
                }
                val trimmed = line.trim()
                if (trimmed.isEmpty()) return@forEach
                window.addLast(trimmed)
                if (cap > 0 && window.size > cap) {
                    window.removeFirst()
                }
            }
        }
        return window.mapNotNull {
            runCatching { json.decodeFromString(StoredMessage.serializer(), it) }.getOrNull()
        }
    }

    fun clear() {
        meta = meta.copy(createdAt = nowFn())
        writeMeta(overwrite = true)
    }
}

@Serializable
private data class ChatMeta(
    val kind: String = "meta",
    @SerialName("session_id") val sessionId: String,
    @SerialName("workspace_path") val workspacePath: String,
    val title: String,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
private data class StoredMessage(
    val id: Long,
    val type: String,
    val content: String,
    @SerialName("metadata") val metadataJson: String? = null,
    @SerialName("tool_call_id") val toolCallId: String? = null,
    @SerialName("tool_calls") val toolCallsJson: String? = null,
    @SerialName("created_at") val createdAt: String,
) {
    fun toRecord(json: Json): MessageRecord {
        val metadata = metadataJson?.let { runCatching { json.parseToJsonElement(it) }.getOrNull() }
        val calls = toolCallsJson?.let { runCatching { json.parseToJsonElement(it) }.getOrNull() }
        return MessageRecord(
            id = id,
            type = type,
            content = content,
            metadata = metadata ?: JsonNull,
            toolCallId = toolCallId,
            toolCalls = calls ?: JsonNull,
            createdAt = createdAt,
        ).normalised()
    }
}

private fun MessageRecord.normalised(): MessageRecord {
    val cleanMeta = when (metadata) {
        is JsonNull -> null
        is JsonObject -> metadata
        is JsonPrimitive -> metadata
        else -> metadata
    }
    val cleanCalls = when (toolCalls) {
        is JsonNull -> null
        else -> toolCalls
    }
    return copy(metadata = cleanMeta, toolCalls = cleanCalls)
}
