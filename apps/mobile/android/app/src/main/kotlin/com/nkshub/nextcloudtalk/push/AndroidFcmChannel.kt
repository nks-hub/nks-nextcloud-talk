package com.nkshub.nextcloudtalk.push

import android.content.Context
import android.util.Base64
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Hands the FCM registration token to Dart and remembers which accounts are
 * signed in.
 *
 * The token is never stored here. [FirebaseMessaging.getToken] always returns
 * the current one, so a rotation that happened while the app was dead is
 * picked up at startup; [NksFirebaseMessagingService] covers one that happens
 * while it is alive.
 *
 * Nothing about the token reaches a log, not even truncated: it is the value
 * the proxy uses to address this device.
 */
internal class AndroidFcmChannel(private val context: Context) :
    MethodChannel.MethodCallHandler {
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
            "setAccounts" -> {
                val accounts = call.argument<List<String>>("accountIds")
                if (accounts == null || accounts.any { !ACCOUNT_ID.matches(it) }) {
                    result.error("invalid_accounts", "Account ids are not valid.", null)
                    return
                }
                storeAccountIds(context, accounts.toSet())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    internal companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/fcm"

        private const val PREFERENCES = "android_fcm_accounts"
        private const val ACCOUNT_IDS = "accountIds"
        private val ACCOUNT_ID = Regex("^[0-9a-fA-F-]{1,64}$")
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

        /**
         * The signed-in accounts, as Dart last reported them. A delivery can
         * arrive at a dead process, so this has to survive one — and an
         * account id is a local UUID, not a secret.
         */
        fun storeAccountIds(context: Context, accountIds: Set<String>) {
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putStringSet(ACCOUNT_IDS, accountIds)
                .apply()
        }

        fun accountIds(context: Context): Set<String> =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getStringSet(ACCOUNT_IDS, emptySet())
                .orEmpty()
    }
}

/**
 * Receives the proxy's `data`-only message and puts it through the same
 * notification path Web Push uses.
 *
 * The proxy sends `{"nc-subject": "<base64 RSA ciphertext>"}` and no
 * `notification` block, precisely so Android does not render a plaintext
 * banner of its own before the app can decrypt anything. Decryption happens
 * here because the private key never leaves the Android Keystore.
 */
class NksFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        AndroidFcmChannel.tokenRefreshed(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val subject = message.data[SUBJECT_KEY] ?: return
        val ciphertext = runCatching {
            Base64.decode(subject, Base64.DEFAULT)
        }.getOrNull() ?: return
        val opened = AndroidPushDeviceKeyStore.decryptSubject(
            ciphertext,
            AndroidFcmChannel.accountIds(applicationContext),
        ) ?: return
        val (accountId, plaintext) = opened
        // Same parser and same display path as Web Push, so the `app=spreed`
        // gate, the account-scoped platform id ledger and the tap route are
        // shared rather than reimplemented.
        val payload = AndroidWebPushPayloadParser.parse(plaintext, decrypted = true)
        AndroidSystemNotifications.apply(applicationContext, accountId, payload)
    }

    private companion object {
        const val SUBJECT_KEY = "nc-subject"
    }
}
