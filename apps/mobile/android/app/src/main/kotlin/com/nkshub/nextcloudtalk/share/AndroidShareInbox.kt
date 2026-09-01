package com.nkshub.nextcloudtalk.share

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

internal data class AndroidIncomingShare(
    val id: String,
    val text: String?,
    val filePath: String?,
    val mimeType: String?,
    val displayName: String?,
    val byteLength: Long?,
    val sha256: String?,
    val sourceFingerprint: String,
    val createdAtMillis: Long,
) {
    fun asMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "text" to text,
        "filePath" to filePath,
        "mimeType" to mimeType,
        "displayName" to displayName,
        "byteLength" to byteLength,
        "sha256" to sha256,
    )
}

internal sealed class AndroidShareCaptureResult {
    data class Accepted(val share: AndroidIncomingShare) : AndroidShareCaptureResult()
    data object Ignored : AndroidShareCaptureResult()
    data class Rejected(val reason: String) : AndroidShareCaptureResult()
}

internal class AndroidShareInbox(
    context: Context,
    private val maximumBytes: Long = MAXIMUM_FILE_BYTES,
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val appContext = context.applicationContext
    private val root = File(appContext.noBackupFilesDir, DIRECTORY_NAME)

    init {
        require(maximumBytes > 0 && maximumBytes <= MAXIMUM_FILE_BYTES)
        root.mkdirs()
    }

    fun capture(
        intent: Intent?,
        deduplicatePending: Boolean = true,
    ): AndroidShareCaptureResult {
        val source = intent ?: return AndroidShareCaptureResult.Ignored
        if (source.action != Intent.ACTION_SEND) {
            return AndroidShareCaptureResult.Ignored
        }
        val existingId = source.getStringExtra(EXTRA_DELIVERY_ID)
        if (existingId != null) {
            val existing = read(existingId)
            return if (existing == null) {
                AndroidShareCaptureResult.Rejected("share-unavailable")
            } else {
                AndroidShareCaptureResult.Accepted(existing)
            }
        }
        val text = source.getCharSequenceExtra(Intent.EXTRA_TEXT)
            ?.toString()
            ?.trim()
            ?.takeIf(String::isNotEmpty)
        if (text != null && text.length > MAXIMUM_TEXT_LENGTH) {
            return AndroidShareCaptureResult.Rejected("share-text-too-large")
        }
        val uri = source.shareUri()
        if (uri != null && text != null && text.length > MAXIMUM_FILE_CAPTION_LENGTH) {
            return AndroidShareCaptureResult.Rejected("share-caption-too-large")
        }
        if (uri == null && text == null) {
            return AndroidShareCaptureResult.Rejected("share-empty")
        }
        if (uri != null && uri.scheme != "content") {
            return AndroidShareCaptureResult.Rejected("share-uri-unsupported")
        }
        val sourceFingerprint = sourceFingerprint(source.type, text, uri)
        val pending = pending()
        if (deduplicatePending) {
            pending.firstOrNull { it.sourceFingerprint == sourceFingerprint }?.let { existing ->
                source.putExtra(EXTRA_DELIVERY_ID, existing.id)
                return AndroidShareCaptureResult.Accepted(existing)
            }
        }
        if (pending.size >= MAXIMUM_PENDING_SHARES) {
            return AndroidShareCaptureResult.Rejected("share-inbox-full")
        }
        val id = idFactory()
        if (!ID_PATTERN.matches(id)) {
            return AndroidShareCaptureResult.Rejected("share-id-invalid")
        }
        source.putExtra(EXTRA_DELIVERY_ID, id)
        return try {
            val share = if (uri == null) {
                AndroidIncomingShare(
                    id = id,
                    text = text,
                    filePath = null,
                    mimeType = null,
                    displayName = null,
                    byteLength = null,
                    sha256 = null,
                    sourceFingerprint = sourceFingerprint,
                    createdAtMillis = clock(),
                )
            } else {
                copyUri(id, uri, source.type, text, sourceFingerprint)
            }
            writeMetadata(share)
            AndroidShareCaptureResult.Accepted(share)
        } catch (_: AndroidShareRejectedException) {
            removeFiles(id)
            AndroidShareCaptureResult.Rejected("share-file-invalid")
        } catch (_: SecurityException) {
            removeFiles(id)
            AndroidShareCaptureResult.Rejected("share-permission-denied")
        } catch (_: java.io.IOException) {
            removeFiles(id)
            AndroidShareCaptureResult.Rejected("share-copy-failed")
        }
    }

    fun pending(): List<AndroidIncomingShare> {
        val files = root.listFiles { file -> file.name.endsWith(METADATA_SUFFIX) }
            ?: return emptyList()
        return files.mapNotNull { file -> readMetadata(file) }
            .sortedBy(AndroidIncomingShare::createdAtMillis)
            .take(MAXIMUM_PENDING_SHARES)
    }

    fun complete(id: String): Boolean {
        if (!ID_PATTERN.matches(id)) {
            return false
        }
        removeFiles(id)
        return true
    }

    private fun read(id: String): AndroidIncomingShare? {
        if (!ID_PATTERN.matches(id)) {
            return null
        }
        return readMetadata(metadataFile(id))
    }

    private fun copyUri(
        id: String,
        uri: Uri,
        declaredMimeType: String?,
        text: String?,
        sourceFingerprint: String,
    ): AndroidIncomingShare {
        val resolver = appContext.contentResolver
        val lengthHint = resolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
        if (lengthHint != null && lengthHint > maximumBytes) {
            throw AndroidShareRejectedException()
        }
        val temporary = temporaryFile(id)
        val digest = MessageDigest.getInstance("SHA-256")
        var byteLength = 0L
        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(temporary).use { output ->
                val buffer = ByteArray(COPY_BUFFER_BYTES)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    byteLength += count
                    if (byteLength > maximumBytes) {
                        throw AndroidShareRejectedException()
                    }
                    digest.update(buffer, 0, count)
                    output.write(buffer, 0, count)
                }
                output.fd.sync()
            }
        } ?: throw AndroidShareRejectedException()
        if (byteLength == 0L) {
            throw AndroidShareRejectedException()
        }
        val payload = payloadFile(id)
        if (!temporary.renameTo(payload)) {
            throw java.io.IOException("Unable to commit shared file")
        }
        val mimeType = normalizeMimeType(resolver.getType(uri) ?: declaredMimeType)
        return AndroidIncomingShare(
            id = id,
            text = text,
            filePath = payload.canonicalPath,
            mimeType = mimeType,
            displayName = displayName(uri),
            byteLength = byteLength,
            sha256 = digest.digest().joinToString("") { "%02x".format(it) },
            sourceFingerprint = sourceFingerprint,
            createdAtMillis = clock(),
        )
    }

    private fun displayName(uri: Uri): String {
        val raw = appContext.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
        val normalized = raw
            ?.replace(Regex("[\\p{Cntrl}/\\\\]"), "_")
            ?.trim()
            ?.take(MAXIMUM_DISPLAY_NAME_LENGTH)
            ?.takeIf(String::isNotEmpty)
        return normalized ?: DEFAULT_DISPLAY_NAME
    }

    private fun writeMetadata(share: AndroidIncomingShare) {
        val temporary = metadataTemporaryFile(share.id)
        val objectValue = JSONObject()
            .put("id", share.id)
            .put("sourceFingerprint", share.sourceFingerprint)
            .put("createdAtMillis", share.createdAtMillis)
        share.text?.let { objectValue.put("text", it) }
        share.filePath?.let { objectValue.put("filePath", it) }
        share.mimeType?.let { objectValue.put("mimeType", it) }
        share.displayName?.let { objectValue.put("displayName", it) }
        share.byteLength?.let { objectValue.put("byteLength", it) }
        share.sha256?.let { objectValue.put("sha256", it) }
        FileOutputStream(temporary).use { output ->
            output.write(objectValue.toString().toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        if (!temporary.renameTo(metadataFile(share.id))) {
            throw java.io.IOException("Unable to commit share metadata")
        }
    }

    private fun readMetadata(file: File): AndroidIncomingShare? = try {
        val value = JSONObject(file.readText(Charsets.UTF_8))
        val id = value.getString("id")
        if (!ID_PATTERN.matches(id) || file != metadataFile(id)) return null
        val sourceFingerprint = value.getString("sourceFingerprint")
        if (!SHA256_PATTERN.matches(sourceFingerprint)) return null
        val filePath = value.optString("filePath").takeIf(String::isNotEmpty)
        if (filePath != null && payloadFile(id).canonicalPath != filePath) return null
        val payloadLength = filePath?.let { payloadFile(id).takeIf(File::isFile)?.length() }
        val recordedLength = value.optLong("byteLength", -1).takeIf { it >= 0 }
        if (filePath != null && payloadLength != recordedLength) return null
        AndroidIncomingShare(
            id = id,
            text = value.optString("text").takeIf(String::isNotEmpty),
            filePath = filePath,
            mimeType = value.optString("mimeType").takeIf(String::isNotEmpty),
            displayName = value.optString("displayName").takeIf(String::isNotEmpty),
            byteLength = recordedLength,
            sha256 = value.optString("sha256").takeIf(String::isNotEmpty),
            sourceFingerprint = sourceFingerprint,
            createdAtMillis = value.getLong("createdAtMillis"),
        )
    } catch (_: org.json.JSONException) {
        null
    } catch (_: java.io.IOException) {
        null
    } catch (_: SecurityException) {
        null
    }

    private fun removeFiles(id: String) {
        temporaryFile(id).delete()
        payloadFile(id).delete()
        metadataTemporaryFile(id).delete()
        metadataFile(id).delete()
    }

    private fun Intent.shareUri(): Uri? = if (android.os.Build.VERSION.SDK_INT >= 33) {
        getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(Intent.EXTRA_STREAM)
    }

    private fun normalizeMimeType(value: String?): String {
        val normalized = value?.trim()?.lowercase()
        return if (normalized != null && MIME_PATTERN.matches(normalized)) {
            normalized
        } else {
            DEFAULT_MIME_TYPE
        }
    }

    private fun sourceFingerprint(mimeType: String?, text: String?, uri: Uri?): String {
        val value = listOf(mimeType.orEmpty(), text.orEmpty(), uri?.toString().orEmpty())
            .joinToString("\u0000")
        return MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun payloadFile(id: String) = File(root, "$id.payload")
    private fun temporaryFile(id: String) = File(root, "$id.payload.tmp")
    private fun metadataFile(id: String) = File(root, "$id$METADATA_SUFFIX")
    private fun metadataTemporaryFile(id: String) = File(root, "$id$METADATA_SUFFIX.tmp")

    companion object {
        private const val DIRECTORY_NAME = "share-inbox-v1"
        private const val METADATA_SUFFIX = ".json"
        private const val DEFAULT_DISPLAY_NAME = "shared-file"
        private const val DEFAULT_MIME_TYPE = "application/octet-stream"
        private const val COPY_BUFFER_BYTES = 64 * 1024
        private const val MAXIMUM_DISPLAY_NAME_LENGTH = 255
        private const val MAXIMUM_TEXT_LENGTH = 32768
        private const val MAXIMUM_FILE_CAPTION_LENGTH = 4000
        private const val MAXIMUM_PENDING_SHARES = 16
        private const val MAXIMUM_FILE_BYTES = 512L * 1024 * 1024
        private const val EXTRA_DELIVERY_ID = "com.nkshub.nextcloudtalk.share.DELIVERY_ID"
        private val ID_PATTERN = Regex(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" +
                "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        )
        private val MIME_PATTERN = Regex("^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$")
        private val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
    }
}

private class AndroidShareRejectedException : Exception()
