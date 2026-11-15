package com.nkshub.nextcloudtalk.clipboard

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.Executors

/**
 * Lets the composer suggest the image waiting on the clipboard.
 *
 * `peek` only reads the clip description. That is the part Android hands out
 * without the "pasted from your clipboard" notice, so it is safe to ask every
 * time the message field gets focus. `read` takes the content, which does raise
 * the notice; Dart calls it once per new clip, when the suggestion is about to
 * be shown.
 */
class ClipboardImageChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // Counts the clips seen while the app runs, for releases whose description
    // carries no timestamp.
    private var changes = 0L
    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        changes++
        channel.invokeMethod("changed", null)
    }

    init {
        channel.setMethodCallHandler(this)
        clipboard.addPrimaryClipChangedListener(listener)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "peek" -> result.success(peek())
            "read" -> {
                val maximumBytes = (call.arguments as? Number)?.toInt()
                if (maximumBytes == null || maximumBytes <= 0) {
                    result.error("invalid_arguments", "Expected a byte limit.", null)
                    return
                }
                executor.execute {
                    val bytes = try {
                        read(maximumBytes)
                    } catch (_: Exception) {
                        // A revoked URI grant or a vanished provider: no image.
                        null
                    }
                    mainHandler.post { result.success(bytes) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun peek(): String? {
        val description = try {
            clipboard.primaryClipDescription
        } catch (_: SecurityException) {
            null
        } ?: return null
        return clipId(description, changes)
    }

    private fun read(maximumBytes: Int): ByteArray? {
        val clip = clipboard.primaryClip ?: return null
        val uri = (if (clip.itemCount > 0) clip.getItemAt(0).uri else null) ?: return null
        val resolver = context.contentResolver
        if (resolver.getType(uri)?.startsWith("image/") != true) {
            return null
        }
        return resolver.openInputStream(uri)?.use { readCapped(it, maximumBytes) }
    }

    fun dispose() {
        clipboard.removePrimaryClipChangedListener(listener)
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/clipboard_image"
    }
}

/**
 * Names an image clip so that a new copy gets a new name; null for a clip
 * that is not an image.
 */
internal fun clipId(description: ClipDescription, changes: Long): String? {
    if (!description.hasMimeType("image/*")) {
        return null
    }
    val timestamp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) description.timestamp else 0L
    return if (timestamp > 0L) "android-$timestamp" else "android-change-$changes"
}

/** The whole stream, or null as soon as it turns out longer than [maximumBytes]. */
internal fun readCapped(input: InputStream, maximumBytes: Int): ByteArray? {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (true) {
        val count = input.read(buffer)
        if (count < 0) {
            return out.toByteArray()
        }
        if (out.size() + count > maximumBytes) {
            return null
        }
        out.write(buffer, 0, count)
    }
}
