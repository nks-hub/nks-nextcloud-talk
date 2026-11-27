package com.nkshub.nextcloudtalk.window

import android.app.Activity
import android.content.Context
import android.graphics.Insets
import android.os.Looper
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.widget.FrameLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.time.Duration

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
        var windowInsets: WindowInsets? = null

        override fun getRootWindowInsets(): WindowInsets? = windowInsets ?: super.getRootWindowInsets()

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

    private fun attachedWindow(): Pair<FrameLayout, RecordingView> {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val container = FrameLayout(activity)
        val view = RecordingView(activity)
        container.addView(view)
        FlutterWindowInsetsRepair.watchKeyboardDismissals(container) { view }
        activity.setContentView(container)
        return container to view
    }

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

    @Test
    fun `a swallowed keyboard dismissal recovers without a window focus change`() {
        val (container, view) = attachedWindow()
        val shown = insets(825, visible = true)
        view.windowInsets = shown
        container.dispatchApplyWindowInsets(shown)
        FlutterWindowInsetsRepair.repair(view)

        view.setOnApplyWindowInsetsListener { _, _ -> WindowInsets.CONSUMED }
        val hidden = insets(0, visible = false)
        view.windowInsets = hidden
        container.dispatchApplyWindowInsets(hidden)

        val ime = WindowInsets.Type.ime()
        assertEquals(825, view.applied.last().getInsets(ime).bottom)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertEquals(0, view.applied.last().getInsets(ime).bottom)
    }

    @Test
    fun `a slow keyboard animation keeps control until it ends`() {
        val (container, view) = attachedWindow()
        val shown = insets(825, visible = true)
        container.dispatchApplyWindowInsets(shown)
        view.setOnApplyWindowInsetsListener { _, _ -> WindowInsets.CONSUMED }

        val hidden = insets(0, visible = false)
        view.windowInsets = hidden
        container.dispatchApplyWindowInsets(hidden)
        val ime = WindowInsets.Type.ime()
        val animation = WindowInsetsAnimation(ime, null, 1_000)
        val mainLooper = shadowOf(Looper.getMainLooper())
        repeat(5) {
            mainLooper.idleFor(Duration.ofMillis(200))
            container.dispatchWindowInsetsAnimationProgress(shown, listOf(animation))
            assertEquals(825, view.applied.last().getInsets(ime).bottom)
        }

        container.dispatchWindowInsetsAnimationEnd(animation)
        view.setOnApplyWindowInsetsListener(null)
        view.dispatchApplyWindowInsets(hidden)
        val appliedAtEnd = view.applied.size
        mainLooper.idleFor(Duration.ofSeconds(1))
        assertEquals(appliedAtEnd, view.applied.size)
        assertEquals(0, view.applied.last().getInsets(ime).bottom)
    }
}
