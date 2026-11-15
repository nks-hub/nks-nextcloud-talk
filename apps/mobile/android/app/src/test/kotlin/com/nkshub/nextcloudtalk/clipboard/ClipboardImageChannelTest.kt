package com.nkshub.nextcloudtalk.clipboard

import android.content.ClipDescription
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ClipboardImageChannelTest {
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
}
