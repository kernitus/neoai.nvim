package com.github.kernitus.neoai

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonElement
import org.msgpack.core.MessagePacker
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

object NeovimBridge {
    private val pendingRequests = ConcurrentHashMap<Int, CompletableDeferred<Any?>>()
    private val requestIdCounter = AtomicInteger(1)
    private lateinit var packer: MessagePacker

    fun init(msgPacker: MessagePacker) {
        this.packer = msgPacker
    }

    suspend fun callLua(
        module: String,
        function: String,
        args: Map<String, Any?>,
    ): Any? {
        val id = requestIdCounter.getAndIncrement()
        val deferred = CompletableDeferred<Any?>()
        pendingRequests[id] = deferred

        // Send the request to Neovim via the existing "nvim_exec_lua" channel
        // We wrap it in a specific type so api.lua knows to execute it and return the result
        synchronized(packer) {
            packer.packArrayHeader(3)
            packer.packInt(2) // Notification
            packer.packString("nvim_exec_lua")

            packer.packArrayHeader(2)
            packer.packString("NeoAI_OnInternalRequest(...)") // New Lua entry point

            packer.packArrayHeader(1)
            packer.packMapHeader(4)
            packer.packString("id")
            packer.packInt(id)
            packer.packString("module")
            packer.packString(module)
            packer.packString("func")
            packer.packString(function)

            // Pack arguments manually or use a helper.
            // For simplicity here, assuming args is a simple map.
            packer.packString("args")
            packMap(packer, args)

            packer.flush()
        }

        // Wait for response (with a 10s timeout to prevent hanging)
        return try {
            withTimeout(10000) {
                deferred.await()
            }
        } finally {
            pendingRequests.remove(id)
        }
    }

    fun handleCallback(
        id: Int,
        result: Any?,
        error: String?,
    ) {
        val deferred = pendingRequests[id] ?: return
        if (error != null) {
            deferred.completeExceptionally(RuntimeException(error))
        } else {
            deferred.complete(result)
        }
    }

    // Helper to pack a Map<String, Any?>
    private fun packMap(
        packer: MessagePacker,
        map: Map<String, Any?>,
    ) {
        packer.packMapHeader(map.size)
        for ((k, v) in map) {
            packer.packString(k)
            when (v) {
                is String -> {
                    packer.packString(v)
                }

                is Int -> {
                    packer.packInt(v)
                }

                is Long -> {
                    packer.packLong(v)
                }

                is Boolean -> {
                    packer.packBoolean(v)
                }

                is List<*> -> {
                    packer.packArrayHeader(v.size)
                    v.forEach { if (it is String) packer.packString(it) else packer.packString(it.toString()) }
                }

                null -> {
                    packer.packNil()
                }

                else -> {
                    packer.packString(v.toString())
                }
            }
        }
    }
}
