package com.nkshub.nextcloudtalk.calls

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * A self-managed phone account is API 26, and a device below it must be left
 * with exactly the call it had before Telecom was involved. The registry side
 * is checked directly because Telecom itself does not run here: Robolectric
 * records the placed call but never binds the connection service, so the
 * connection is built the way the system would build it.
 */
@RunWith(RobolectricTestRunner::class)
class CallTelecomTest {

    private val context: Context
        get() = RuntimeEnvironment.getApplication()

    private val telecomManager
        get() = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

    @After
    fun tearDown() {
        CallTelecomRegistry.listener = null
        CallTelecomRegistry.endAll()
    }

    @Test
    @Config(sdk = [24])
    fun `an android without self-managed calls registers no phone account`() {
        val telecom = CallTelecom(context)

        assertFalse(ask(telecom, "supported") as Boolean)
        assertFalse(
            ask(
                telecom,
                "startOutgoing",
                mapOf(
                    "callId" to CALL_ID,
                    "accountId" to ACCOUNT,
                    "roomToken" to ROOM,
                ),
            ) as Boolean,
        )
        assertNull(telecomManager.getPhoneAccount(handle()))
    }

    @Test
    @Config(sdk = [26])
    fun `a supported device registers one self-managed account`() {
        val telecom = CallTelecom(context)

        assertTrue(ask(telecom, "supported") as Boolean)

        val account = telecomManager.getPhoneAccount(handle())
        assertNotNull(account)
        assertEquals(
            PhoneAccount.CAPABILITY_SELF_MANAGED,
            account!!.capabilities and PhoneAccount.CAPABILITY_SELF_MANAGED,
        )
        assertTrue(account.supportedUriSchemes.contains(PhoneAccount.SCHEME_SIP))
    }

    @Test
    @Config(sdk = [26])
    fun `the connection telecom asks for is the call dart named`() {
        val reported = mutableListOf<Pair<String, Map<String, Any?>>>()
        CallTelecomRegistry.listener = { method, arguments ->
            reported.add(method to arguments)
        }
        CallTelecomRegistry.expect(
            CallTelecomRegistry.Pending(CALL_ID, ACCOUNT, ROOM, incoming = false),
        )

        val connection = CallTelecomRegistry.create(request()) as? CallTelecomConnection
        assertNotNull(connection)
        assertEquals(Connection.STATE_ACTIVE, connection!!.state)
        assertEquals(
            Connection.PROPERTY_SELF_MANAGED,
            connection.connectionProperties and Connection.PROPERTY_SELF_MANAGED,
        )
        assertEquals(
            Connection.CAPABILITY_HOLD,
            connection.connectionCapabilities and Connection.CAPABILITY_HOLD,
        )

        // Hold is accepted rather than refused: a connection that cannot hold
        // gets disconnected when a cellular call arrives, which would end a
        // Talk call that survives today.
        connection.onHold()
        assertEquals(Connection.STATE_HOLDING, connection.state)
        connection.onUnhold()
        assertEquals(Connection.STATE_ACTIVE, connection.state)
        assertTrue(reported.isEmpty())

        // The system hung the call up; Dart hears it once and by room.
        connection.onDisconnect()
        assertEquals(1, reported.size)
        assertEquals("telecomEnded", reported.single().first)
        assertEquals(
            mapOf("callId" to CALL_ID, "accountId" to ACCOUNT, "roomToken" to ROOM),
            reported.single().second,
        )

        // The same call cannot be built twice, and nothing is left to end.
        assertNull(CallTelecomRegistry.create(request()))
    }

    @Test
    @Config(sdk = [26])
    fun `an incoming call rings and reports the answer`() {
        val reported = mutableListOf<String>()
        CallTelecomRegistry.listener = { method, _ -> reported.add(method) }
        CallTelecomRegistry.expect(
            CallTelecomRegistry.Pending(CALL_ID, ACCOUNT, ROOM, incoming = true),
        )

        val connection = CallTelecomRegistry.create(request()) as CallTelecomConnection
        assertEquals(Connection.STATE_RINGING, connection.state)

        connection.onAnswer()
        assertEquals(Connection.STATE_ACTIVE, connection.state)
        assertEquals(listOf("telecomAnswered"), reported)
    }

    @Test
    @Config(sdk = [26])
    fun `a call ended before its connection arrives never becomes one`() {
        CallTelecomRegistry.expect(
            CallTelecomRegistry.Pending(CALL_ID, ACCOUNT, ROOM, incoming = false),
        )
        CallTelecomRegistry.end(CALL_ID)

        assertNull(CallTelecomRegistry.create(request()))
    }

    @Test
    @Config(sdk = [26])
    fun `ending the call from dart tells dart nothing back`() {
        val reported = mutableListOf<String>()
        CallTelecomRegistry.listener = { method, _ -> reported.add(method) }
        CallTelecomRegistry.expect(
            CallTelecomRegistry.Pending(CALL_ID, ACCOUNT, ROOM, incoming = false),
        )
        val connection = CallTelecomRegistry.create(request()) as CallTelecomConnection

        CallTelecomRegistry.end(CALL_ID)

        assertEquals(Connection.STATE_DISCONNECTED, connection.state)
        // Dart asked for this one, so reporting it back would be an echo that
        // could only tear the call down a second time.
        assertTrue(reported.isEmpty())
    }

    private fun ask(
        telecom: CallTelecom,
        method: String,
        arguments: Map<String, Any?>? = null,
    ): Any? {
        var answer: Any? = null
        telecom.onMethodCall(
            MethodCall(method, arguments),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    answer = result
                }

                override fun error(code: String, message: String?, details: Any?) =
                    throw AssertionError("$method failed with $code")

                override fun notImplemented() =
                    throw AssertionError("$method is not implemented")
            },
        )
        return answer
    }

    private fun handle() =
        PhoneAccountHandle(
            ComponentName(context, CallTelecomConnectionService::class.java),
            "nks-talk-calls",
        )

    private fun request() =
        ConnectionRequest(
            handle(),
            Uri.fromParts(PhoneAccount.SCHEME_SIP, ROOM, null),
            Bundle().apply { putString(CallTelecom.EXTRA_CALL_ID, CALL_ID) },
        )

    private companion object {
        const val CALL_ID = "11111111-1111-1111-1111-111111111111"
        const val ACCOUNT = "account-a"
        const val ROOM = "rooma123"
    }
}
