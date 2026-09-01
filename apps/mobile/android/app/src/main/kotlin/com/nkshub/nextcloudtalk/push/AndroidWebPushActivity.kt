package com.nkshub.nextcloudtalk.push

import android.Manifest
import android.app.RemoteInput
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.nkshub.nextcloudtalk.contacts.ContactPickerChannel
import com.nkshub.nextcloudtalk.share.AndroidShareCaptureResult
import com.nkshub.nextcloudtalk.share.AndroidShareDelivery
import com.nkshub.nextcloudtalk.share.AndroidShareInbox
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.concurrent.Executors

class AndroidWebPushActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var deepLinkChannel: MethodChannel? = null
    private var shareChannel: MethodChannel? = null
    private var deviceKeyChannel: MethodChannel? = null
    private var deviceKeyStore: AndroidPushDeviceKeyStore? = null
    private var fcmChannel: MethodChannel? = null
    private var contactPickerChannel: ContactPickerChannel? = null
    private val shareExecutor = Executors.newSingleThreadExecutor()
    private val shareInbox by lazy { AndroidShareInbox(applicationContext) }
    private val fcmTokenListener: (String) -> Unit = { token ->
        mainHandler.post {
            fcmChannel?.invokeMethod("tokenRefreshed", token)
        }
    }
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val notificationOpenDelivery = AndroidNotificationOpenDelivery { notification ->
        mainHandler.post {
            methodChannel?.invokeMethod("notificationOpened", notification)
        }
    }
    private val deepLinkDelivery = AndroidNotificationOpenDelivery { link ->
        mainHandler.post {
            deepLinkChannel?.invokeMethod("linkOpened", link)
        }
    }
    private val shareDelivery = AndroidShareDelivery { share ->
        mainHandler.post {
            shareChannel?.invokeMethod("shareOpened", share)
        }
    }
    private val notifierListener: (Int) -> Unit = { count ->
        mainHandler.post {
            methodChannel?.invokeMethod("eventsAvailable", mapOf("count" to count))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        notificationAction(intent)?.route?.let(notificationOpenDelivery::opened)
        notificationOpen(intent)?.let(notificationOpenDelivery::opened)
        deepLinkOpen(intent)?.let(deepLinkDelivery::opened)
        captureShare(intent, deduplicatePending = true)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        val handler = AndroidWebPushChannel(applicationContext, this)
        channel.setMethodCallHandler(handler)
        methodChannel = channel
        AndroidWebPushNotifier.attach(notifierListener)

        val deepLink = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEP_LINK_CHANNEL_NAME,
        )
        deepLink.setMethodCallHandler { call, result ->
            if (call.method == "getLaunchLink") {
                result.success(takeLaunchDeepLink())
            } else {
                result.notImplemented()
            }
        }
        deepLinkChannel = deepLink

        val share = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL_NAME,
        )
        share.setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchShare" -> result.success(shareDelivery.markReadyAndTakeLaunch())
                "completeShare" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("invalid-share", "A share id is required.", null)
                    } else {
                        shareExecutor.execute {
                            val completed = shareInbox.complete(id)
                            mainHandler.post { result.success(completed) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        shareChannel = share
        shareExecutor.execute {
            shareInbox.pending().forEach(shareDelivery::opened)
        }

        // The push-v2 device key is independent of Web Push: it belongs to the
        // proxy transport, but it lives on the same engine, so it is wired here
        // rather than in a second activity.
        val deviceKey = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AndroidPushDeviceKeyStore.CHANNEL_NAME,
        )
        val deviceKeyHandler = AndroidPushDeviceKeyStore()
        deviceKey.setMethodCallHandler(deviceKeyHandler)
        deviceKeyChannel = deviceKey
        deviceKeyStore = deviceKeyHandler

        val fcm = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AndroidFcmChannel.CHANNEL_NAME,
        )
        fcm.setMethodCallHandler(AndroidFcmChannel(applicationContext))
        fcmChannel = fcm
        AndroidFcmChannel.attach(fcmTokenListener)

        contactPickerChannel = ContactPickerChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (contactPickerChannel?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        notificationAction(intent)?.route?.let(notificationOpenDelivery::opened)
        notificationOpen(intent)?.let(notificationOpenDelivery::opened)
        deepLinkOpen(intent)?.let(deepLinkDelivery::opened)
        captureShare(intent, deduplicatePending = false)
    }

    internal fun registrationPermissionStatus(): Map<String, String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return mapOf("status" to "granted")
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            return mapOf("status" to "granted")
        }
        val asked = getSharedPreferences(PERMISSION_PREFERENCES, MODE_PRIVATE)
            .getBoolean(PERMISSION_ASKED, false)
        return mapOf("status" to if (asked) "denied" else "notDetermined")
    }

    internal fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(mapOf("status" to "granted"))
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "A notification permission request is already active.",
                null,
            )
            return
        }
        pendingPermissionResult = result
        setPermissionAsked(true)
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    internal fun takeLaunchNotification(): Map<String, Any?>? {
        return notificationOpenDelivery.markReadyAndTakeLaunch()
    }

    internal fun takeLaunchDeepLink(): Map<String, Any?>? {
        return deepLinkDelivery.markReadyAndTakeLaunch()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) {
            return
        }
        if (grantResults.isEmpty()) {
            setPermissionAsked(false)
        }
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        result.success(registrationPermissionStatus())
    }

    override fun onDestroy() {
        AndroidWebPushNotifier.detach(notifierListener)
        if (pendingPermissionResult != null) {
            setPermissionAsked(false)
        }
        pendingPermissionResult?.error(
            "permission_request_cancelled",
            "The notification permission request was cancelled.",
            null,
        )
        pendingPermissionResult = null
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        deepLinkChannel?.setMethodCallHandler(null)
        deepLinkChannel = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        deviceKeyChannel?.setMethodCallHandler(null)
        deviceKeyChannel = null
        deviceKeyStore?.dispose()
        deviceKeyStore = null
        AndroidFcmChannel.detach(fcmTokenListener)
        fcmChannel?.setMethodCallHandler(null)
        fcmChannel = null
        contactPickerChannel?.dispose()
        contactPickerChannel = null
        shareExecutor.shutdown()
        super.onDestroy()
    }

    internal fun notificationOpen(intent: Intent?): Map<String, Any?>? {
        val openIntent = intent ?: return null
        val token = AndroidSystemNotifications.notificationOpenToken(openIntent, packageName)
            ?: return null
        return runCatching {
            AndroidWebPushStore(applicationContext).consumeNotificationOpen(token)
        }.getOrNull()
    }

    internal fun notificationAction(intent: Intent?): NotificationActionLaunch? {
        val actionIntent = intent ?: return null
        val request = AndroidSystemNotifications.notificationActionRequest(
            actionIntent,
            packageName,
        ) ?: return null
        val (kind, token) = request
        val replyText = if (kind == NotificationActionKind.REPLY) {
            RemoteInput.getResultsFromIntent(actionIntent)
                ?.getCharSequence(AndroidSystemNotifications.REPLY_RESULT_KEY)
                ?.toString()
                ?.trim()
                ?.take(AndroidSystemNotifications.MAX_REPLY_LENGTH)
        } else {
            null
        }
        return runCatching {
            AndroidSystemNotifications.performAction(
                applicationContext,
                kind,
                token,
                replyText,
            )
        }.getOrNull()
    }

    internal fun deepLinkOpen(intent: Intent?): Map<String, Any?>? {
        val openIntent = intent ?: return null
        if (openIntent.action != Intent.ACTION_VIEW) {
            return null
        }
        val uri = openIntent.data ?: return null
        return mapOf("uri" to uri.toString())
    }

    private fun setPermissionAsked(asked: Boolean) {
        getSharedPreferences(PERMISSION_PREFERENCES, MODE_PRIVATE)
            .edit()
            .putBoolean(PERMISSION_ASKED, asked)
            .apply()
    }

    private fun captureShare(intent: Intent?, deduplicatePending: Boolean) {
        shareExecutor.execute {
            when (val result = shareInbox.capture(intent, deduplicatePending)) {
                is AndroidShareCaptureResult.Accepted -> shareDelivery.opened(result.share)
                AndroidShareCaptureResult.Ignored,
                is AndroidShareCaptureResult.Rejected,
                -> Unit
            }
        }
    }

    companion object {
        private const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/android_web_push"
        private const val DEEP_LINK_CHANNEL_NAME = "com.nkshub.nextcloudtalk/deep_link"
        private const val SHARE_CHANNEL_NAME = "com.nkshub.nextcloudtalk/share"
        internal const val PERMISSION_PREFERENCES = "android_web_push_permission"
        internal const val PERMISSION_ASKED = "asked"
        internal const val NOTIFICATION_PERMISSION_REQUEST = 4107
    }
}

internal class AndroidNotificationOpenDelivery(
    private val deliver: (Map<String, Any?>) -> Unit,
) {
    private val pending = ArrayDeque<Map<String, Any?>>()
    private var ready = false

    fun opened(notification: Map<String, Any?>) {
        val liveNotification = synchronized(this) {
            if (!ready) {
                if (pending.size >= MAX_PENDING_NOTIFICATION_OPENS) {
                    val launch = pending.removeFirst()
                    pending.removeFirst()
                    pending.addFirst(launch)
                }
                pending.addLast(notification)
                null
            } else {
                notification
            }
        }
        liveNotification?.let(deliver)
    }

    fun markReadyAndTakeLaunch(): Map<String, Any?>? {
        val callbacks = mutableListOf<Map<String, Any?>>()
        val launch = synchronized(this) {
            if (ready) {
                return null
            }
            ready = true
            val first = pending.pollFirst()
            while (pending.isNotEmpty()) {
                callbacks.add(pending.removeFirst())
            }
            first
        }
        callbacks.forEach(deliver)
        return launch
    }

    companion object {
        internal const val MAX_PENDING_NOTIFICATION_OPENS = 128
    }
}
