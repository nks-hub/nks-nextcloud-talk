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
 * `addOnModeChangedListener` exists from API 31. Below that the SAME global
 * state is read by polling it, because there is nothing else left: a focus
 * listener cannot be used for the reason above, and `TelephonyManager`'s call
 * state would cost a `READ_PHONE_STATE` permission for one bit of information.
 * The poll runs only while a call is up — this stream is listened to for
 * exactly that long — and asks a process-local getter every
 * [POLL_INTERVAL_MS] ms, which is why it is affordable.
 *
 * Until 6 September 2026 the older devices reported NOTHING, and that mattered
 * more than it looked: the crash fixed the same day showed how many of them
 * there are, and on every one of them the microphone stayed open for the whole
 * of an incoming telephone call.
 *
 * THE LISTENER ITSELF IS NOT HELD HERE, and that is not tidiness. A field of
 * type `AudioManager.OnModeChangedListener` is resolved when this class is
 * loaded, which happens on every device that opens the app — a version check
 * inside a method never gets the chance to prevent it. It lives in
 * [CallAudioModeWatcher], which is only ever constructed above API 31.
 */
class CallAudioFocus(context: Context) : EventChannel.StreamHandler {

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    /** Held as [Any] so this class carries no API 31 type of its own. */
    private var watcher: Any? = null

    /** Last state the poll reported, so only changes reach the sink. */
    private var polled = false

    private val poll =
        object : Runnable {
            override fun run() {
                val now = callAudioModeInterrupts(audioManager.mode)
                if (now != polled) {
                    polled = now
                    sink?.success(if (now) BEGAN else ENDED)
                }
                handler.postDelayed(this, POLL_INTERVAL_MS)
            }
        }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            polled = callAudioModeInterrupts(audioManager.mode)
            handler.postDelayed(poll, POLL_INTERVAL_MS)
            return
        }
        val watcher =
            CallAudioModeWatcher(audioManager) { interrupted ->
                // Called on the executor handed over below, which posts to the
                // platform thread — the only one a sink may be used from.
                sink?.success(if (interrupted) BEGAN else ENDED)
            }
        this.watcher = watcher
        watcher.start { handler.post(it) }
    }

    override fun onCancel(arguments: Any?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (watcher as? CallAudioModeWatcher)?.stop()
        } else {
            handler.removeCallbacks(poll)
        }
        watcher = null
        polled = false
        sink = null
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/call_audio_focus"
        private const val BEGAN = "began"
        private const val ENDED = "ended"

        /**
         * How often the audio mode is read below API 31. A telephone call rings
         * for seconds, so half of one is well inside the window that matters,
         * and the read is a process-local getter.
         */
        internal const val POLL_INTERVAL_MS = 500L
    }
}

/**
 * Whether an audio mode means something else is using the phone's voice path.
 *
 * `MODE_IN_CALL` is a telephone call in progress and `MODE_RINGTONE` is one
 * ringing; the WebRTC engine's own mode is `MODE_IN_COMMUNICATION`, which is
 * not either of these. Both the API 31 listener and the poll below it decide
 * with this one function, so the two paths cannot drift apart.
 */
internal fun callAudioModeInterrupts(mode: Int): Boolean =
    mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_RINGTONE
