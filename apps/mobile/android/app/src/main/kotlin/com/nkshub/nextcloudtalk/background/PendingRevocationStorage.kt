package com.nkshub.nextcloudtalk.background

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.WeakHashMap
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors

/**
 * Owns the credentials and revocation records shared by Android engines.
 *
 * Flutter secure storage creates one worker per engine. An engine can vanish
 * while that worker is still finishing a write. Here every vault operation
 * runs before the worker releases the retired engine's claims. Recovery can
 * then inspect the final vault state before changing a durable reservation.
 */
object PendingRevocationStorage {
    private const val CHANNEL = "com.nkshub.nextcloudtalk/credential_vault"
    private const val KEY = "nks.pending_revocations"
    private const val STORAGE_NAMESPACE = "nks_nextcloud_talk"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val attached = WeakHashMap<FlutterEngine, Boolean>()
    private val claims = PendingRevocationOwners()
    private var storage: FlutterSecureStorage? = null
    private var credentials: AndroidCredentialRecords? = null

    fun attach(engine: FlutterEngine, context: Context) {
        if (attached.put(engine, true) != null) return
        val appContext = context.applicationContext
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        var client = Any()
        channel.setMethodCallHandler { call, result -> handle(appContext, client, call, result) }

        fun retire() {
            val retired = client
            client = Any()
            executor.execute { claims.detach(retired) }
        }

        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = retire()

            override fun onEngineWillDestroy() {
                channel.setMethodCallHandler(null)
                attached.remove(engine)
                retire()
            }
        })
    }

    private fun handle(
        context: Context,
        client: Any,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "readPendingRevocations" -> read(context, result)
            "compareAndSetPendingRevocations" -> compareAndSet(
                context,
                call.argument<String>("expected"),
                call.argument<String>("updated"),
                result,
            )
            "claimRevocation", "releaseRevocationClaim" -> run(result) {
                val id = requireNotNull(call.argument<String>("id"))
                val token = requireNotNull(call.argument<String>("token"))
                if (call.method == "claimRevocation") {
                    claims.claim(client, id, token)
                } else {
                    claims.release(client, id, token)
                    null
                }
            }
            "readAppPassword", "writeAppPassword", "deleteAppPassword" -> run(result) {
                val accountId = requireNotNull(call.argument<String>("accountId"))
                val records = credentialRecords(context)
                when (call.method) {
                    "readAppPassword" -> records.read(accountId)
                    "writeAppPassword" -> {
                        records.write(accountId, requireNotNull(call.argument<String>("password")))
                        null
                    }
                    else -> {
                        records.delete(accountId)
                        null
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun read(context: Context, result: MethodChannel.Result) {
        run(result) {
            val secureStorage = secureStorage(context)
            val key = secureStorage.addPrefixToKey(KEY)
            secureStorage.read(key)
        }
    }

    private fun compareAndSet(
        context: Context,
        expected: String?,
        updated: String?,
        result: MethodChannel.Result,
    ) {
        run(result) {
            val secureStorage = secureStorage(context)
            val key = secureStorage.addPrefixToKey(KEY)
            PendingRevocationCompareAndSet(
                read = { secureStorage.read(key) },
                write = { value ->
                    if (value == null) {
                        secureStorage.delete(key)
                    } else {
                        secureStorage.write(key, value)
                    }
                },
            ).compareAndSet(expected, updated)
        }
    }

    private fun run(result: MethodChannel.Result, operation: () -> Any?) {
        executor.execute {
            try {
                val value = operation()
                mainHandler.post { runCatching { result.success(value) } }
            } catch (error: Exception) {
                mainHandler.post {
                    runCatching {
                        result.error(
                            "pending_revocation_storage",
                            "The credential vault operation failed.",
                            null,
                        )
                    }
                }
            }
        }
    }

    private fun credentialRecords(context: Context): AndroidCredentialRecords {
        credentials?.let { return it }
        val store = secureStorage(context)
        return AndroidCredentialRecords(
            readKey = { key -> store.read(store.addPrefixToKey(key)) },
            writeKey = { key, value -> store.write(store.addPrefixToKey(key), value) },
            deleteKey = { key -> store.delete(store.addPrefixToKey(key)) },
        ).also { credentials = it }
    }

    private fun secureStorage(context: Context): FlutterSecureStorage {
        storage?.let { return it }

        val created = FlutterSecureStorage(context.applicationContext)
        val initialized = CompletableFuture<FlutterSecureStorage>()
        created.initialize(
            FlutterSecureStorageConfig(
                mapOf(
                    "resetOnError" to "false",
                    "migrateOnAlgorithmChange" to "true",
                    "migrateWithBackup" to "true",
                    "enforceBiometrics" to "false",
                    "keyCipherAlgorithm" to "RSA_ECB_OAEPwithSHA_256andMGF1Padding",
                    "storageCipherAlgorithm" to "AES_GCM_NoPadding",
                    "biometricType" to "biometricOrDeviceCredential",
                    "requireBiometricConfirmation" to "true",
                    "storageNamespace" to STORAGE_NAMESPACE,
                ),
            ),
            object : SecurePreferencesCallback<Void> {
                override fun onSuccess(value: Void?) {
                    initialized.complete(created)
                }

                override fun onError(error: Exception) {
                    initialized.completeExceptionally(error)
                }
            },
        )
        return initialized.get().also { storage = it }
    }
}

/** Called on the vault worker in the same order as reads and writes. */
internal class PendingRevocationOwners {
    private data class Claim(val client: Any, val token: String)

    private val owners = mutableMapOf<String, Claim>()

    fun claim(client: Any, id: String, token: String): Boolean {
        if (owners.containsKey(id)) return false
        owners[id] = Claim(client, token)
        return true
    }

    fun release(client: Any, id: String, token: String) {
        val owner = owners[id] ?: return
        if (owner.client === client && owner.token == token) owners.remove(id)
    }

    fun detach(client: Any) {
        owners.entries.removeAll { it.value.client === client }
    }
}

/** Uses the existing Dart vault's keys and migration order. */
internal class AndroidCredentialRecords(
    private val readKey: (String) -> String?,
    private val writeKey: (String, String) -> Unit,
    private val deleteKey: (String) -> Unit,
) {
    private val migrated = mutableSetOf<String>()

    fun read(accountId: String): String? {
        migrate(accountId)
        return readKey(currentKey(accountId))
    }

    fun write(accountId: String, password: String) {
        migrate(accountId)
        writeKey(currentKey(accountId), password)
    }

    fun delete(accountId: String) {
        migrate(accountId)
        deleteKey(currentKey(accountId))
    }

    private fun migrate(accountId: String) {
        if (accountId in migrated) return
        val versionKey = "credential.account.$accountId.version"
        val marker = readKey(versionKey)
        val version = if (marker == null) 1 else marker.trim().toIntOrNull()
        check(version == 1 || version == 2)

        val legacyKey = "account.$accountId.appPassword"
        val currentKey = currentKey(accountId)
        val legacy = readKey(legacyKey)
        val current = readKey(currentKey)
        check(legacy == null || current == null || legacy == current)
        if (current == null && legacy != null) {
            writeKey(currentKey, legacy)
            check(readKey(currentKey) == legacy)
        }
        if (version == 1) {
            writeKey(versionKey, "2")
            check(readKey(versionKey) == "2")
        }
        if (legacy != null) deleteKey(legacyKey)
        migrated.add(accountId)
    }

    private fun currentKey(accountId: String) = "credential.v2.account.$accountId.appPassword"
}

internal class PendingRevocationCompareAndSet(
    private val read: () -> String?,
    private val write: (String?) -> Unit,
) {
    fun compareAndSet(expected: String?, updated: String?): Boolean {
        if (read() != expected) {
            return false
        }
        write(updated)
        return true
    }
}
