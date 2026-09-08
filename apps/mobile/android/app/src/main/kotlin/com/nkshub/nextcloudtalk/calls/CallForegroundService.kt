package com.nkshub.nextcloudtalk.calls

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.nkshub.nextcloudtalk.R
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Keeps user-accepted call audio eligible after the Activity loses visibility. */
class CallForegroundService : Service() {
    private var generation = 0L
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requestedGeneration = intent?.getLongExtra(EXTRA_GENERATION, currentGeneration) ?: currentGeneration
        if (requestedGeneration != currentGeneration) return START_NOT_STICKY
        generation = requestedGeneration
        if (owners.isEmpty()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL_ID, getString(R.string.call_notification_channel),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) })
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                Notification.Builder(this)
            }
            val launch = packageManager.getLaunchIntentForPackage(packageName)
            if (launch != null) {
                builder.setContentIntent(PendingIntent.getActivity(
                    this, NOTIFICATION_ID, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ))
            }
            val notification = builder
                .setSmallIcon(android.R.drawable.sym_action_call)
                .setContentTitle(getString(R.string.call_notification_title))
                .setContentText(getString(R.string.call_notification_text))
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setOngoing(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            foreground = true
            val callbacks = pending.values.toList()
            pending.clear()
            callbacks.forEach { it(true) }
        } catch (error: RuntimeException) {
            // Android 12/14 may revoke foreground-start eligibility between callbacks.
            foreground = false
            owners.clear()
            val callbacks = pending.values.toList()
            pending.clear()
            callbacks.forEach { it(false) }
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (generation != currentGeneration) {
            super.onDestroy()
            return
        }
        foreground = false
        owners.clear()
        val callbacks = pending.values.toList()
        pending.clear()
        callbacks.forEach { it(false) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/call_foreground"
        private const val CHANNEL_ID = "ongoing-calls"
        private const val NOTIFICATION_ID = 4110
        private const val EXTRA_GENERATION = "call-generation"
        private var currentGeneration = 0L
        private val owners = mutableSetOf<String>()
        private val pending = mutableMapOf<String, (Boolean) -> Unit>()
        private var foreground = false

        fun start(context: Context, owner: String, completion: (Boolean) -> Unit) {
            if (owners.contains(owner)) {
                completion(foreground)
                return
            }
            if (owners.isEmpty()) currentGeneration++
            owners.add(owner)
            if (foreground) {
                completion(true)
                return
            }
            pending[owner] = completion
            try {
                val intent = Intent(context, CallForegroundService::class.java)
                    .putExtra(EXTRA_GENERATION, currentGeneration)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (error: RuntimeException) {
                stop(context, owner)
            }
        }

        fun stop(context: Context, owner: String) {
            if (!owners.remove(owner)) return
            pending.remove(owner)?.invoke(false)
            if (owners.isEmpty()) {
                foreground = false
                context.stopService(Intent(context, CallForegroundService::class.java))
            }
        }
    }
}

/** Permission and visibility gate; no background receiver can reach this channel. */
class CallForegroundChannel(
    private val activity: Activity,
    private val isResumed: () -> Boolean,
) : MethodChannel.MethodCallHandler {
    private val handler = Handler(Looper.getMainLooper())
    private val owners = mutableSetOf<String>()
    private var permissionOwner: String? = null
    private var permissionResult: MethodChannel.Result? = null
    private var disposed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = call.argument<String>("owner")
        if (owner.isNullOrBlank() || owner.length > 128) {
            result.error("invalid-owner", "A call owner is required.", null)
            return
        }
        when (call.method) {
            "start" -> {
                if (disposed || !isResumed() || permissionResult != null) {
                    result.success("unavailable")
                    return
                }
                if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    start(owner, result)
                } else {
                    permissionOwner = owner
                    permissionResult = result
                    try {
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_CODE)
                    } catch (error: RuntimeException) {
                        finishPermission("unavailable")
                    }
                }
            }
            "stop" -> {
                if (permissionOwner == owner) finishPermission("unavailable")
                owners.remove(owner)
                CallForegroundService.stop(activity.applicationContext, owner)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            finishPermission("permission-denied")
        } else if (isResumed()) {
            onResume()
        } else {
            val owner = permissionOwner
            handler.postDelayed({ if (permissionOwner == owner) finishPermission("unavailable") }, 3000)
        }
        return true
    }

    fun onResume() {
        val owner = permissionOwner ?: return
        if (disposed || !isResumed() ||
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return
        val result = permissionResult ?: return
        permissionOwner = null
        permissionResult = null
        start(owner, result)
    }

    private fun finishPermission(status: String) {
        val result = permissionResult
        permissionOwner = null
        permissionResult = null
        result?.success(status)
    }

    private fun start(owner: String, result: MethodChannel.Result) {
        if (disposed || !isResumed()) {
            result.success("unavailable")
            return
        }
        owners.add(owner)
        var answered = false
        val timeout = Runnable {
            if (!answered) CallForegroundService.stop(activity.applicationContext, owner)
        }
        handler.postDelayed(timeout, 3000)
        CallForegroundService.start(activity.applicationContext, owner) { started ->
            if (!answered) {
                answered = true
                handler.removeCallbacks(timeout)
                if (!started) owners.remove(owner)
                result.success(if (started) "started" else "unavailable")
            }
        }
    }

    fun dispose() {
        disposed = true
        finishPermission("unavailable")
        owners.toList().forEach { CallForegroundService.stop(activity.applicationContext, it) }
        owners.clear()
        handler.removeCallbacksAndMessages(null)
    }

    companion object {
        const val REQUEST_CODE = 4110
    }
}
