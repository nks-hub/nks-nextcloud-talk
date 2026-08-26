package com.nkshub.nextcloudtalk.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

class AndroidWebPushDeduplicationTest {
    @Test
    fun exactAuthenticatedContentUsesOnlyAnOpaqueDigest() {
        val token = "9f9bcfc4-93db-4f23-a8f4-5f2403f722cc"
        val content = """{"activationToken":"$token"}"""
            .toByteArray(StandardCharsets.UTF_8)
        val fingerprint = PushDeliveryFingerprint.from(
            content,
            AndroidWebPushPayload.Activation(token),
        )

        assertNotNull(fingerprint)
        assertTrue(PushDeliveryFingerprint.isValid(fingerprint!!.value))
        assertFalse(fingerprint.value.contains(token))
        assertFalse(fingerprint.value.contains("activationToken"))
        assertEquals(
            fingerprint,
            PushDeliveryFingerprint.from(content, AndroidWebPushPayload.Activation(token)),
        )
        assertNotEquals(
            fingerprint,
            PushDeliveryFingerprint.from(
                """{"activationToken":"00000000-0000-4000-8000-000000000001"}"""
                    .toByteArray(StandardCharsets.UTF_8),
                AndroidWebPushPayload.Activation("00000000-0000-4000-8000-000000000001"),
            ),
        )
        assertNull(PushDeliveryFingerprint.from(content, AndroidWebPushPayload.Invalid))
    }

    @Test
    fun weakIdentityPayloadsUseTheShortRetentionWindow() {
        val content = """{"delete-all":true}""".toByteArray(StandardCharsets.UTF_8)
        val deleteAll = PushDeliveryFingerprint.from(content, AndroidWebPushPayload.DeleteAll)
        val noId = PushDeliveryFingerprint.from(
            """{"subject":"wake"}""".toByteArray(StandardCharsets.UTF_8),
            AndroidWebPushPayload.Message(null, null, "wake", null, null),
        )

        assertEquals(PushDeliveryFingerprint.WEAK_RETENTION_MILLIS, deleteAll?.retentionMillis)
        assertEquals(PushDeliveryFingerprint.WEAK_RETENTION_MILLIS, noId?.retentionMillis)
    }

    @Test
    fun stateMachineDeduplicatesPerAccountWithoutMergingDifferentContent() {
        val state = AndroidWebPushState()
        val machine = AndroidWebPushStateMachine { "event" }
        machine.beginRegistration(state, "account-a", 1, "instance-a", 1)
        machine.beginRegistration(state, "account-b", 1, "instance-b", 1)
        val first = fingerprint(1)
        val second = fingerprint(2)

        assertNotNull(
            machine.appendMessage(state, "instance-a", mapOf("content" to "first"), 2, first),
        )
        assertNull(
            machine.appendMessage(state, "instance-a", mapOf("content" to "first"), 3, first),
        )
        assertNotNull(
            machine.appendMessage(state, "instance-b", mapOf("content" to "first"), 4, first),
        )
        assertNotNull(
            machine.appendMessage(state, "instance-a", mapOf("content" to "second"), 5, second),
        )

        assertEquals(3, state.events.size)
        assertEquals(3, state.deliveryFingerprints.size)
    }

    @Test
    fun missingFingerprintNeverSuppressesAStoredEvent() {
        val state = AndroidWebPushState()
        val machine = AndroidWebPushStateMachine { "event-${state.events.size}" }
        machine.beginRegistration(state, "account", 1, "instance", 1)

        assertNotNull(machine.appendMessage(state, "instance", emptyMap(), 2, null))
        assertNotNull(machine.appendMessage(state, "instance", emptyMap(), 3, null))
        assertEquals(2, state.events.size)
        assertTrue(state.deliveryFingerprints.isEmpty())
    }

    @Test
    fun expiryKeepsTheBoundaryThenAllowsTheSameDeliveryAgain() {
        val state = AndroidWebPushState()
        val fingerprint = fingerprint(1, retentionMillis = 100)
        AndroidWebPushDeliveryLedger.record(state, "account", fingerprint, 1_000)

        assertTrue(
            AndroidWebPushDeliveryLedger.isDuplicate(state, "account", fingerprint, 1_100),
        )
        assertFalse(
            AndroidWebPushDeliveryLedger.isDuplicate(state, "account", fingerprint, 1_101),
        )
        assertTrue(state.deliveryFingerprints.isEmpty())
    }

    @Test
    fun ledgerIsBoundedPerAccountAndGlobally() {
        val perAccount = AndroidWebPushState()
        repeat(AndroidWebPushDeliveryLedger.MAX_PER_ACCOUNT + 1) { index ->
            AndroidWebPushDeliveryLedger.record(
                perAccount,
                "account",
                fingerprint(index),
                index.toLong(),
            )
        }
        assertEquals(
            AndroidWebPushDeliveryLedger.MAX_PER_ACCOUNT,
            perAccount.deliveryFingerprints.size,
        )
        assertFalse(perAccount.deliveryFingerprints.any { it.value == fingerprint(0).value })

        val global = AndroidWebPushState()
        repeat(AndroidWebPushDeliveryLedger.MAX_TOTAL + 1) { index ->
            AndroidWebPushDeliveryLedger.record(
                global,
                "account-${index % 5}",
                fingerprint(index),
                index.toLong(),
            )
        }
        assertEquals(AndroidWebPushDeliveryLedger.MAX_TOTAL, global.deliveryFingerprints.size)
        assertFalse(global.deliveryFingerprints.any { it.value == fingerprint(0).value })
    }

    private fun fingerprint(
        value: Int,
        retentionMillis: Long = PushDeliveryFingerprint.STRONG_RETENTION_MILLIS,
    ): PushDeliveryFingerprint {
        return PushDeliveryFingerprint(value.toString(16).padStart(64, '0'), retentionMillis)
    }
}
