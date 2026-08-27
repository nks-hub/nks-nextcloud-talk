package com.nkshub.nextcloudtalk.push

import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Hands the FCM registration token to Dart.
 *
 * The token is never stored here. [FirebaseMessaging.getToken] always returns
 * the current one, so a rotation that happens while the app is dead is picked
 * up by the next [onMethodCall] at startup; [NksFirebaseMessagingService]
 * covers a rotation that happens while it is alive.
 *
 * Nothing about the token reaches a log, not even truncated: it is the value
 * the proxy uses to address this device.
 */
internal class AndroidFcmChannel : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getToken" -> FirebaseMessaging.getInstance().token
                .addOnSuccessListener { token -> result.success(token) }
                .addOnFailureListener {
                    result.error(
                        "fcm_token_unavailable",
                        "No FCM registration token is available.",
                        null,
                    )
                }
            else -> result.notImplemented()
        }
    }

    internal companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/fcm"

        private val listeners = CopyOnWriteArrayList<(String) -> Unit>()

        fun attach(listener: (String) -> Unit) {
            listeners.add(listener)
        }

        fun detach(listener: (String) -> Unit) {
            listeners.remove(listener)
        }

        fun tokenRefreshed(token: String) {
            for (listener in listeners) {
                listener(token)
            }
        }
    }
}

/**
 * Exists for [onNewToken]. A rotated token invalidates the registration the
 * proxy holds, so Dart has to re-register with the new one.
 *
 * `onMessageReceived` is deliberately not overridden. Delivery is a separate
 * piece of work — the payload is RSA-encrypted with this device's key and
 * nothing decrypts it yet — and the base class already ignores what it cannot
 * handle. See docs/architecture/notifications.md.
 */
class NksFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        AndroidFcmChannel.tokenRefreshed(token)
    }
}
