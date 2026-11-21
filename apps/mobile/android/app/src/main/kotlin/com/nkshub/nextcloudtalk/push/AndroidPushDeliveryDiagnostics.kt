package com.nkshub.nextcloudtalk.push

import android.content.Context
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

internal enum class PushDeliveryTransport(val wireName: String) {
    PROXY("proxy"),
    WEB_PUSH("webPush"),
    ;

    companion object {
        fun fromWireName(value: String): PushDeliveryTransport? = entries.firstOrNull {
            it.wireName == value
        }
    }
}

internal enum class PushDisplayOutcome {
    POSTED,
    SUPPRESSED_OPEN_ROOM,
    FILTERED_OTHER_APP,
    NOTIFICATIONS_DISABLED,
    MISSING_FIELDS,
    INVALID_PAYLOAD,
}

internal data class PushDeliveryDiagnostics(
    val lastTransportReceivedAtMillis: Long? = null,
    val lastDecryptedAtMillis: Long? = null,
    val lastDisplayAtMillis: Long? = null,
    val displayOutcome: PushDisplayOutcome? = null,
    val lastTransportFailureAtMillis: Long? = null,
    val transportFailureClass: String? = null,
    val lastAccountFailureAtMillis: Long? = null,
    val accountFailureClass: String? = null,
) {
    fun toChannelMap(): Map<String, Any?> = mapOf(
        "lastTransportReceivedAtMillis" to lastTransportReceivedAtMillis,
        "lastDecryptedAtMillis" to lastDecryptedAtMillis,
        "lastDisplayAtMillis" to lastDisplayAtMillis,
        "displayOutcome" to displayOutcome?.name,
        "lastTransportFailureAtMillis" to lastTransportFailureAtMillis,
        "transportFailureClass" to transportFailureClass,
        "lastAccountFailureAtMillis" to lastAccountFailureAtMillis,
        "accountFailureClass" to accountFailureClass,
    )
}

/**
 * Persists only stage timestamps and fixed result names. Message content,
 * notification ids, room tokens and raw account ids never enter this store.
 */
internal class AndroidPushDeliveryDiagnosticsStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES,
        Context.MODE_PRIVATE,
    )

    fun recordReceived(transport: PushDeliveryTransport, atMillis: Long = now()) {
        bestEffort {
            updateTimestamp(transportKey(transport, RECEIVED_AT), atMillis)
        }
    }

    fun recordDecrypted(
        transport: PushDeliveryTransport,
        accountId: String,
        atMillis: Long = now(),
    ) {
        bestEffort {
            updateTimestamp(accountKey(accountPrefix(transport, accountId), DECRYPTED_AT), atMillis)
        }
    }

    fun recordDisplay(
        transport: PushDeliveryTransport,
        accountId: String,
        outcome: PushDisplayOutcome,
        atMillis: Long = now(),
    ) {
        bestEffort {
            val prefix = accountPrefix(transport, accountId)
            val timestampKey = accountKey(prefix, DISPLAY_AT)
            synchronized(lock) {
                if (atMillis < storedLong(timestampKey)) {
                    return@synchronized
                }
                preferences.edit()
                    .putLong(timestampKey, atMillis)
                    .putString(accountKey(prefix, DISPLAY_OUTCOME), outcome.name)
                    .apply()
            }
        }
    }

    fun recordFailure(
        transport: PushDeliveryTransport,
        failureClass: String,
        atMillis: Long = now(),
        accountId: String? = null,
    ) {
        bestEffort {
            val prefix = accountId?.let { accountPrefix(transport, it) }
            val timestampKey = prefix?.let { accountKey(it, FAILURE_AT) }
                ?: transportKey(transport, FAILURE_AT)
            val classKey = prefix?.let { accountKey(it, FAILURE_CLASS) }
                ?: transportKey(transport, FAILURE_CLASS)
            synchronized(lock) {
                if (atMillis < storedLong(timestampKey)) {
                    return@synchronized
                }
                preferences.edit()
                    .putLong(timestampKey, atMillis)
                    .putString(classKey, failureClass)
                    .apply()
            }
        }
    }

    fun read(
        transport: PushDeliveryTransport,
        accountId: String,
    ): PushDeliveryDiagnostics = try {
        synchronized(lock) {
            val prefix = accountPrefix(transport, accountId)
            val globalFailure = failure(
                transportKey(transport, FAILURE_AT),
                transportKey(transport, FAILURE_CLASS),
            )
            val accountFailure = failure(
                accountKey(prefix, FAILURE_AT),
                accountKey(prefix, FAILURE_CLASS),
            )
            PushDeliveryDiagnostics(
                lastTransportReceivedAtMillis = timestamp(transportKey(transport, RECEIVED_AT)),
                lastDecryptedAtMillis = timestamp(accountKey(prefix, DECRYPTED_AT)),
                lastDisplayAtMillis = timestamp(accountKey(prefix, DISPLAY_AT)),
                displayOutcome = storedString(accountKey(prefix, DISPLAY_OUTCOME))
                    ?.let { runCatching { PushDisplayOutcome.valueOf(it) }.getOrNull() },
                lastTransportFailureAtMillis = globalFailure?.first,
                transportFailureClass = globalFailure?.second,
                lastAccountFailureAtMillis = accountFailure?.first,
                accountFailureClass = accountFailure?.second,
            )
        }
    } catch (_: RuntimeException) {
        PushDeliveryDiagnostics()
    }

    internal fun clearForTests() {
        preferences.edit().clear().commit()
    }

    private fun updateTimestamp(key: String, atMillis: Long) {
        synchronized(lock) {
            if (atMillis >= storedLong(key)) {
                preferences.edit().putLong(key, atMillis).apply()
            }
        }
    }

    private fun timestamp(key: String): Long? = storedLong(key)
        .takeUnless { it == Long.MIN_VALUE }

    private fun failure(timestampKey: String, classKey: String): Pair<Long, String>? {
        val atMillis = timestamp(timestampKey) ?: return null
        val failureClass = storedString(classKey) ?: return null
        return atMillis to failureClass
    }

    private fun storedLong(key: String): Long = try {
        preferences.getLong(key, Long.MIN_VALUE)
    } catch (_: ClassCastException) {
        Long.MIN_VALUE
    }

    private fun storedString(key: String): String? = try {
        preferences.getString(key, null)
    } catch (_: ClassCastException) {
        null
    }

    private inline fun bestEffort(write: () -> Unit) {
        try {
            write()
        } catch (_: RuntimeException) {
            // Diagnostics must never stop the notification path they observe.
        }
    }

    private fun transportKey(transport: PushDeliveryTransport, field: String): String =
        "${transport.wireName}.$field"

    private fun accountPrefix(
        transport: PushDeliveryTransport,
        accountId: String,
    ): String = "${transport.wireName}.account.${accountDigest(accountId)}"

    private fun accountKey(prefix: String, field: String): String = "$prefix.$field"

    private fun accountDigest(accountId: String): String = MessageDigest
        .getInstance("SHA-256")
        .digest(accountId.toByteArray(StandardCharsets.UTF_8))
        .joinToString(separator = "") {
            (it.toInt() and 0xff).toString(16).padStart(2, '0')
        }

    internal companion object {
        const val PREFERENCES = "android_push_delivery_diagnostics"

        private val lock = Any()
        private fun now(): Long = System.currentTimeMillis()

        private const val RECEIVED_AT = "receivedAt"
        private const val DECRYPTED_AT = "decryptedAt"
        private const val DISPLAY_AT = "displayAt"
        private const val DISPLAY_OUTCOME = "displayOutcome"
        private const val FAILURE_AT = "failureAt"
        private const val FAILURE_CLASS = "failureClass"
    }
}
