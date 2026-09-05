package com.nkshub.nextcloudtalk.calls

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Reports when a telephone call takes the audio away from a Talk call and when
 * it gives it back.
 *
 * Measured on 5 September 2026 with a connected call and a simulated incoming
 * telephone call: the WebRTC engine received `AUDIOFOCUS_LOSS_TRANSIENT` and
 * carried on capturing regardless, so the other participants kept hearing the
 * room for as long as the phone rang. Nothing above the plugin was listening.
 *
 * WHY THIS WATCHES THE AUDIO MODE AND NOT AUDIO FOCUS. The first version
 * requested focus in order to be told about changes — a focus listener only
 * fires for a request you made yourself. That was measured to be self-defeating:
 * the WebRTC engine holds `AUDIOFOCUS_GAIN` for voice communication, and the
 * moment it took it (`getUserMedia` at 09:30:20.998) this app's own request was
 * evicted with `onAudioFocusChange(-1)` at 09:30:21.017 and dropped from the
 * focus stack. Subscribing before the engine gets evicted; subscribing after
 * would evict the engine. Focus cannot be shared within one process.
 *
 * The audio mode is global state that the telecom stack changes for everyone:
 * `AS.AudioService … onModeUpdate mode=2` (`MODE_IN_CALL`) when the telephone
 * call was answered and `mode=3` (`MODE_IN_COMMUNICATION`, the WebRTC engine's
 * own mode) when it ended. Observing it takes no permission and takes nothing
 * from the engine. It fires when the other call is ANSWERED, not while it only
 * rings — the engine's mode wins while it rings — so the microphone closes the
 * moment the user is actually talking to someone else, which is the case that
 * matters for privacy.
 *
 * `addOnModeChangedListener` exists from API 31. Below that this reports
 * nothing, and the Dart side treats silence as "no interruptions", which is
 * honest: the older devices behave as they did before this change.
 */
class CallAudioFocus(context: Context) : EventChannel.StreamHandler {

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var interrupted = false

    private val listener = AudioManager.OnModeChangedListener { mode ->
        val now = mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_RINGTONE
        if (now == interrupted) {
            return@OnModeChangedListener
        }
        interrupted = now
        val event = if (now) BEGAN else ENDED
        // The callback runs on the executor handed over below, which is the
        // platform thread, the only one a sink may be used from.
        sink?.success(event)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return
        }
        interrupted = false
        audioManager.addOnModeChangedListener({ handler.post(it) }, listener)
    }

    override fun onCancel(arguments: Any?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.removeOnModeChangedListener(listener)
        }
        sink = null
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/call_audio_focus"
        private const val BEGAN = "began"
        private const val ENDED = "ended"
    }
}
