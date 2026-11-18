package com.nkshub.nextcloudtalk.clipboard

import android.content.ClipData
import android.content.ClipDescription
import android.content.pm.ProviderInfo
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import androidx.core.content.FileProvider
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
class ClipboardImageChannelTest {
    @get:Rule
    val files = TemporaryFolder()

    @Test
    fun streamWithinTheLimitIsReadWhole() {
        val bytes = ByteArray(200_000) { it.toByte() }

        assertArrayEquals(bytes, readCapped(bytes.inputStream(), 200_000))
    }

    @Test
    fun streamOverTheLimitIsRefused() {
        assertNull(readCapped(ByteArray(200_001).inputStream(), 200_000))
    }

    @Test
    fun textClipIsNotAnImage() {
        assertNull(clipId(ClipDescription("label", arrayOf("text/plain")), 1))
    }

    @Test
    fun imageClipWithoutTimestampIsNamedByTheChangeCount() {
        // A description built by hand, not one the clipboard stamped.
        val description = ClipDescription("label", arrayOf("image/png"))

        assertEquals("android-change-3", clipId(description, 3))
        assertNotEquals(clipId(description, 3), clipId(description, 4))
    }

    @Test
    fun aGenericUriCanSupplyTheImageAfterAPlainTextItem() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        val image = files.newFile().apply { writeBytes(bytes) }
        val uri = Uri.parse("content://clipboard.test/image")
        val provider = object : FileProvider() {
            override fun getType(uri: Uri) = "application/octet-stream"

            override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
                ParcelFileDescriptor.open(image, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        registerProvider(uri, provider)
        val clip = ClipData("image", arrayOf("image/png"), ClipData.Item("caption"))
        clip.addItem(ClipData.Item(uri))

        val resolver = RuntimeEnvironment.getApplication().contentResolver
        assertArrayEquals(bytes, readClipboardImage(clip, resolver, bytes.size))
        assertNull(readClipboardImage(clip, resolver, bytes.size - 1))
    }

    @Test
    fun aDocumentCanExposeItsImageAsATypedStream() {
        val bytes = byteArrayOf(5, 6, 7, 8)
        val image = files.newFile().apply { writeBytes(bytes) }
        val uri = Uri.parse("content://clipboard.test/virtual")
        val provider = object : FileProvider() {
            override fun getType(uri: Uri) = "application/x-document"

            override fun getStreamTypes(uri: Uri, mimeTypeFilter: String) =
                arrayOf("image/png")

            override fun openTypedAssetFile(
                uri: Uri,
                mimeTypeFilter: String,
                opts: Bundle?,
            ): AssetFileDescriptor = AssetFileDescriptor(
                ParcelFileDescriptor.open(image, ParcelFileDescriptor.MODE_READ_ONLY),
                0,
                image.length(),
            )
        }
        registerProvider(uri, provider)
        val clip = ClipData("image", arrayOf("image/png"), ClipData.Item(uri))

        val resolver = RuntimeEnvironment.getApplication().contentResolver
        assertArrayEquals(bytes, readClipboardImage(clip, resolver, bytes.size))
    }

    private fun registerProvider(uri: Uri, provider: FileProvider) {
        val authority = checkNotNull(uri.authority)
        provider.attachInfo(RuntimeEnvironment.getApplication(), ProviderInfo().apply {
            this.authority = authority
            grantUriPermissions = true
        })
        ShadowContentResolver.registerProviderInternal(authority, provider)
    }
}
