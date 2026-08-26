package com.nkshub.nextcloudtalk.push

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

internal data class StoredPlatformNotificationId(
    val accountId: String,
    val notificationId: Long,
    val platformNotificationId: Int,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
) {
    val route: Pair<String, Long>
        get() = accountId to notificationId

    override fun toString(): String {
        return "StoredPlatformNotificationId(accountId=<redacted>, " +
            "notificationId=$notificationId, platformNotificationId=$platformNotificationId)"
    }
}

internal data class PlatformNotificationIdAllocation(
    val stored: StoredPlatformNotificationId,
    val evicted: List<StoredPlatformNotificationId>,
) {
    val route: Pair<String, Long>
        get() = stored.route

    val platformNotificationId: Int
        get() = stored.platformNotificationId

    val updatedAtMillis: Long
        get() = stored.updatedAtMillis
}

internal data class PreparedAndroidSystemNotification(
    val openToken: String,
    val platformNotificationId: Int,
    val evicted: List<StoredPlatformNotificationId>,
)

internal class AndroidPlatformNotificationIdLedger(
    private val candidateId: (String, Long) -> Int = ::hashedCandidate,
    private val maxTotal: Int = MAX_TOTAL_ROUTES,
    private val maxPerAccount: Int = MAX_ROUTES_PER_ACCOUNT,
) {
    init {
        require(maxPerAccount > 0 && maxTotal >= maxPerAccount)
    }

    fun allocate(
        state: AndroidNotificationOpenState,
        accountId: String,
        notificationId: Long,
        nowMillis: Long,
    ): PlatformNotificationIdAllocation {
        require(accountId.isNotBlank() && notificationId > 0 && nowMillis >= 0)
        val existingIndex = state.platformNotificationIds.indexOfFirst {
            it.accountId == accountId && it.notificationId == notificationId
        }
        if (existingIndex >= 0) {
            val updated = state.platformNotificationIds[existingIndex].copy(
                updatedAtMillis = maxOf(
                    state.platformNotificationIds[existingIndex].updatedAtMillis,
                    nowMillis,
                ),
            )
            state.platformNotificationIds[existingIndex] = updated
            return PlatformNotificationIdAllocation(updated, emptyList())
        }

        val evicted = mutableListOf<StoredPlatformNotificationId>()
        while (state.platformNotificationIds.count { it.accountId == accountId } >= maxPerAccount) {
            evicted.add(removeOldest(state) { it.accountId == accountId })
        }
        while (state.platformNotificationIds.size >= maxTotal) {
            evicted.add(removeOldest(state) { true })
        }

        val used = state.platformNotificationIds.mapTo(mutableSetOf()) {
            it.platformNotificationId
        }
        var platformId = normalize(candidateId(accountId, notificationId))
        while (platformId in used) {
            platformId = if (platformId == Int.MAX_VALUE) MIN_PLATFORM_ID else platformId + 1
        }
        val stored = StoredPlatformNotificationId(
            accountId = accountId,
            notificationId = notificationId,
            platformNotificationId = platformId,
            createdAtMillis = nowMillis,
            updatedAtMillis = nowMillis,
        )
        state.platformNotificationIds.add(stored)
        return PlatformNotificationIdAllocation(stored, evicted)
    }

    fun resolve(
        state: AndroidNotificationOpenState,
        accountId: String,
        notificationId: Long,
    ): Int? = state.platformNotificationIds.firstOrNull {
        it.accountId == accountId && it.notificationId == notificationId
    }?.platformNotificationId

    fun release(
        state: AndroidNotificationOpenState,
        accountId: String,
        notificationIds: Set<Long>,
    ): List<StoredPlatformNotificationId> {
        val released = state.platformNotificationIds.filter {
            it.accountId == accountId && it.notificationId in notificationIds
        }
        state.platformNotificationIds.removeAll(released.toSet())
        return released
    }

    fun releaseAll(
        state: AndroidNotificationOpenState,
        accountId: String,
    ): List<StoredPlatformNotificationId> {
        val released = state.platformNotificationIds.filter { it.accountId == accountId }
        state.platformNotificationIds.removeAll(released.toSet())
        return released
    }

    private fun removeOldest(
        state: AndroidNotificationOpenState,
        predicate: (StoredPlatformNotificationId) -> Boolean,
    ): StoredPlatformNotificationId {
        val oldest = state.platformNotificationIds
            .asSequence()
            .filter(predicate)
            .minWith(
                compareBy<StoredPlatformNotificationId> { it.updatedAtMillis }
                    .thenBy { it.createdAtMillis }
                    .thenBy { it.platformNotificationId },
            )
        state.platformNotificationIds.remove(oldest)
        return oldest
    }

    private fun normalize(value: Int): Int {
        return if (value < MIN_PLATFORM_ID) MIN_PLATFORM_ID else value
    }

    companion object {
        internal const val MAX_TOTAL_ROUTES = 512
        internal const val MAX_ROUTES_PER_ACCOUNT = 128
        internal const val MIN_PLATFORM_ID = 2

        private fun hashedCandidate(accountId: String, notificationId: Long): Int {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(accountId.toByteArray(StandardCharsets.UTF_8))
            digest.update(0)
            digest.update(notificationId.toString().toByteArray(StandardCharsets.US_ASCII))
            return ByteBuffer.wrap(digest.digest()).int and Int.MAX_VALUE
        }
    }
}
