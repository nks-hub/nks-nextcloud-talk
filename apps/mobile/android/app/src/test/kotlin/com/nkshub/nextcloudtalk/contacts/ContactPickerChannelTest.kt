package com.nkshub.nextcloudtalk.contacts

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
class ContactPickerChannelTest {
    @Test
    fun selectedPhoneBecomesOneEscapedVCard() {
        val card = contactVCard("Alice; Example", "+420 123,456").toString(Charsets.UTF_8)

        assertEquals(
            "BEGIN:VCARD\r\n" +
                "VERSION:3.0\r\n" +
                "FN:Alice\\; Example\r\n" +
                "TEL:+420 123\\,456\r\n" +
                "END:VCARD\r\n",
            card,
        )
    }

    @Test
    fun cancelledPickerCompletesWithNull() {
        val fixture = channelFixture()

        fixture.channel.onMethodCall(MethodCall("pickContact", null), fixture.result)
        fixture.channel.onActivityResult(
            ContactPickerChannel.REQUEST_CODE,
            Activity.RESULT_CANCELED,
            null,
        )

        assertEquals(1, fixture.result.successCalls)
        assertNull(fixture.result.value)
        assertNull(fixture.result.errorCode)
    }

    @Test
    fun securityExceptionBecomesPermissionDenied() {
        val fixture = channelFixture()
        ShadowContentResolver.registerProviderInternal(
            "com.android.contacts",
            DenyingContactsProvider(),
        )

        fixture.channel.onMethodCall(MethodCall("pickContact", null), fixture.result)
        fixture.channel.onActivityResult(
            ContactPickerChannel.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://com.android.contacts/data/phones/1")),
        )

        assertEquals("permission_denied", fixture.result.errorCode)
        assertEquals(0, fixture.result.successCalls)
    }

    @Test
    fun disposingOpenPickerCompletesItsPendingResult() {
        val fixture = channelFixture()

        fixture.channel.onMethodCall(MethodCall("pickContact", null), fixture.result)
        fixture.channel.dispose()

        assertEquals("picker_unavailable", fixture.result.errorCode)
        assertEquals(0, fixture.result.successCalls)
    }

    private fun channelFixture(): Fixture {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val result = RecordingResult()
        return Fixture(
            channel = ContactPickerChannel(activity, NoopMessenger()),
            result = result,
        )
    }

    private data class Fixture(
        val channel: ContactPickerChannel,
        val result: RecordingResult,
    )
}

private class NoopMessenger : BinaryMessenger {
    override fun send(channel: String, message: ByteBuffer?) = Unit

    override fun send(
        channel: String,
        message: ByteBuffer?,
        callback: BinaryMessenger.BinaryReply?,
    ) = Unit

    override fun setMessageHandler(
        channel: String,
        handler: BinaryMessenger.BinaryMessageHandler?,
    ) = Unit
}

private class RecordingResult : MethodChannel.Result {
    var successCalls = 0
    var value: Any? = null
    var errorCode: String? = null

    override fun success(result: Any?) {
        successCalls++
        value = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        this.errorCode = errorCode
    }

    override fun notImplemented() = Unit
}

private class DenyingContactsProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor = throw SecurityException("denied")

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
