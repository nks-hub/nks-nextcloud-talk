package com.nkshub.nextcloudtalk.calls

import android.media.AudioManager
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Watches the device's audio mode and says when a telephone call takes it over.
 *
 * This class exists ONLY to hold [AudioManager.OnModeChangedListener], which
 * arrived in API 31. A field or lambda of that type makes the class that
 * declares it unloadable on an older device — ART resolves the interface when
 * the class is loaded, long before any `Build.VERSION` check inside a method
 * gets to run. Keeping it here means nothing below API 31 ever touches it: the
 * caller decides by version whether to construct this at all.
 *
 * Measured on a Galaxy S9+ (Android 10) with build 61, where the listener still
 * lived on [CallAudioFocus]: the application died at launch with
 * `NoClassDefFoundError: Landroid/media/AudioManager$OnModeChangedListener` as
 * the activity was being instantiated. It could not start at all.
 */
@RequiresApi(Build.VERSION_CODES.S)
internal class CallAudioModeWatcher(
    private val audioManager: AudioManager,
    private val onInterruptionChanged: (Boolean) -> Unit,
) {
    private var interrupted = false

    private val listener =
        AudioManager.OnModeChangedListener { mode ->
            val now = callAudioModeInterrupts(mode)
            if (now != interrupted) {
                interrupted = now
                onInterruptionChanged(now)
            }
        }

    fun start(post: (Runnable) -> Unit) {
        interrupted = false
        audioManager.addOnModeChangedListener({ post(it) }, listener)
    }

    fun stop() {
        audioManager.removeOnModeChangedListener(listener)
    }
}
