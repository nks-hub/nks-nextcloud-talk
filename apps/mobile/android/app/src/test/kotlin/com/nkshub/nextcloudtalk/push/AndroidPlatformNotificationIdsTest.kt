package com.nkshub.nextcloudtalk.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidPlatformNotificationIdsTest {
    @Test
    fun sameRouteIsStableAndCollidingAccountsProbeToDifferentIds() {
        val state = AndroidNotificationOpenState()
        val ledger = AndroidPlatformNotificationIdLedger(candidateId = { _, _ -> 7 })

        val first = ledger.allocate(state, "account-a", 42, 1)
        val repeated = ledger.allocate(state, "account-a", 42, 2)
        val otherAccount = ledger.allocate(state, "account-b", 42, 3)
        val otherNotification = ledger.allocate(state, "account-a", 43, 4)

        assertEquals(7, first.platformNotificationId)
        assertEquals(first.platformNotificationId, repeated.platformNotificationId)
        assertEquals(8, otherAccount.platformNotificationId)
        assertEquals(9, otherNotification.platformNotificationId)
        assertNotEquals(first.platformNotificationId, otherAccount.platformNotificationId)
        assertEquals(3, state.platformNotificationIds.size)
        assertEquals(2, repeated.updatedAtMillis)
    }

    @Test
    fun releaseOneAndAllNeverCrossTheAccountBoundary() {
        val state = AndroidNotificationOpenState()
        val ledger = AndroidPlatformNotificationIdLedger(candidateId = { _, _ -> 20 })
        val accountAFirst = ledger.allocate(state, "account-a", 51, 1)
        val accountASecond = ledger.allocate(state, "account-a", 52, 2)
        val accountB = ledger.allocate(state, "account-b", 51, 3)

        assertEquals(
            listOf(accountAFirst.route),
            ledger.release(state, "account-a", setOf(51)).map { it.route },
        )
        assertNull(ledger.resolve(state, "account-a", 51))
        assertEquals(accountB.platformNotificationId, ledger.resolve(state, "account-b", 51))

        assertEquals(
            listOf(accountASecond.route),
            ledger.releaseAll(state, "account-a").map { it.route },
        )
        assertEquals(accountB.platformNotificationId, ledger.resolve(state, "account-b", 51))
        assertEquals(1, state.platformNotificationIds.size)
    }

    @Test
    fun perAccountAndGlobalBoundsEvictOldestRoutesDeterministically() {
        val state = AndroidNotificationOpenState()
        val ledger = AndroidPlatformNotificationIdLedger(
            candidateId = { _, _ -> 30 },
            maxTotal = 3,
            maxPerAccount = 2,
        )
        val accountAFirst = ledger.allocate(state, "account-a", 61, 1)
        val accountASecond = ledger.allocate(state, "account-a", 62, 2)
        val accountB = ledger.allocate(state, "account-b", 61, 3)

        val perAccountEviction = ledger.allocate(state, "account-a", 63, 4)
        assertEquals(listOf(accountAFirst.route), perAccountEviction.evicted.map { it.route })
        assertNull(ledger.resolve(state, "account-a", 61))
        assertEquals(accountASecond.platformNotificationId, ledger.resolve(state, "account-a", 62))
        assertEquals(accountB.platformNotificationId, ledger.resolve(state, "account-b", 61))

        val globalEviction = ledger.allocate(state, "account-c", 61, 5)
        assertEquals(listOf(accountASecond.route), globalEviction.evicted.map { it.route })
        assertEquals(3, state.platformNotificationIds.size)
        assertEquals(3, state.platformNotificationIds.map { it.platformNotificationId }.toSet().size)
    }

    @Test
    fun reservedAndNegativeCandidatesNormalizeToPositiveNonLegacyIds() {
        val state = AndroidNotificationOpenState()
        val candidates = ArrayDeque(listOf(Int.MIN_VALUE, 0, 1, Int.MAX_VALUE))
        val ledger = AndroidPlatformNotificationIdLedger(candidateId = { _, _ -> candidates.removeFirst() })

        val ids = (1L..4L).map { ledger.allocate(state, "account", it, it).platformNotificationId }

        assertEquals(listOf(2, 3, 4, Int.MAX_VALUE), ids)
    }
}
