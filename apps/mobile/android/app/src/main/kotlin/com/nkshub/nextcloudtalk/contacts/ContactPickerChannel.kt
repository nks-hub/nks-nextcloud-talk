package com.nkshub.nextcloudtalk.contacts

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.ContactsContract.CommonDataKinds.Phone
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ContactPickerChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var pendingResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "pickContact") {
            result.notImplemented()
            return
        }
        if (pendingResult != null) {
            result.error("picker_in_progress", "A contact picker is already open.", null)
            return
        }
        pendingResult = result
        try {
            val intent = Intent(Intent.ACTION_PICK, Phone.CONTENT_URI).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            pendingResult = null
            result.error("picker_unavailable", "No contact picker is available.", null)
        } catch (_: SecurityException) {
            pendingResult = null
            result.error("permission_denied", "Contact access was denied.", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            result.error("invalid_contact", "The contact picker returned no contact.", null)
            return true
        }
        try {
            activity.contentResolver.query(
                uri,
                arrayOf(Phone.DISPLAY_NAME, Phone.NUMBER),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) {
                    result.error("invalid_contact", "The selected contact is unavailable.", null)
                    return true
                }
                val name = cursor.getString(cursor.getColumnIndexOrThrow(Phone.DISPLAY_NAME))
                    ?.trim()
                    .orEmpty()
                val number = cursor.getString(cursor.getColumnIndexOrThrow(Phone.NUMBER))
                    ?.trim()
                    .orEmpty()
                if (name.isEmpty() || number.isEmpty()) {
                    result.error("invalid_contact", "The selected contact has no phone number.", null)
                    return true
                }
                result.success(
                    mapOf(
                        "displayName" to name,
                        "vcard" to contactVCard(name, number),
                    ),
                )
                return true
            }
            result.error("invalid_contact", "The selected contact is unavailable.", null)
        } catch (_: SecurityException) {
            result.error("permission_denied", "Contact access was denied.", null)
        } catch (_: IllegalArgumentException) {
            result.error("invalid_contact", "The selected contact is invalid.", null)
        }
        return true
    }

    fun dispose() {
        pendingResult?.error("picker_unavailable", "The contact picker was closed.", null)
        pendingResult = null
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/contact_picker"
        internal const val REQUEST_CODE = 4118
    }
}

internal fun contactVCard(name: String, number: String): ByteArray {
    fun escape(value: String): String = value
        .replace("\\", "\\\\")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
        .replace("\r", "\\n")
        .replace(";", "\\;")
        .replace(",", "\\,")

    val bytes = buildString {
        append("BEGIN:VCARD\r\n")
        append("VERSION:3.0\r\n")
        append("FN:").append(escape(name)).append("\r\n")
        append("TEL:").append(escape(number)).append("\r\n")
        append("END:VCARD\r\n")
    }.toByteArray(Charsets.UTF_8)
    require(bytes.size <= MAXIMUM_VCARD_BYTES) { "The selected contact is too large." }
    return bytes
}

internal const val MAXIMUM_VCARD_BYTES = 2 * 1024 * 1024
