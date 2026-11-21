package com.nkshub.nextcloudtalk.push

import android.app.NotificationManager
import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29])
class AndroidPushDisplayOutcomeTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val manager = context.getSystemService(NotificationManager::class.java)

    @After
    fun resetOpenRoom() {
        AndroidSystemNotifications.setOpenRoom(null, null)
        manager.cancelAll()
    }

    @Test
    fun reportsWhyAMessageWasNotPosted() {
        val otherApp = message(app = "files")
        val openChat = message(app = "spreed")
        AndroidSystemNotifications.setOpenRoom("account-a", "room-a")

        assertEquals(
            PushDisplayOutcome.FILTERED_OTHER_APP,
            AndroidSystemNotifications.apply(context, "account-a", otherApp),
        )
        assertEquals(
            PushDisplayOutcome.SUPPRESSED_OPEN_ROOM,
            AndroidSystemNotifications.apply(context, "account-a", openChat),
        )
        assertEquals(0, shadowOf(manager).allNotifications.size)
    }

    @Test
    fun reportsMissingFieldsWithoutOpeningTheEncryptedStore() {
        val missingSubject = message(app = "spreed", subject = null)

        assertEquals(
            PushDisplayOutcome.MISSING_FIELDS,
            AndroidSystemNotifications.apply(context, "account-a", missingSubject),
        )
        assertEquals(0, shadowOf(manager).allNotifications.size)
    }

    private fun message(
        app: String,
        subject: String? = "Message",
        notificationId: Long = 901,
    ) = AndroidWebPushPayload.Message(
        notificationId = notificationId,
        app = app,
        subject = subject,
        type = "chat",
        objectId = "room-a",
    )
}
