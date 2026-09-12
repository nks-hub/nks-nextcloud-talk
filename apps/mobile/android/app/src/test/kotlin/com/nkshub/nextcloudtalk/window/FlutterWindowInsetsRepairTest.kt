package com.nkshub.nextcloudtalk.window

import android.content.Context
import android.graphics.Insets
import android.view.View
import android.view.WindowInsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The half-screen bug: Flutter's deferring callback keeps consuming insets after
 * a keyboard animation that never ended, so the view goes on believing the
 * keyboard is still there. These prove the repair notices exactly that and
 * leaves every other case alone.
 */
@RunWith(RobolectricTestRunner::class)
class FlutterWindowInsetsRepairTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    /** A view that records the insets it was actually given. */
    private class RecordingView(context: Context) : View(context) {
        val applied = mutableListOf<WindowInsets>()

        override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
            applied.add(insets)
            return super.onApplyWindowInsets(insets)
        }
    }

    private fun insets(keyboard: Int, visible: Boolean): WindowInsets =
        WindowInsets.Builder()
            .setInsets(WindowInsets.Type.ime(), Insets.of(0, 0, 0, keyboard))
            .setVisible(WindowInsets.Type.ime(), visible)
            .build()

    @Test
    fun `insets a stuck callback swallows are applied to the view anyway`() {
        val view = RecordingView(context)
        // What ImeSyncDeferringInsetsCallback does for as long as it believes an
        // IME animation is running.
        view.setOnApplyWindowInsetsListener { _, _ -> WindowInsets.CONSUMED }

        val repaired = FlutterWindowInsetsRepair.apply(view, insets(0, visible = false))

        assertTrue("the swallowed update has to be noticed", repaired)
        assertEquals(1, view.applied.size)
        assertEquals(
            0,
            view.applied.single().getInsets(WindowInsets.Type.ime()).bottom,
        )
    }

    @Test
    fun `an ordinary dispatch is left to do its own work`() {
        val view = RecordingView(context)

        val repaired = FlutterWindowInsetsRepair.apply(view, insets(0, visible = false))

        assertFalse("nothing is stuck, so nothing is worked around", repaired)
        assertEquals(
            "the ordinary dispatch is what applied them",
            1,
            view.applied.size,
        )
    }

    @Test
    fun `a keyboard that is really on screen keeps its inset`() {
        val view = RecordingView(context)
        view.setOnApplyWindowInsetsListener { _, _ -> WindowInsets.CONSUMED }

        val repaired = FlutterWindowInsetsRepair.apply(view, insets(1200, visible = true))

        assertFalse(repaired)
        assertTrue(
            "an animating keyboard must not be interrupted",
            view.applied.isEmpty(),
        )
    }
}
