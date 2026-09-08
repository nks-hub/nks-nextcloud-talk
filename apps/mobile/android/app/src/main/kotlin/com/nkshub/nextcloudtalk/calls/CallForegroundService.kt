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

/** Keeps accepted audio and explicitly enabled video eligible after visibility is lost. */
open class CallForegroundService : Service() {
    private var generation = 0L
    private var notification: Notification? = null
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requestedGeneration = intent?.getLongExtra(EXTRA_GENERATION, currentGeneration) ?: currentGeneration
        if (requestedGeneration != currentGeneration) return START_NOT_STICKY
        generation = requestedGeneration
        if (owners.isEmpty()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        activeService = this
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
            notification = builder
                .setSmallIcon(android.R.drawable.sym_action_call)
                .setContentTitle(getString(R.string.call_notification_title))
                .setContentText(getString(R.string.call_notification_text))
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setOngoing(true)
                .build()
            promoteForOwners()
            foreground = true
            val callbacks = pending.values.toList()
            pending.clear()
            callbacks.forEach { it(true) }
        } catch (error: RuntimeException) {
            // Android 12/14 may revoke foreground-start eligibility between callbacks.
            foreground = false
            owners.clear()
            cameraOwners.clear()
            if (activeService === this) activeService = null
            val callbacks = pending.values.toList()
            pending.clear()
            callbacks.forEach { it(false) }
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun promoteForOwners() {
        val current = notification ?: throw IllegalStateException("Call notification is absent")
        var types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        } else 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && cameraOwners.isNotEmpty()) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        promoteNotification(current, types)
    }

    protected open fun promoteNotification(notification: Notification, types: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, types)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        if (generation != currentGeneration) {
            super.onDestroy()
            return
        }
        foreground = false
        owners.clear()
        cameraOwners.clear()
        if (activeService === this) activeService = null
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
        private val cameraOwners = mutableSetOf<String>()
        private val pending = mutableMapOf<String, (Boolean) -> Unit>()
        private var foreground = false
        private var activeService: CallForegroundService? = null

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
            val hadCamera = cameraOwners.remove(owner)
            pending.remove(owner)?.invoke(false)
            if (owners.isEmpty()) {
                foreground = false
                activeService = null
                context.stopService(Intent(context, CallForegroundService::class.java))
            } else if (hadCamera) {
                try {
                    activeService?.promoteForOwners()
                } catch (_: RuntimeException) {
                    // Stopping one owner must not stop another owner's microphone.
                }
            }
        }

        fun setCameraEnabled(owner: String, enabled: Boolean): Boolean {
            val service = activeService
            if (!foreground || !owners.contains(owner) || service == null ||
                service.generation != currentGeneration) return false
            val previous = cameraOwners.contains(owner)
            if (previous == enabled) return true
            if (enabled) cameraOwners.add(owner) else cameraOwners.remove(owner)
            return try {
                service.promoteForOwners()
                true
            } catch (_: RuntimeException) {
                // A rejected camera upgrade leaves the already-running audio service intact.
                if (previous) cameraOwners.add(owner) else cameraOwners.remove(owner)
                false
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
    private var cameraPermission = false
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
                    cameraPermission = false
                    try {
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_CODE)
                    } catch (error: RuntimeException) {
                        finishPermission("unavailable")
                    }
                }
            }
            "setCameraEnabled" -> {
                val enabled = call.argument<Any>("enabled") as? Boolean
                if (enabled == null) {
                    result.error("invalid-camera-state", "A camera state is required.", null)
                    return
                }
                if (disposed || !owners.contains(owner)) {
                    result.success("unavailable")
                    return
                }
                if (!enabled) {
                    if (permissionOwner == owner && cameraPermission) finishPermission("unavailable")
                    updateCamera(owner, false, result)
                } else if (!isResumed() || permissionResult != null) {
                    result.success("unavailable")
                } else if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    updateCamera(owner, true, result)
                } else {
                    permissionOwner = owner
                    permissionResult = result
                    cameraPermission = true
                    try {
                        activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_REQUEST_CODE)
                    } catch (_: RuntimeException) {
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
        if (requestCode != REQUEST_CODE && requestCode != CAMERA_REQUEST_CODE) return false
        if (permissionResult == null || (requestCode == CAMERA_REQUEST_CODE) != cameraPermission) return true
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
        val permission = if (cameraPermission) Manifest.permission.CAMERA else Manifest.permission.RECORD_AUDIO
        if (disposed || !isResumed() ||
            activity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) return
        val result = permissionResult ?: return
        val camera = cameraPermission
        permissionOwner = null
        permissionResult = null
        cameraPermission = false
        if (camera) updateCamera(owner, true, result) else start(owner, result)
    }

    private fun finishPermission(status: String) {
        val result = permissionResult
        permissionOwner = null
        permissionResult = null
        cameraPermission = false
        result?.success(status)
    }

    private fun updateCamera(owner: String, enabled: Boolean, result: MethodChannel.Result) {
        if (disposed || !owners.contains(owner) ||
            (enabled && (!isResumed() ||
                activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED))) {
            result.success("unavailable")
            return
        }
        result.success(if (CallForegroundService.setCameraEnabled(owner, enabled)) "started" else "unavailable")
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
        const val CAMERA_REQUEST_CODE = 4111
    }
}
