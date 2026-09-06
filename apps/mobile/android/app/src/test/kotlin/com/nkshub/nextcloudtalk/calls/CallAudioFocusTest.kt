package com.nkshub.nextcloudtalk.calls

import android.content.Context
import android.media.AudioManager
import io.flutter.plugin.common.EventChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

/**
 * Below API 31 there is no `addOnModeChangedListener`, and until 6 September
 * 2026 that meant the older devices reported no telephone interruption at all:
 * the microphone stayed open for the whole of an incoming call. The poll that
 * replaced the silence is what these assert, at the API level the rig's Galaxy
 * S9+ actually runs.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29])
class CallAudioFocusTest {
    @Test
    fun aTelephoneCallBelowApi31IsReportedAndSoIsItsEnd() {
        val context = RuntimeEnvironment.getApplication()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val events = mutableListOf<Any?>()
        val focus = CallAudioFocus(context)

        focus.onListen(null, recordingSink(events))
        assertTrue("nothing is reported while only this app is on the call", events.isEmpty())

        audio.mode = AudioManager.MODE_RINGTONE
        advanceOnePoll()
        assertEquals(listOf<Any?>("began"), events)

        // Answering it keeps the interruption; the state did not change, so the
        // sink must not hear about it twice.
        audio.mode = AudioManager.MODE_IN_CALL
        advanceOnePoll()
        assertEquals(listOf<Any?>("began"), events)

        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        advanceOnePoll()
        assertEquals(listOf<Any?>("began", "ended"), events)
    }

    @Test
    fun cancellingStopsThePollForGood() {
        val context = RuntimeEnvironment.getApplication()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val events = mutableListOf<Any?>()
        val focus = CallAudioFocus(context)

        focus.onListen(null, recordingSink(events))
        focus.onCancel(null)

        audio.mode = AudioManager.MODE_IN_CALL
        advanceOnePoll()
        advanceOnePoll()
        assertTrue("a call that ended must not keep reading the audio mode", events.isEmpty())
    }

    @Test
    fun theTwoPathsAgreeOnWhatCountsAsAnInterruption() {
        assertTrue(callAudioModeInterrupts(AudioManager.MODE_IN_CALL))
        assertTrue(callAudioModeInterrupts(AudioManager.MODE_RINGTONE))
        // The engine's own mode, which must never read as an interruption.
        assertFalse(callAudioModeInterrupts(AudioManager.MODE_IN_COMMUNICATION))
        assertFalse(callAudioModeInterrupts(AudioManager.MODE_NORMAL))
    }

    private fun advanceOnePoll() {
        shadowOf(android.os.Looper.getMainLooper())
            .idleFor(CallAudioFocus.POLL_INTERVAL_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
        ShadowLooper.idleMainLooper()
    }

    private fun recordingSink(events: MutableList<Any?>) =
        object : EventChannel.EventSink {
            override fun success(event: Any?) {
                events.add(event)
            }

            override fun error(code: String, message: String?, details: Any?) = Unit

            override fun endOfStream() = Unit
        }
}
