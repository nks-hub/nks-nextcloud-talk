package com.nkshub.nextcloudtalk.attachments

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.nkshub.nextcloudtalk.R
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the process out of the cached-app freezer while attachments upload
 * or a text message is on its way to the server.
 *
 * Android freezes a backgrounded app about ten seconds after it leaves the
 * screen, and the system photo picker alone is enough to send it there. A
 * frozen process stops feeding the request body: the server then sees a chunk
 * that ends after a few kilobytes, and the upload sits in "Sending" until the
 * app has been back in front long enough for the idle timeout to notice. The
 * upload itself runs in Dart; this service only holds the process in the
 * foreground while it does. A text message sent the moment before the app is
 * left needs the same few seconds: frozen, its request never completes and
 * the message waits for the app to be opened again.
 */
class AttachmentTransferService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = notification(intent?.getBooleanExtra(EXTRA_WAITING, false) == true)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = this
        } catch (error: RuntimeException) {
            // Started from the background, or the daily dataSync budget is
            // spent: the upload still runs, it just is not protected.
            stopSelf(startId)
        }
        // Not sticky: without the Dart engine there is nothing to keep alive.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (running === this) {
            running = null
        }
        super.onDestroy()
    }

    /** Changes what the running service says it is doing. */
    fun show(waiting: Boolean) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification(waiting))
    }

    /**
     * [waiting] is the state after the app was left with a message that
     * cannot go out yet: nothing is being sent, the process only stays
     * reachable for the moment it can be.
     */
    private fun notification(waiting: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.attachment_upload_channel),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) },
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this, NOTIFICATION_ID, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(
                getString(
                    if (waiting) {
                        R.string.unsent_message_title
                    } else {
                        R.string.attachment_upload_title
                    },
                ),
            )
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(true)
            .build()
    }

    /** Android 15 caps dataSync; past it the service must leave on its own. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/attachment_transfer"
        const val EXTRA_WAITING = "waiting"

        /** The service while it is in the foreground, main thread only. */
        internal var running: AttachmentTransferService? = null
        private const val CHANNEL_ID = "attachment-upload"
        private const val NOTIFICATION_ID = 4111
        private const val UNSENT_NOTIFICATION_ID = 4112
        private const val PREFERENCES = "attachment_transfer"
        private const val KEY_UNSENT = "unsent_message_waiting"

        /** Whether [showUnsent] last announced a message that is still unsent. */
        fun unsentWaiting(context: Context): Boolean =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getBoolean(KEY_UNSENT, false)

        /**
         * Says that a message is still unsent once the service has given
         * up holding the process for it; nothing sends it until the app is
         * opened, so the sender must not be left believing it went out.
         */
        fun showUnsent(context: Context, shown: Boolean) {
            // Kept on disk: the push that may send the message later can
            // arrive in a process that was started just for it.
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_UNSENT, shown).apply()
            val manager = context.getSystemService(NotificationManager::class.java)
            if (!shown) {
                manager.cancel(UNSENT_NOTIFICATION_ID)
                return
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        context.getString(R.string.attachment_upload_channel),
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply { setShowBadge(false) },
                )
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context)
            }
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        context, UNSENT_NOTIFICATION_ID, launch,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            manager.notify(
                UNSENT_NOTIFICATION_ID,
                builder
                    .setSmallIcon(android.R.drawable.stat_notify_error)
                    .setContentTitle(context.getString(R.string.unsent_message_left_title))
                    .setContentText(context.getString(R.string.unsent_message_left_text))
                    .setAutoCancel(true)
                    .build(),
            )
        }
    }
}

/** `start` / `stop` from Dart, both best effort. */
class AttachmentTransferChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val intent = Intent(context, AttachmentTransferService::class.java)
        when (call.method) {
            "start" -> {
                val waiting = call.argument<Boolean>("waiting") == true
                intent.putExtra(AttachmentTransferService.EXTRA_WAITING, waiting)
                val running = AttachmentTransferService.running
                if (running != null) {
                    // Already in the foreground: only its text changes, and a
                    // second start from the background would be refused.
                    running.show(waiting)
                    result.success(null)
                    return
                }
                runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                }
                result.success(null)
            }
            "stop" -> {
                runCatching { context.stopService(intent) }
                result.success(null)
            }
            "unsent" -> {
                runCatching {
                    AttachmentTransferService.showUnsent(
                        context,
                        call.argument<Boolean>("shown") == true,
                    )
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
