package com.nkshub.nextcloudtalk.calls

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Puts a Talk call into the system's own call lifecycle.
 *
 * Android's supported way for an application that draws its own call screen is
 * a SELF-MANAGED `ConnectionService`: the app keeps its user interface and its
 * media, and Telecom gains a record of a call in progress. That record is what
 * makes the rest of the system behave — the phone knows a call is up, a
 * headset's hang-up button reaches this app, another calling application is
 * told there is already a call, and an incoming cellular call is arbitrated
 * instead of simply landing on top. A foreground service with an ongoing
 * notification keeps the process alive and says nothing to any of that.
 *
 * WHAT THIS DELIBERATELY DOES NOT DO IS TOUCH THE AUDIO. Telecom does not
 * manage audio for self-managed connections — that is the app's own job and
 * the WebRTC engine already does it. So [CallTelecomConnection] never calls
 * `setAudioModeIsVoip`, never requests audio focus and never sets an audio
 * mode. This matters more than it looks: audio focus cannot be shared inside
 * one process (measured 5 September 2026, see [CallAudioFocus]), and the
 * global audio MODE is the very signal [CallAudioModeWatcher] reads to close
 * the microphone during a telephone call. A second writer of either would
 * break a working, measured mechanism.
 *
 * SELF-MANAGED IS API 26. Below that, and on a device or ROM that refuses the
 * phone account at all, [supported] answers false and every other method is a
 * no-op that answers false — a call then runs exactly as it did before this
 * class existed. Nothing here may fail a call: Telecom is an addition to a
 * working call, never a precondition for one.
 *
 * The `MANAGE_OWN_CALLS` permission this needs is a normal permission granted
 * at install time; there is no runtime prompt to handle.
 *
 * `CAPABILITY_SELF_MANAGED` is marked deprecated by the newest platform SDK in
 * favour of `TelecomManager.addCall` with `CallAttributes`, which is API 34 and
 * up, or the `androidx.core:core-telecom` backport. It is deprecated, not gone,
 * and it is the only route that reaches API 26; taking the new one would raise
 * the floor by eight releases or add a dependency for the same behaviour.
 */
class CallTelecom(context: Context) : MethodChannel.MethodCallHandler {

    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val telecomManager =
        context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager

    private var channel: MethodChannel? = null

    /** Null until the phone account has been offered to Telecom once. */
    private var registered: Boolean? = null

    fun attach(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler(this)
        CallTelecomRegistry.listener = { method, arguments ->
            handler.post { this.channel?.invokeMethod(method, arguments) }
        }
    }

    /**
     * Drops the bridge to Dart and takes down whatever the system still
     * believes is a call. The activity calls this when its engine goes away,
     * so a system call record cannot outlive the app that owns it.
     */
    fun detach() {
        CallTelecomRegistry.listener = null
        CallTelecomRegistry.endAll()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supported" -> result.success(supported())
            "startOutgoing" -> result.success(place(call, incoming = false))
            "reportIncoming" -> result.success(place(call, incoming = true))
            "endCall" -> {
                CallTelecomRegistry.end(call.argument<String>("callId"))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Whether this device will take a self-managed call at all. Registering
     * the phone account is part of the answer, because a ROM that refuses the
     * registration cannot be told about calls either.
     */
    private fun supported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        val manager = telecomManager ?: return false
        registered?.let { return it }
        val account =
            PhoneAccount.builder(accountHandle(), label())
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .setSupportedUriSchemes(listOf(PhoneAccount.SCHEME_SIP))
                .build()
        val outcome =
            try {
                manager.registerPhoneAccount(account)
                true
            } catch (error: RuntimeException) {
                // A ROM without Telecom, or one that refuses a self-managed
                // account, throws here. The call still runs without it.
                false
            }
        registered = outcome
        return outcome
    }

    /**
     * Hands one call to Telecom. Returns false whenever the system would not
     * take it, which is never a reason to stop joining.
     */
    private fun place(call: MethodCall, incoming: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        val callId = call.argument<String>("callId") ?: return false
        val accountId = call.argument<String>("accountId") ?: return false
        val roomToken = call.argument<String>("roomToken") ?: return false
        if (!supported()) {
            return false
        }
        val manager = telecomManager ?: return false
        val handle = accountHandle()
        val permitted =
            try {
                if (incoming) {
                    manager.isIncomingCallPermitted(handle)
                } else {
                    manager.isOutgoingCallPermitted(handle)
                }
            } catch (error: RuntimeException) {
                false
            }
        if (!permitted) {
            return false
        }
        CallTelecomRegistry.expect(
            CallTelecomRegistry.Pending(callId, accountId, roomToken, incoming),
        )
        val inner = Bundle().apply { putString(EXTRA_CALL_ID, callId) }
        val extras =
            Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                if (incoming) {
                    putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, inner)
                } else {
                    putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, inner)
                }
            }
        return try {
            if (incoming) {
                manager.addNewIncomingCall(handle, extras)
            } else {
                manager.placeCall(Uri.fromParts(PhoneAccount.SCHEME_SIP, roomToken, null), extras)
            }
            true
        } catch (error: RuntimeException) {
            // A missing MANAGE_OWN_CALLS, an emergency call in progress, a
            // manufacturer's own restriction: the call carries on regardless.
            CallTelecomRegistry.forget(callId)
            false
        }
    }

    private fun accountHandle() =
        PhoneAccountHandle(
            ComponentName(context, CallTelecomConnectionService::class.java),
            ACCOUNT_ID,
        )

    /** Shown wherever the system names the calling account. */
    private fun label(): CharSequence =
        context.applicationInfo.loadLabel(context.packageManager)

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/call_telecom"

        /** One account for the whole app; a Talk account is not a SIM. */
        private const val ACCOUNT_ID = "nks-talk-calls"

        internal const val EXTRA_CALL_ID = "com.nkshub.nextcloudtalk.CALL_ID"
    }
}

/**
 * Connects the calls Dart asked for to the connections Telecom creates.
 *
 * The two halves cannot reach each other directly: [CallTelecomConnectionService]
 * is instantiated by the system, while [CallTelecom] belongs to the activity's
 * Flutter engine. Process-wide state is what the platform leaves as the option,
 * the same as [CallForegroundService]'s owner set.
 *
 * Everything here runs on the main thread — Telecom binds its service there
 * and Dart's channel calls arrive there — so the maps need no locking.
 */
internal object CallTelecomRegistry {

    internal class Pending(
        val callId: String,
        val accountId: String,
        val roomToken: String,
        val incoming: Boolean,
    )

    /** Set while a Flutter engine is attached; every report goes through it. */
    var listener: ((String, Map<String, Any?>) -> Unit)? = null

    private val pending = mutableMapOf<String, Pending>()
    private val connections = mutableMapOf<String, CallTelecomConnection>()

    fun expect(call: Pending) {
        pending[call.callId] = call
    }

    fun forget(callId: String) {
        pending.remove(callId)
    }

    /**
     * Builds the connection Telecom asked for, or null when nothing is waiting
     * for it. Null fails that one call in Telecom and leaves the Talk call
     * alone, which is also what a call ended before its connection arrived
     * needs: [end] has already removed the pending entry by then.
     */
    fun create(request: ConnectionRequest?): Connection? {
        val callId = request?.extras?.getString(CallTelecom.EXTRA_CALL_ID)
        val call = pending.remove(callId) ?: return null
        val connection = CallTelecomConnection(call)
        connections[call.callId] = connection
        // After this method returns, never inside it. Telecom only learns of
        // the connection when it is handed back, and a state set before that
        // is replaced by DIALING when the system registers it — measured on
        // API 29, where an outgoing call sat in DIALING for its whole life.
        Handler(Looper.getMainLooper()).post {
            if (connections[call.callId] === connection) {
                connection.begin()
            }
        }
        return connection
    }

    /** The system took the call down; Dart has to hear it exactly once. */
    fun report(method: String, call: Pending) {
        connections.remove(call.callId)
        listener?.invoke(
            method,
            mapOf(
                "callId" to call.callId,
                "accountId" to call.accountId,
                "roomToken" to call.roomToken,
            ),
        )
    }

    /** This side is done with the call: the system record goes away silently. */
    fun end(callId: String?) {
        val id = callId ?: return
        pending.remove(id)
        connections.remove(id)?.endLocally()
    }

    fun endAll() {
        pending.clear()
        val open = connections.values.toList()
        connections.clear()
        open.forEach { it.endLocally() }
    }
}

/**
 * One Talk call as Telecom sees it.
 *
 * An outgoing call goes straight to active. Talk has no dialing state to
 * mirror — by the time this exists the call's REST seat is confirmed and the
 * media session is running, so a connection left dialing would only be a lie
 * that Telecom eventually times out.
 *
 * HOLD IS ACCEPTED AND REPORTED, AND THAT IS ALL IT DOES. Telecom asks a
 * self-managed call to hold when the user answers a cellular call, and a
 * connection that declares no hold support gets disconnected instead — which
 * would end a Talk call that survives today. So hold is declared, answered
 * with [setOnHold] so Telecom sees compliance, and the microphone is left to
 * [CallAudioModeWatcher], which already closes it for the very same event and
 * has been measured doing so on API 31 and below. Two mechanisms muting one
 * microphone would only be able to disagree.
 */
internal class CallTelecomConnection(private val call: CallTelecomRegistry.Pending) :
    Connection() {

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
        }
        connectionCapabilities =
            Connection.CAPABILITY_HOLD or Connection.CAPABILITY_SUPPORT_HOLD
        setAddress(
            Uri.fromParts(PhoneAccount.SCHEME_SIP, call.roomToken, null),
            TelecomManager.PRESENTATION_ALLOWED,
        )
    }

    fun begin() {
        if (call.incoming) {
            setRinging()
        } else {
            setActive()
        }
    }

    /** Ends the system's record without telling Dart to leave the call. */
    fun endLocally() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
    }

    override fun onAnswer() {
        setActive()
        CallTelecomRegistry.report(ANSWERED, call)
    }

    override fun onReject() {
        finish(DisconnectCause.REJECTED)
    }

    override fun onDisconnect() {
        finish(DisconnectCause.LOCAL)
    }

    override fun onAbort() {
        finish(DisconnectCause.UNKNOWN)
    }

    override fun onHold() {
        setOnHold()
    }

    override fun onUnhold() {
        setActive()
    }

    /**
     * A self-managed application is required to show its own incoming-call
     * user interface here. This app has none yet — no Talk push on Android is
     * classified as a call, so nothing reports an incoming call in the first
     * place — and the report tells Dart what the system asked for rather than
     * pretending a screen appeared.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    override fun onShowIncomingCallUi() {
        CallTelecomRegistry.report(SHOW_INCOMING, call)
    }

    private fun finish(cause: Int) {
        setDisconnected(DisconnectCause(cause))
        destroy()
        CallTelecomRegistry.report(ENDED, call)
    }

    private companion object {
        const val ANSWERED = "telecomAnswered"
        const val ENDED = "telecomEnded"
        const val SHOW_INCOMING = "telecomShowIncomingUi"
    }
}

/**
 * The service Telecom binds to build the connections for this app's calls.
 *
 * Declared in the manifest with `BIND_TELECOM_CONNECTION_SERVICE` so only the
 * system can bind it. It is bound only after a self-managed phone account has
 * been registered, which never happens below API 26, so the declaration is
 * inert on older devices rather than conditional.
 */
class CallTelecomConnectionService : ConnectionService() {

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection? = CallTelecomRegistry.create(request)

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection? = CallTelecomRegistry.create(request)

    /**
     * Telecom refused the call. The pending entry goes, and Dart is told
     * nothing: a call the system would not take must keep running as if
     * Telecom were not there.
     */
    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        CallTelecomRegistry.forget(
            request?.extras?.getString(CallTelecom.EXTRA_CALL_ID) ?: return,
        )
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        CallTelecomRegistry.forget(
            request?.extras?.getString(CallTelecom.EXTRA_CALL_ID) ?: return,
        )
    }
}
