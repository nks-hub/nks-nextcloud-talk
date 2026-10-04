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
 * Keeps the process out of the cached-app freezer while attachments upload.
 *
 * Android freezes a backgrounded app about ten seconds after it leaves the
 * screen, and the system photo picker alone is enough to send it there. A
 * frozen process stops feeding the request body: the server then sees a chunk
 * that ends after a few kilobytes, and the upload sits in "Sending" until the
 * app has been back in front long enough for the idle timeout to notice. The
 * upload itself runs in Dart; this service only holds the process in the
 * foreground while it does.
 */
class AttachmentTransferService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(getString(R.string.attachment_upload_title))
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(true)
            .build()
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
        } catch (error: RuntimeException) {
            // Started from the background, or the daily dataSync budget is
            // spent: the upload still runs, it just is not protected.
            stopSelf(startId)
        }
        // Not sticky: without the Dart engine there is nothing to keep alive.
        return START_NOT_STICKY
    }

    /** Android 15 caps dataSync; past it the service must leave on its own. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/attachment_transfer"
        private const val CHANNEL_ID = "attachment-upload"
        private const val NOTIFICATION_ID = 4111
    }
}

/** `start` / `stop` from Dart, both best effort. */
class AttachmentTransferChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val intent = Intent(context, AttachmentTransferService::class.java)
        when (call.method) {
            "start" -> {
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
            else -> result.notImplemented()
        }
    }
}
