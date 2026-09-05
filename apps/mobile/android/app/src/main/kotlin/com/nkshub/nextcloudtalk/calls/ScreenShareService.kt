package com.nkshub.nextcloudtalk.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The foreground service a screen capture needs.
 *
 * From Android 10 a `MediaProjection` may only be obtained while a foreground
 * service of type `mediaProjection` is running, and from Android 14 the
 * platform kills the capture outright when it is not. The plugin that opens
 * the screen (`flutter_webrtc`) ships no such service, so the app owns one:
 * Dart starts it before asking for the screen and stops it when the share
 * ends, and its notification is what tells the user the screen is being
 * shared.
 */
class ScreenShareService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(manager)
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Sharing your screen")
            .setContentText("Your screen is visible to everyone in the call.")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // Only now may the projection be taken. `startForegroundService`
        // returns before this runs, and a capture that raced ahead of it died
        // in `MediaProjection.start` (measured on the Android 14 emulator on
        // 5 September 2026 — the very same tap worked when the timing fell the
        // other way).
        onForeground?.invoke(true)
        onForeground = null
        // Not sticky: a share that died with the process is over, and a
        // restarted service without a projection would only show a lying
        // notification.
        return START_NOT_STICKY
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Screen sharing",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while your screen is shared into a call"
                setShowBadge(false)
            },
        )
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/screen_share"

        /** Told once the service is actually in the foreground; see above. */
        @Volatile
        var onForeground: ((Boolean) -> Unit)? = null
        private const val CHANNEL_ID = "screen-share"
        private const val NOTIFICATION_ID = 4109
    }
}

/**
 * Starts and stops [ScreenShareService] for Dart. `start` answers whether the
 * platform can capture at all, so a device without the projection API reports
 * an unavailable screen rather than a silent failure.
 */
class ScreenShareChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
                    result.success(false)
                    return
                }
                // Answered when the service reports itself in the foreground,
                // not when the start was merely requested; a service that never
                // gets there answers false after a moment rather than hanging.
                val handler = Handler(Looper.getMainLooper())
                var answered = false
                val answer: (Boolean) -> Unit = { ok ->
                    if (!answered) {
                        answered = true
                        ScreenShareService.onForeground = null
                        result.success(ok)
                    }
                }
                ScreenShareService.onForeground = { ok -> handler.post { answer(ok) } }
                handler.postDelayed({ answer(false) }, 3000)
                val requested = runCatching {
                    val intent = Intent(context, ScreenShareService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                }.isSuccess
                if (!requested) {
                    answer(false)
                }
            }
            "stop" -> {
                runCatching {
                    context.stopService(Intent(context, ScreenShareService::class.java))
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
