package com.nkshub.nextcloudtalk.emoji

import android.graphics.Paint
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Tells the emoji picker which glyphs the system font can draw.
 *
 * The Unicode data behind the picker is newer than the emoji font of older
 * Android releases, which draw a box for every glyph they lack.
 */
class EmojiGlyphChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val paint = Paint()

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
        result.success(glyphs.map { paint.hasGlyph(it as String) })
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/emoji_glyphs"
    }
}
