package com.nkshub.nextcloudtalk.background

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.WeakHashMap

/** Used only on the main thread shared by the attached engine messengers. */
internal class TextSendOwners {
    private data class Claim(val client: Any, val token: String)

    private val owners = mutableMapOf<Pair<String, String>, Claim>()

    fun acquire(client: Any, account: String, id: String, token: String): Boolean {
        return owners.putIfAbsent(account to id, Claim(client, token)) == null
    }

    fun release(client: Any, account: String, id: String, token: String) {
        val key = account to id
        val owner = owners[key] ?: return
        if (owner.client === client && owner.token == token) owners.remove(key)
    }

    fun active(account: String): List<String> =
        owners.keys.filter { it.first == account }.map { it.second }

    fun detach(client: Any) {
        owners.entries.removeAll { it.value.client === client }
    }
}

internal class TextSendOwnershipBinding(
    private val owners: TextSendOwners,
    private val setHandler: (MethodChannel.MethodCallHandler?) -> Unit,
    private val postDetach: (() -> Unit) -> Unit,
) {
    private var currentClient: Any? = null

    init {
        register()
    }

    private fun register() {
        val client = Any()
        currentClient = client
        setHandler(MethodChannel.MethodCallHandler { call, result ->
            // The messenger may already have queued a callback for the retired client.
            if (currentClient !== client) {
                result.error("retiredTextSendOwner", "The text send engine is retired", null)
                return@MethodCallHandler
            }
            val account = call.argument<String>("accountId")
            if (account.isNullOrEmpty()) {
                result.error("invalidTextSend", "Missing account ID", null)
                return@MethodCallHandler
            }
            when (call.method) {
                "active" -> result.success(owners.active(account))
                "acquire", "release" -> {
                    val id = call.argument<String>("operationId")
                    val token = call.argument<String>("token")
                    if (id.isNullOrEmpty() || token.isNullOrEmpty()) {
                        result.error("invalidTextSend", "Missing reservation ID", null)
                    } else if (call.method == "acquire") {
                        result.success(owners.acquire(client, account, id, token))
                    } else {
                        owners.release(client, account, id, token)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        })
    }

    fun restart() {
        detach()
        register()
    }

    fun destroy() {
        setHandler(null)
        detach()
    }

    private fun detach() {
        val retired = currentClient ?: return
        currentClient = null
        // The engine listener runs before the old Dart executor detaches.
        postDetach { owners.detach(retired) }
    }
}

internal object TextSendOwnershipChannel {
    private const val NAME = "com.nkshub.nextcloudtalk/text_sends"
    private val owners = TextSendOwners()
    private val attached = WeakHashMap<FlutterEngine, Boolean>()

    fun attach(engine: FlutterEngine) {
        if (attached.put(engine, true) != null) return
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        val main = Handler(Looper.getMainLooper())
        val binding = TextSendOwnershipBinding(owners, channel::setMethodCallHandler) { work ->
            main.post { work() }
        }

        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = binding.restart()

            override fun onEngineWillDestroy() {
                binding.destroy()
                attached.remove(engine)
            }
        })
    }
}
