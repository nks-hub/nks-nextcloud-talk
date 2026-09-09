package com.nkshub.nextcloudtalk.calls

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorManager
import android.os.PowerManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Blanks the screen while the phone is held at the ear during a call.
 *
 * Android has one mechanism for this and it belongs to the system:
 * `PROXIMITY_SCREEN_OFF_WAKE_LOCK`. While it is held the platform turns the
 * screen and the touchscreen off whenever the proximity sensor reports "near"
 * and back on when it reports "far". The application never reads the sensor,
 * never decides when to blank, and cannot leave the screen off — releasing the
 * lock restores the display whatever the sensor says.
 *
 * Two things are checked before it is offered, and both can be false on a real
 * device: the platform has to support the lock level at all
 * (`isWakeLockLevelSupported`, API 21) and the device has to have a proximity
 * sensor. A tablet typically has neither.
 *
 * The lock is not reference counted. There is one call at a time and one
 * screen, so [acquire] with the lock already held is a no-op, and [release] is
 * safe to call when nothing is held — which is what the activity does when its
 * engine goes away, so a lock cannot outlive the call that asked for it.
 */
class CallProximityLock(context: Context) : MethodChannel.MethodCallHandler {

    private val powerManager =
        context.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private var lock: PowerManager.WakeLock? = null

    private val supported: Boolean
        get() =
            powerManager.isWakeLockLevelSupported(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
            ) && sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY) != null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supported" -> result.success(supported)
            "acquire" -> result.success(acquire())
            "release" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** True when the screen is now under the sensor's control. */
    fun acquire(): Boolean {
        if (lock?.isHeld == true) {
            return true
        }
        if (!supported) {
            return false
        }
        val acquired =
            powerManager.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                WAKE_LOCK_TAG,
            )
        return try {
            acquired.acquire()
            lock = acquired
            true
        } catch (error: RuntimeException) {
            // A device can refuse the level even after reporting support.
            lock = null
            false
        }
    }

    fun release() {
        val held = lock ?: return
        lock = null
        if (held.isHeld) {
            held.release()
        }
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/call_proximity"

        /** Shown in `dumpsys power`, so it names the app and the purpose. */
        private const val WAKE_LOCK_TAG = "NKSTalk:call-proximity"
    }
}
