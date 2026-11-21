package com.nkshub.nextcloudtalk.attachments

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.WeakHashMap

/** Both engine messengers enter this queue on Android's main thread. */
internal class AttachmentRuntimeQueue {
    private data class Reservation(
        val client: Any,
        val id: String,
        val grant: (Boolean) -> Unit,
    )

    private val waiting = ArrayDeque<Reservation>()
    private var owner: Reservation? = null

    fun acquire(client: Any, id: String, grant: (Boolean) -> Unit) {
        waiting.addLast(Reservation(client, id, grant))
        grantNext()
    }

    fun release(client: Any, id: String) {
        val current = owner
        if (current != null && current.client === client && current.id == id) {
            owner = null
            grantNext()
            return
        }
        val pending = waiting.firstOrNull { it.client === client && it.id == id } ?: return
        waiting.remove(pending)
        pending.grant(false)
    }

    fun detach(client: Any) {
        waiting.removeAll { it.client === client }
        if (owner?.client === client) {
            owner = null
            grantNext()
        }
    }

    private fun grantNext() {
        if (owner != null) return
        val next = waiting.removeFirstOrNull() ?: return
        owner = next
        next.grant(true)
    }
}

internal object AttachmentRuntimeChannel {
    private const val NAME = "com.nkshub.nextcloudtalk/attachment_runtime"
    private val queue = AttachmentRuntimeQueue()
    private val attached = WeakHashMap<FlutterEngine, Boolean>()

    fun attach(engine: FlutterEngine) {
        if (attached.put(engine, true) != null) return
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        val main = Handler(Looper.getMainLooper())
        var client = Any()
        channel.setMethodCallHandler { call, result ->
            val id = call.arguments as? String
            if (id.isNullOrEmpty()) {
                result.error("invalidReservation", "Missing reservation ID", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "acquire" -> queue.acquire(client, id) { result.success(it) }
                "release" -> {
                    queue.release(client, id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        fun detach() {
            val previous = client
            client = Any()
            // Flutter invokes the listener before it detaches the old Dart executor.
            main.post { queue.detach(previous) }
        }

        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = detach()

            override fun onEngineWillDestroy() {
                channel.setMethodCallHandler(null)
                attached.remove(engine)
                detach()
            }
        })
    }
}
