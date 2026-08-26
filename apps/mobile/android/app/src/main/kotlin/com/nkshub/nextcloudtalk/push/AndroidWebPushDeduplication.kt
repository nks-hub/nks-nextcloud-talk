package com.nkshub.nextcloudtalk.push

import java.security.MessageDigest

internal data class PushDeliveryFingerprint(
    val value: String,
    val retentionMillis: Long,
) {
    companion object {
        fun from(
            content: ByteArray,
            payload: AndroidWebPushPayload,
        ): PushDeliveryFingerprint? {
            val retention = when (payload) {
                AndroidWebPushPayload.Invalid -> return null
                AndroidWebPushPayload.DeleteAll -> WEAK_RETENTION_MILLIS
                is AndroidWebPushPayload.Message -> if (payload.notificationId == null) {
                    WEAK_RETENTION_MILLIS
                } else {
                    STRONG_RETENTION_MILLIS
                }
                else -> STRONG_RETENTION_MILLIS
            }
            val digest = MessageDigest.getInstance("SHA-256").digest(content)
            return PushDeliveryFingerprint(digest.toLowerHex(), retention)
        }

        fun isValid(value: String): Boolean = FINGERPRINT_PATTERN.matches(value)

        internal const val STRONG_RETENTION_MILLIS = 7L * 24L * 60L * 60L * 1000L
        internal const val WEAK_RETENTION_MILLIS = 60L * 1000L
        private val FINGERPRINT_PATTERN = Regex("^[0-9a-f]{64}$")
    }
}

internal data class StoredPushDeliveryFingerprint(
    val accountId: String,
    val value: String,
    val expiresAtMillis: Long,
)

internal fun AndroidWebPushStateMachine.appendActivation(
    state: AndroidWebPushState,
    instance: String,
    payload: Map<String, Any?>,
    nowMillis: Long,
    deliveryFingerprint: PushDeliveryFingerprint?,
): StoredPushEvent? {
    return AndroidWebPushDeliveryLedger.appendIfNew(
        state,
        instance,
        deliveryFingerprint,
        nowMillis,
    ) {
        appendActivation(state, instance, payload, nowMillis)
    }
}

internal fun AndroidWebPushStateMachine.appendMessage(
    state: AndroidWebPushState,
    instance: String,
    payload: Map<String, Any?>,
    nowMillis: Long,
    deliveryFingerprint: PushDeliveryFingerprint?,
): StoredPushEvent? {
    return AndroidWebPushDeliveryLedger.appendIfNew(
        state,
        instance,
        deliveryFingerprint,
        nowMillis,
    ) {
        appendMessage(state, instance, payload, nowMillis)
    }
}

internal object AndroidWebPushDeliveryLedger {
    fun <T> appendIfNew(
        state: AndroidWebPushState,
        instance: String,
        fingerprint: PushDeliveryFingerprint?,
        nowMillis: Long,
        append: () -> T?,
    ): T? {
        val accountId = state.registrations
            .firstOrNull { it.instance == instance && it.phase != PushRegistrationPhase.RETIRED }
            ?.accountId
            ?: return append()
        if (fingerprint == null || !isDuplicate(state, accountId, fingerprint, nowMillis)) {
            return append()?.also {
                fingerprint?.let { record(state, accountId, it, nowMillis) }
            }
        }
        return null
    }

    fun isDuplicate(
        state: AndroidWebPushState,
        accountId: String,
        fingerprint: PushDeliveryFingerprint,
        nowMillis: Long,
    ): Boolean {
        prune(state, nowMillis)
        return state.deliveryFingerprints.any {
            it.accountId == accountId && it.value == fingerprint.value
        }
    }

    fun record(
        state: AndroidWebPushState,
        accountId: String,
        fingerprint: PushDeliveryFingerprint,
        nowMillis: Long,
    ) {
        while (state.deliveryFingerprints.count { it.accountId == accountId } >= MAX_PER_ACCOUNT) {
            removeOldest(state) { it.accountId == accountId }
        }
        while (state.deliveryFingerprints.size >= MAX_TOTAL) {
            removeOldest(state) { true }
        }
        state.deliveryFingerprints.add(
            StoredPushDeliveryFingerprint(
                accountId = accountId,
                value = fingerprint.value,
                expiresAtMillis = saturatingAdd(nowMillis, fingerprint.retentionMillis),
            ),
        )
    }

    fun prune(state: AndroidWebPushState, nowMillis: Long) {
        state.deliveryFingerprints.removeAll { it.expiresAtMillis < nowMillis }
    }

    private fun removeOldest(
        state: AndroidWebPushState,
        predicate: (StoredPushDeliveryFingerprint) -> Boolean,
    ) {
        val oldest = state.deliveryFingerprints
            .filter(predicate)
            .minWithOrNull(compareBy<StoredPushDeliveryFingerprint> { it.expiresAtMillis }.thenBy { it.value })
            ?: return
        state.deliveryFingerprints.remove(oldest)
    }

    private fun saturatingAdd(left: Long, right: Long): Long {
        return if (left > Long.MAX_VALUE - right) Long.MAX_VALUE else left + right
    }

    internal const val MAX_TOTAL = 512
    internal const val MAX_PER_ACCOUNT = 128
}

private fun ByteArray.toLowerHex(): String {
    val alphabet = "0123456789abcdef"
    return buildString(size * 2) {
        this@toLowerHex.forEach { byte ->
            val value = byte.toInt() and 0xff
            append(alphabet[value ushr 4])
            append(alphabet[value and 0x0f])
        }
    }
}
