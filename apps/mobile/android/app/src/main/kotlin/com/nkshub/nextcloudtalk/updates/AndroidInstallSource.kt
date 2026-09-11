package com.nkshub.nextcloudtalk.updates

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Which application installed this build.
 *
 * The update check asks before it offers anything at all: a build that came
 * from Google Play is updated by Play, and offering a download beside it
 * breaks Play's rules. A build somebody installed from the published APK has
 * no such shop behind it, and is the only one that may be told a newer build
 * exists.
 *
 * Answers null when the question cannot be answered, which the Dart side
 * treats the same as "from a shop" — the cautious reading, because being
 * wrong the other way is the one that breaks a rule.
 */
internal class AndroidInstallSource(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD_INSTALLING_PACKAGE) {
            result.notImplemented()
            return
        }
        result.success(installingPackage())
    }

    private fun installingPackage(): String? = try {
        val packages = context.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packages.getInstallSourceInfo(context.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            packages.getInstallerPackageName(context.packageName)
        }
    } catch (error: Throwable) {
        // A package the system cannot describe is one this must not guess at.
        null
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/install_source"
        const val METHOD_INSTALLING_PACKAGE = "installingPackage"
    }
}
