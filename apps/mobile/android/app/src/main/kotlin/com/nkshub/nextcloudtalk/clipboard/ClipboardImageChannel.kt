package com.nkshub.nextcloudtalk.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Lets the composer suggest the image waiting on the clipboard.
 *
 * `peek` only reads the clip description. That is the part Android hands out
 * without the "pasted from your clipboard" notice, so it is safe to ask every
 * time the chat returns to the foreground. `read` takes the content, which does raise
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
        windowFocused()
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
            "writePng" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes == null || bytes.isEmpty() || bytes.size > MAXIMUM_BYTES) {
                    result.success(false)
                    return
                }
                executor.execute {
                    val written = try {
                        writePng(bytes)
                    } catch (_: IOException) {
                        false
                    } catch (_: SecurityException) {
                        false
                    } catch (_: IllegalArgumentException) {
                        false
                    }
                    mainHandler.post { result.success(written) }
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
        return readClipboardImage(clip, context.contentResolver, maximumBytes)
    }

    private fun writePng(bytes: ByteArray): Boolean {
        val directory = File(context.cacheDir, "clipboard-images")
        if (!directory.mkdirs() && !directory.isDirectory) return false
        val image = File.createTempFile("image-", ".png", directory)
        var published = false
        try {
            image.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.clipboard_images", image)
            clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, "image.png", uri))
            published = true
        } finally {
            if (!published) image.delete()
        }
        val cutoff = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(1)
        directory.listFiles()?.forEach { previous ->
            if (previous != image && previous.lastModified() < cutoff) previous.delete()
        }
        return true
    }

    fun windowFocused() {
        channel.invokeMethod("changed", null)
    }

    fun dispose() {
        clipboard.removePrimaryClipChangedListener(listener)
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/clipboard_image"
        private const val MAXIMUM_BYTES = 25 * 1024 * 1024
    }
}

class ClipboardImageFileProvider : FileProvider()

internal fun readClipboardImage(
    clip: ClipData,
    resolver: ContentResolver,
    maximumBytes: Int,
): ByteArray? {
    if (!clip.description.hasMimeType("image/*")) return null
    for (index in 0 until clip.itemCount) {
        val uri = clip.getItemAt(index).uri ?: continue
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) continue
        val bytes = try {
            openImage(resolver, uri)?.use { readCapped(it, maximumBytes) }
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            null
        }
        if (bytes != null && bytes.isNotEmpty()) return bytes
    }
    return null
}

private fun openImage(resolver: ContentResolver, uri: Uri): InputStream? {
    val type = resolver.getType(uri)
    if (type?.startsWith("image/") == true) return resolver.openInputStream(uri)

    // A provider can expose an image stream separately from the document's MIME type.
    val streamType = resolver.getStreamTypes(uri, "image/*")?.firstOrNull()
    if (streamType != null) {
        return resolver.openTypedAssetFileDescriptor(uri, streamType, null)?.createInputStream()
    }
    return if (type == null || type == "application/octet-stream") {
        resolver.openInputStream(uri)
    } else {
        null
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
