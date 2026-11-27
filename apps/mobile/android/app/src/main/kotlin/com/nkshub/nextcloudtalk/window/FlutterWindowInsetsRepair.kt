package com.nkshub.nextcloudtalk.window

import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterView

/**
 * Flutter's ImeSyncDeferringInsetsCallback consumes insets until the IME
 * animation ends. If the end callback goes missing, the viewport keeps the
 * keyboard inset even after the window reports it hidden.
 */
object FlutterWindowInsetsRepair {
    private const val IME_IDLE_DELAY_MS = 400L

    fun watchKeyboardDismissals(
        container: View,
        target: () -> View? = { flutterViewIn(container) },
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val watcher = ImeDismissalWatcher(container, target)
            container.setOnApplyWindowInsetsListener(watcher)
            container.setWindowInsetsAnimationCallback(watcher)
        }
    }

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

    @RequiresApi(Build.VERSION_CODES.R)
    private class ImeDismissalWatcher(
        private val container: View,
        target: () -> View?,
    ) : WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE), View.OnApplyWindowInsetsListener {
        private val ime = WindowInsets.Type.ime()
        private var wasVisible = false
        private var repairPending = false
        private val repairDismissal = Runnable {
            repairPending = false
            if (container.isAttachedToWindow) {
                target()?.let(::repair)
            }
        }

        override fun onApplyWindowInsets(view: View, insets: WindowInsets): WindowInsets {
            val visible = insets.isVisible(ime)
            if (visible) {
                cancelRepair()
            } else if (wasVisible) {
                // Android dispatches the final insets before starting the animation.
                repairPending = true
                deferRepair()
            }
            wasVisible = visible
            return view.onApplyWindowInsets(insets)
        }

        override fun onProgress(
            insets: WindowInsets,
            animations: MutableList<WindowInsetsAnimation>,
        ): WindowInsets {
            if (repairPending && animations.any { it.typeMask and ime != 0 }) {
                deferRepair()
            }
            return insets
        }

        override fun onEnd(animation: WindowInsetsAnimation) {
            if (animation.typeMask and ime != 0) {
                cancelRepair()
            }
        }

        private fun deferRepair() {
            container.removeCallbacks(repairDismissal)
            container.postDelayed(repairDismissal, IME_IDLE_DELAY_MS)
        }

        private fun cancelRepair() {
            if (repairPending) {
                container.removeCallbacks(repairDismissal)
                repairPending = false
            }
        }
    }
}
