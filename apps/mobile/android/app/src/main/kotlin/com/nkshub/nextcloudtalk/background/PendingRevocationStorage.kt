package com.nkshub.nextcloudtalk.background

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors

/**
 * Owns the one secure-storage key shared by foreground and headless engines.
 *
 * Flutter secure storage creates one worker per engine. An engine can vanish
 * while that worker is still finishing a write, so a lock handed to another
 * engine cannot protect this key. Keeping all its operations in this
 * process-wide worker avoids that late-write race. Compare-and-set lets Dart
 * recompute a queue update when another engine changed it first.
 */
object PendingRevocationStorage {
    private const val KEY = "nks.pending_revocations"
    private const val STORAGE_NAMESPACE = "nks_nextcloud_talk"

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var storage: FlutterSecureStorage? = null

    fun read(context: Context, result: MethodChannel.Result) {
        run(result) {
            val secureStorage = secureStorage(context)
            val key = secureStorage.addPrefixToKey(KEY)
            secureStorage.read(key)
        }
    }

    fun compareAndSet(
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
                            "The pending revocation queue could not be updated.",
                            null,
                        )
                    }
                }
            }
        }
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
