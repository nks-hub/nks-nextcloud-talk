package com.nkshub.nextcloudtalk.push

import android.content.Context
import android.util.Base64
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor

internal class FirstInstallFcmTokenReset(
    private val isFirstInstall: () -> Boolean,
    private val isComplete: () -> Boolean,
    private val deleteToken: () -> Task<Void>,
    private val markComplete: () -> Boolean,
    private val currentToken: () -> Task<String> = {
        Tasks.forException(IllegalStateException("FCM token provider is not configured"))
    },
) {
    private val refreshLock = Any()
    private var blockRefreshUntilFreshToken = false
    private var establishedToken: String? = null
    private var refreshGeneration = 0L
    private var latestRefresh: PendingFcmTokenRefresh? = null

    fun beforeGetToken(): Task<Void> {
        return try {
            if (!isFirstInstall() || isComplete()) {
                return Tasks.forResult<Void>(null)
            }
            synchronized(PROCESS_LOCK) {
                if (!isFirstInstall() || isComplete()) {
                    return@synchronized Tasks.forResult<Void>(null)
                }
                synchronized(refreshLock) {
                    blockRefreshUntilFreshToken = true
                }
                processInFlight?.let { return@synchronized it }
                val reset = deleteToken().continueWith<Void>(DIRECT_EXECUTOR) { task ->
                    if (!task.isSuccessful) {
                        throw task.exception
                            ?: IllegalStateException("FCM token deletion failed")
                    }
                    check(markComplete()) { "FCM reset marker could not be persisted" }
                    null
                }
                processInFlight = reset
                reset.addOnCompleteListener(DIRECT_EXECUTOR) {
                    synchronized(PROCESS_LOCK) {
                        if (processInFlight === reset) {
                            processInFlight = null
                        }
                    }
                }
                reset
            }
        } catch (failure: Exception) {
            Tasks.forException(failure)
        }
    }

    fun establishCurrentToken(): Task<String> {
        val task = try {
            currentToken()
        } catch (failure: Exception) {
            return Tasks.forException(failure)
        }
        return task.continueWith(DIRECT_EXECUTOR) { completed ->
            if (!completed.isSuccessful) {
                throw completed.exception
                    ?: IllegalStateException("FCM token lookup failed")
            }
            val token = completed.result
            val pending = synchronized(refreshLock) {
                establishedToken = token
                blockRefreshUntilFreshToken = false
                latestRefresh
            }
            pending?.let(::validateRefresh)
            token
        }
    }

    fun forwardTokenRefresh(token: String, forward: (String) -> Unit) {
        val candidate = synchronized(refreshLock) {
            PendingFcmTokenRefresh(
                generation = ++refreshGeneration,
                token = token,
                forward = forward,
            ).also { latestRefresh = it }
        }
        val ready = try {
            !isFirstInstall() || isComplete()
        } catch (_: Exception) {
            false
        }
        if (!ready || synchronized(refreshLock) { blockRefreshUntilFreshToken }) {
            return
        }
        validateRefresh(candidate)
    }

    private fun validateRefresh(candidate: PendingFcmTokenRefresh) {
        val providerTask = try {
            currentToken()
        } catch (_: Exception) {
            return
        }
        providerTask.addOnSuccessListener(DIRECT_EXECUTOR) { providerToken ->
            val stillReady = try {
                (!isFirstInstall() || isComplete()) &&
                    !synchronized(refreshLock) { blockRefreshUntilFreshToken }
            } catch (_: Exception) {
                false
            }
            if (!stillReady) {
                return@addOnSuccessListener
            }
            var forward: ((String) -> Unit)? = null
            synchronized(refreshLock) {
                if (latestRefresh?.generation != candidate.generation ||
                    blockRefreshUntilFreshToken
                ) {
                    return@synchronized
                }
                if (providerToken != candidate.token) {
                    latestRefresh = null
                    return@synchronized
                }
                latestRefresh = null
                if (establishedToken != candidate.token) {
                    establishedToken = candidate.token
                    forward = candidate.forward
                }
            }
            forward?.invoke(candidate.token)
        }
    }

    private companion object {
        val DIRECT_EXECUTOR = Executor { command -> command.run() }
        val PROCESS_LOCK = Any()
        var processInFlight: Task<Void>? = null
    }
}

private data class PendingFcmTokenRefresh(
    val generation: Long,
    val token: String,
    val forward: (String) -> Unit,
)

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
    private val firstInstallReset = firstInstallReset(context)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getToken" -> firstInstallReset.beforeGetToken()
                .addOnSuccessListener {
                    firstInstallReset.establishCurrentToken()
                        .addOnSuccessListener { token -> result.success(token) }
                        .addOnFailureListener {
                            result.error(
                                "fcm_token_unavailable",
                                "No FCM registration token is available.",
                                null,
                            )
                        }
                }
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
        internal const val FIRST_INSTALL_RESET_COMPLETE = "firstInstallResetComplete"
        private val ACCOUNT_ID = Regex("^[0-9a-fA-F-]{1,64}$")
        private val listeners = CopyOnWriteArrayList<(String) -> Unit>()
        private val resetLock = Any()
        private var sharedFirstInstallReset: FirstInstallFcmTokenReset? = null

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

        fun tokenRefreshed(context: Context, token: String) {
            firstInstallReset(context).forwardTokenRefresh(token, ::tokenRefreshed)
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

        private fun firstInstallReset(context: Context): FirstInstallFcmTokenReset {
            sharedFirstInstallReset?.let { return it }
            return synchronized(resetLock) {
                sharedFirstInstallReset ?: createFirstInstallReset(context.applicationContext)
                    .also { sharedFirstInstallReset = it }
            }
        }

        private fun createFirstInstallReset(context: Context) = FirstInstallFcmTokenReset(
            isFirstInstall = {
                context.packageManager.getPackageInfo(context.packageName, 0).run {
                    firstInstallTime == lastUpdateTime
                }
            },
            isComplete = {
                context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                    .getBoolean(FIRST_INSTALL_RESET_COMPLETE, false)
            },
            deleteToken = { FirebaseMessaging.getInstance().deleteToken() },
            markComplete = {
                context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(FIRST_INSTALL_RESET_COMPLETE, true)
                    .commit()
            },
            currentToken = { FirebaseMessaging.getInstance().token },
        )
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
        AndroidFcmChannel.tokenRefreshed(applicationContext, token)
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
