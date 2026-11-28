package io.flutter.plugin.editing

import android.app.Activity
import android.graphics.Insets
import android.os.Looper
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.widget.FrameLayout
import com.nkshub.nextcloudtalk.window.FlutterWindowInsetsRepair
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class FlutterImeResumeTest {
    @Test
    fun `a late animation end after focus returns cannot reinstate the old keyboard height`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val ime = WindowInsets.Type.ime()
        val shown = WindowInsets.Builder()
            .setInsets(ime, Insets.of(0, 0, 0, 825)).setVisible(ime, true).build()
        val hidden = WindowInsets.Builder(shown)
            .setInsets(ime, Insets.NONE).setVisible(ime, false).build()
        var current = shown
        var insetSeenByFlutter = -1
        val target = object : View(activity) {
            override fun getRootWindowInsets() = current

            override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
                insetSeenByFlutter = insets.getInsets(ime).bottom
                return super.onApplyWindowInsets(insets)
            }
        }
        val container = FrameLayout(activity)
        container.addView(target)
        FlutterWindowInsetsRepair.watchKeyboardDismissals(container) { target }
        activity.setContentView(container)
        ImeSyncDeferringInsetsCallback(target).install()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        container.dispatchApplyWindowInsets(shown)
        assertEquals(825, insetSeenByFlutter)

        // Flutter saves the first inset after prepare. The IME is then hidden
        // during the activity switch before that animation delivers its end.
        val animation = WindowInsetsAnimation(ime, null, 250)
        container.dispatchWindowInsetsAnimationPrepare(animation)
        container.dispatchApplyWindowInsets(shown)
        current = hidden
        container.dispatchApplyWindowInsets(hidden)
        FlutterWindowInsetsRepair.repair(target)
        assertEquals(0, insetSeenByFlutter)
        // Let the missing-end timeout expire before the delayed end arrives.
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        container.dispatchWindowInsetsAnimationEnd(animation)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))

        assertEquals(0, insetSeenByFlutter)
    }
}
