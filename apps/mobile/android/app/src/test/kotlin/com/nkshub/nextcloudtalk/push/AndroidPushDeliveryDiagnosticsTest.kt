package com.nkshub.nextcloudtalk.push

import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class AndroidPushDeliveryDiagnosticsTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val store = AndroidPushDeliveryDiagnosticsStore(context)

    @After
    fun clear() {
        store.clearForTests()
    }

    @Test
    fun transportReceptionAndAccountStagesStaySeparate() {
        store.recordReceived(PushDeliveryTransport.PROXY, 100)
        store.recordDecrypted(PushDeliveryTransport.PROXY, "account-a", 110)
        store.recordDisplay(
            PushDeliveryTransport.PROXY,
            "account-a",
            PushDisplayOutcome.POSTED,
            120,
        )
        store.recordFailure(
            PushDeliveryTransport.PROXY,
            "invalid-payload",
            125,
            accountId = "account-a",
        )
        store.recordFailure(PushDeliveryTransport.PROXY, "decryption-failed", 130)
        store.recordReceived(PushDeliveryTransport.WEB_PUSH, 200)

        assertEquals(
            PushDeliveryDiagnostics(
                lastTransportReceivedAtMillis = 100,
                lastDecryptedAtMillis = 110,
                lastDisplayAtMillis = 120,
                displayOutcome = PushDisplayOutcome.POSTED,
                lastTransportFailureAtMillis = 130,
                transportFailureClass = "decryption-failed",
                lastAccountFailureAtMillis = 125,
                accountFailureClass = "invalid-payload",
            ),
            store.read(PushDeliveryTransport.PROXY, "account-a"),
        )
        val otherAccount = store.read(PushDeliveryTransport.PROXY, "account-b")
        assertEquals(100L, otherAccount.lastTransportReceivedAtMillis)
        assertNull(otherAccount.lastDecryptedAtMillis)
        assertNull(otherAccount.displayOutcome)
        assertEquals("decryption-failed", otherAccount.transportFailureClass)
        assertNull(otherAccount.accountFailureClass)
        assertEquals(
            200L,
            store.read(PushDeliveryTransport.WEB_PUSH, "account-a").lastTransportReceivedAtMillis,
        )
    }

    @Test
    fun preferencesDoNotContainTheAccountIdentifier() {
        store.recordDecrypted(PushDeliveryTransport.PROXY, "private-account-id", 110)

        val values = context
            .getSharedPreferences(
                AndroidPushDeliveryDiagnosticsStore.PREFERENCES,
                Context.MODE_PRIVATE,
            )
            .all
        assertFalse(values.keys.any { it.contains("private-account-id") })
        assertFalse(values.values.any { it.toString().contains("private-account-id") })
    }

    @Test
    fun wronglyTypedTimestampsAreRepairedWithoutBlockingWrites() {
        val preferences = context.getSharedPreferences(
            AndroidPushDeliveryDiagnosticsStore.PREFERENCES,
            Context.MODE_PRIVATE,
        )
        preferences.edit().putString("proxy.receivedAt", "bad").commit()

        store.recordReceived(PushDeliveryTransport.PROXY, 100)
        assertEquals(100L, preferences.getLong("proxy.receivedAt", -1))

        store.recordDisplay(
            PushDeliveryTransport.PROXY,
            "account-a",
            PushDisplayOutcome.POSTED,
            110,
        )
        val displayAt = preferences.all.keys.single { it.endsWith(".displayAt") }
        preferences.edit().putString(displayAt, "bad").commit()
        store.recordDisplay(
            PushDeliveryTransport.PROXY,
            "account-a",
            PushDisplayOutcome.SUPPRESSED_OPEN_ROOM,
            120,
        )
        assertEquals(120L, preferences.getLong(displayAt, -1))

        store.recordFailure(PushDeliveryTransport.PROXY, "first", 125)
        preferences.edit().putString("proxy.failureAt", "bad").commit()
        store.recordFailure(PushDeliveryTransport.PROXY, "second", 130)
        assertEquals(130L, preferences.getLong("proxy.failureAt", -1))
    }

    @Test
    fun wronglyTypedStringsDoNotBreakReadingAndAreRepairedByTheNextWrite() {
        val preferences = context.getSharedPreferences(
            AndroidPushDeliveryDiagnosticsStore.PREFERENCES,
            Context.MODE_PRIVATE,
        )
        store.recordDisplay(
            PushDeliveryTransport.PROXY,
            "account-a",
            PushDisplayOutcome.POSTED,
            100,
        )
        store.recordFailure(PushDeliveryTransport.PROXY, "first", 110)
        val outcome = preferences.all.keys.single { it.endsWith(".displayOutcome") }
        preferences.edit()
            .putLong(outcome, 1)
            .putLong("proxy.failureClass", 2)
            .commit()

        val damaged = store.read(PushDeliveryTransport.PROXY, "account-a")
        assertNull(damaged.displayOutcome)
        assertNull(damaged.transportFailureClass)

        store.recordDisplay(
            PushDeliveryTransport.PROXY,
            "account-a",
            PushDisplayOutcome.SUPPRESSED_OPEN_ROOM,
            120,
        )
        store.recordFailure(PushDeliveryTransport.PROXY, "second", 130)
        val repaired = store.read(PushDeliveryTransport.PROXY, "account-a")
        assertEquals(PushDisplayOutcome.SUPPRESSED_OPEN_ROOM, repaired.displayOutcome)
        assertEquals("second", repaired.transportFailureClass)
    }
}
