package com.nkshub.nextcloudtalk.share

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
class AndroidShareInboxTest {
    private lateinit var context: Context
    private lateinit var provider: ShareTestProvider
    private var nextId = 0

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        File(context.noBackupFilesDir, "share-inbox-v1").deleteRecursively()
        provider = ShareTestProvider()
        provider.attachInfo(
            context,
            ProviderInfo().apply { authority = AUTHORITY },
        )
        ShadowContentResolver.registerProviderInternal(AUTHORITY, provider)
    }

    @After
    fun tearDown() {
        File(context.noBackupFilesDir, "share-inbox-v1").deleteRecursively()
    }

    @Test
    fun textShareIsTrimmedAndPersistsAcrossInboxInstances() {
        val inbox = inbox()
        val result = inbox.capture(
            Intent(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, "  hello  "),
        ) as AndroidShareCaptureResult.Accepted

        assertEquals("hello", result.share.text)
        assertNull(result.share.filePath)
        assertEquals(result.share, inbox().pending().single())
    }

    @Test
    fun sharedContentIsCopiedBeforeTheUriGrantDisappears() {
        val bytes = "durable bytes".toByteArray()
        val uri = provider.put("photo.jpg", "image/jpeg", bytes)
        val inbox = inbox()

        val result = inbox.capture(
            Intent(Intent.ACTION_SEND)
                .setType("image/jpeg")
                .putExtra(Intent.EXTRA_STREAM, uri),
        ) as AndroidShareCaptureResult.Accepted
        provider.remove(uri)

        assertArrayEquals(bytes, File(result.share.filePath!!).readBytes())
        assertEquals("photo.jpg", result.share.displayName)
        assertEquals("image/jpeg", result.share.mimeType)
        assertEquals(bytes.size.toLong(), result.share.byteLength)
        assertEquals(64, result.share.sha256?.length)
    }

    @Test
    fun repeatedDeliveryOfTheSameIntentCreatesOneRecord() {
        val intent = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, "once")
        val inbox = inbox()

        val first = inbox.capture(intent) as AndroidShareCaptureResult.Accepted
        val second = inbox.capture(intent) as AndroidShareCaptureResult.Accepted

        assertEquals(first.share.id, second.share.id)
        assertEquals(1, inbox.pending().size)
    }

    @Test
    fun restoredIntentWithoutThePrivateIdReusesThePendingCopy() {
        val uri = provider.put("restored.jpg", "image/jpeg", byteArrayOf(9, 8, 7))
        val inbox = inbox()
        val first = inbox.capture(
            Intent(Intent.ACTION_SEND)
                .setType("image/jpeg")
                .putExtra(Intent.EXTRA_STREAM, uri),
        ) as AndroidShareCaptureResult.Accepted

        val restored = inbox().capture(
            Intent(Intent.ACTION_SEND)
                .setType("image/jpeg")
                .putExtra(Intent.EXTRA_STREAM, uri),
        ) as AndroidShareCaptureResult.Accepted

        assertEquals(first.share.id, restored.share.id)
        assertEquals(1, inbox.pending().size)
    }

    @Test
    fun aNewWarmIntentMayShareTheSameTextAgain() {
        val inbox = inbox()
        val first = inbox.capture(
            Intent(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, "repeat me"),
        ) as AndroidShareCaptureResult.Accepted

        val second = inbox.capture(
            Intent(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, "repeat me"),
            deduplicatePending = false,
        ) as AndroidShareCaptureResult.Accepted

        assertFalse(first.share.id == second.share.id)
        assertEquals(2, inbox.pending().size)
    }

    @Test
    fun oversizedContentIsRejectedWithoutLeavingAFile() {
        val uri = provider.put("large.bin", "application/octet-stream", byteArrayOf(1, 2, 3, 4, 5))
        val inbox = inbox(maximumBytes = 4)

        val result = inbox.capture(
            Intent(Intent.ACTION_SEND)
                .setType("application/octet-stream")
                .putExtra(Intent.EXTRA_STREAM, uri),
        )

        assertTrue(result is AndroidShareCaptureResult.Rejected)
        assertTrue(inbox.pending().isEmpty())
        assertTrue(File(context.noBackupFilesDir, "share-inbox-v1").listFiles().isNullOrEmpty())
    }

    @Test
    fun fileSchemeIsRejectedAtTheTrustBoundary() {
        val result = inbox().capture(
            Intent(Intent.ACTION_SEND)
                .setType("image/jpeg")
                .putExtra(Intent.EXTRA_STREAM, Uri.parse("file:///sdcard/private.jpg")),
        )

        assertEquals(
            "share-uri-unsupported",
            (result as AndroidShareCaptureResult.Rejected).reason,
        )
    }

    @Test
    fun completingShareDeletesMetadataAndPayload() {
        val uri = provider.put("document.pdf", "application/pdf", byteArrayOf(4, 2))
        val inbox = inbox()
        val share = (inbox.capture(
            Intent(Intent.ACTION_SEND)
                .setType("application/pdf")
                .putExtra(Intent.EXTRA_STREAM, uri),
        ) as AndroidShareCaptureResult.Accepted).share

        assertTrue(inbox.complete(share.id))
        assertFalse(File(share.filePath!!).exists())
        assertTrue(inbox.pending().isEmpty())
    }

    private fun inbox(maximumBytes: Long = 512L * 1024 * 1024) = AndroidShareInbox(
        context = context,
        maximumBytes = maximumBytes,
        idFactory = { "00000000-0000-0000-0000-${(++nextId).toString().padStart(12, '0')}" },
        clock = { nextId.toLong() },
    )

    companion object {
        private const val AUTHORITY = "com.nkshub.nextcloudtalk.share.test"
    }
}

@RunWith(RobolectricTestRunner::class)
class AndroidShareDeliveryTest {
    @Test
    fun coldShareIsReturnedOnceAndLaterSharesUseWarmCallback() {
        val callbacks = mutableListOf<Map<String, Any?>>()
        val delivery = AndroidShareDelivery(callbacks::add)
        val cold = share("cold")
        val warm = share("warm")

        delivery.opened(cold)
        assertEquals(cold.id, delivery.markReadyAndTakeLaunch()?.get("id"))
        assertNull(delivery.markReadyAndTakeLaunch())
        delivery.opened(warm)

        assertEquals(listOf(warm.id), callbacks.map { it["id"] })
    }

    @Test
    fun duplicateIdIsNeverDeliveredTwice() {
        val callbacks = mutableListOf<Map<String, Any?>>()
        val delivery = AndroidShareDelivery(callbacks::add)
        val share = share("same")
        delivery.markReadyAndTakeLaunch()

        delivery.opened(share)
        delivery.opened(share)

        assertEquals(1, callbacks.size)
    }

    private fun share(id: String) = AndroidIncomingShare(
        id = id,
        text = id,
        filePath = null,
        mimeType = null,
        displayName = null,
        byteLength = null,
        sha256 = null,
        sourceFingerprint = id,
        createdAtMillis = 1,
    )
}

private class ShareTestProvider : ContentProvider() {
    private val files = mutableMapOf<Uri, Entry>()

    fun put(name: String, mimeType: String, bytes: ByteArray): Uri {
        val uri = Uri.parse("content://com.nkshub.nextcloudtalk.share.test/$name")
        files[uri] = Entry(name, mimeType, bytes)
        return uri
    }

    fun remove(uri: Uri) {
        files.remove(uri)
    }

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String? = files[uri]?.mimeType

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val entry = files[uri] ?: throw FileNotFoundException(uri.toString())
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply {
            addRow(arrayOf(entry.name))
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val entry = files[uri] ?: throw FileNotFoundException(uri.toString())
        val file = File.createTempFile("shared", null, context!!.cacheDir)
        file.writeBytes(entry.bytes)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    private data class Entry(val name: String, val mimeType: String, val bytes: ByteArray)
}
