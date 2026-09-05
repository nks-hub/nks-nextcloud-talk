package com.nkshub.nextcloudtalk.calls

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps a call visible as a small window when the user leaves the app.
 *
 * Dart arms this while the call screen is showing and disarms it when the
 * screen goes away, so an ordinary conversation never shrinks into a window.
 * From API 31 the platform enters the window itself on the home gesture
 * (`setAutoEnterEnabled`), which is the only way to get the smooth transition;
 * on API 26–30 the activity's `onUserLeaveHint` does it. Below API 26, and on
 * devices without the feature, `setAvailable` answers `false` and the screen
 * stays a plain full-screen page.
 *
 * The aspect ratio is a portrait tile, the same shape as one participant in
 * the grid.
 */
class CallPictureInPicture(private val activity: Activity) : MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var available = false

    fun attach(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler(this)
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        available = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setAvailable" -> {
                val wanted = call.arguments as? Boolean ?: false
                result.success(setAvailable(wanted))
            }
            else -> result.notImplemented()
        }
    }

    /** The user is leaving the app (API 26–30 path). */
    fun onUserLeaveHint() {
        if (!available || Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !activity.isInPictureInPictureMode) {
            runCatching { activity.enterPictureInPictureMode(params(autoEnter = false)) }
        }
    }

    fun onPictureInPictureModeChanged(active: Boolean) {
        channel?.invokeMethod("modeChanged", active)
    }

    private fun setAvailable(wanted: Boolean): Boolean {
        if (!supported()) {
            available = false
            return false
        }
        available = wanted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { activity.setPictureInPictureParams(params(autoEnter = wanted)) }
        }
        return true
    }

    private fun supported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun params(autoEnter: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(3, 4))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnter)
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/call_picture_in_picture"
    }
}
