package com.nkshub.nextcloudtalk.window

import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import io.flutter.embedding.android.FlutterView

/**
 * Puts the window's real insets back into Flutter's hands after the app returns
 * to the foreground.
 *
 * Flutter defers insets while the keyboard animates, so the Dart side can move
 * with the keyboard instead of jumping after it. `ImeSyncDeferringInsetsCallback`
 * does that by consuming every insets update between the animation's start and
 * its end. Samsung's keyboard starts that animation and then never ends it when
 * the activity is paused in the middle of it - which is what picking a picture
 * with the keyboard open does - and from then on nothing the window reports ever
 * reaches the view again. The whole app keeps the viewport it had while the
 * keyboard was up: roughly half the screen of content and dead space below it,
 * on every screen, until some later keyboard animation happens to complete.
 *
 * The repair is to hand the view the insets the window really has. Dispatching
 * them the ordinary way is both the probe and the harmless case: a callback that
 * is not stuck applies them and there is nothing left to do, while one that is
 * stuck answers [WindowInsets.CONSUMED], proving the update never arrived, and
 * the insets are then applied to the view directly.
 */
object FlutterWindowInsetsRepair {
    /**
     * Applies [insets] to [view], going around the deferring callback if that is
     * the only way they will land. Returns whether it had to.
     *
     * A keyboard that is genuinely on screen owns the inset it is claiming, so
     * nothing is repaired while one is visible.
     */
    fun apply(view: View, insets: WindowInsets): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return false
        }
        if (insets.isVisible(WindowInsets.Type.ime())) {
            return false
        }
        if (view.dispatchApplyWindowInsets(insets) != WindowInsets.CONSUMED) {
            return false
        }
        view.onApplyWindowInsets(insets)
        return true
    }

    /** [apply] against whatever the window is currently reporting. */
    fun repair(view: View): Boolean {
        val insets = view.rootWindowInsets ?: return false
        return apply(view, insets)
    }

    /** The engine's view, which is the one the deferring callback is installed on. */
    fun flutterViewIn(view: View): FlutterView? {
        if (view is FlutterView) {
            return view
        }
        if (view !is ViewGroup) {
            return null
        }
        for (index in 0 until view.childCount) {
            flutterViewIn(view.getChildAt(index))?.let { return it }
        }
        return null
    }
}
