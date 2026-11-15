package com.nkshub.nextcloudtalk.emoji

import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Tells the emoji picker which glyphs the system font can draw.
 *
 * The Unicode data behind the picker is newer than the emoji font of older
 * Android releases, which draw a box for every glyph they lack.
 *
 * Probing the whole catalog takes long enough to stall frames, so it runs on a
 * single background thread (which also keeps the shared [Paint] single-threaded)
 * and the reply goes back on the main thread.
 */
class EmojiGlyphChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val paint = Paint()
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "hasGlyphs") {
            result.notImplemented()
            return
        }
        val glyphs = call.arguments as? List<*>
        if (glyphs == null || glyphs.any { it !is String }) {
            result.error("invalid_arguments", "Expected a list of strings.", null)
            return
        }
        executor.execute {
            val answer = glyphs.map { paint.hasGlyph(it as String) }
            mainHandler.post { result.success(answer) }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/emoji_glyphs"
    }
}
