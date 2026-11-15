package com.nkshub.nextcloudtalk.attachments

import android.app.NotificationManager
import android.content.Intent
import com.nkshub.nextcloudtalk.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class AttachmentTransferServiceTest {
    private val context = RuntimeEnvironment.getApplication()
    private val manager = context.getSystemService(NotificationManager::class.java)

    private fun shownTitle(): String =
        shadowOf(shadowOf(manager).allNotifications.single()).contentTitle.toString()

    @Test
    fun aServiceHeldForAWaitingMessageSaysSoAndNotThatItIsSending() {
        val controller = Robolectric.buildService(
            AttachmentTransferService::class.java,
            Intent().putExtra(AttachmentTransferService.EXTRA_WAITING, true),
        ).create().startCommand(0, 1)

        assertEquals(context.getString(R.string.unsent_message_title), shownTitle())
        assertSame(controller.get(), AttachmentTransferService.running)

        controller.destroy()
        assertNull(AttachmentTransferService.running)
    }

    @Test
    fun theRunningServiceChangesItsTextWithoutBeingStartedAgain() {
        val controller = Robolectric.buildService(
            AttachmentTransferService::class.java,
            Intent(),
        ).create().startCommand(0, 1)
        assertEquals(context.getString(R.string.attachment_upload_title), shownTitle())

        controller.get().show(true)
        assertEquals(context.getString(R.string.unsent_message_title), shownTitle())

        controller.get().show(false)
        assertEquals(context.getString(R.string.attachment_upload_title), shownTitle())
        controller.destroy()
    }
}
