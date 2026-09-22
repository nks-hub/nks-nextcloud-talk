package com.nkshub.nextcloudtalk.calls

import android.app.Notification
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 25, 34])
class ScreenShareServiceTest {
    @Test
    fun captureStartsOnlyAfterAnOngoingNotificationIsPosted() {
        val service = Robolectric.buildService(ScreenShareService::class.java).create()
        val replies = mutableListOf<Boolean>()
        ScreenShareService.onForeground = replies::add
        try {
            service.startCommand(0, 1)
            val notification = shadowOf(service.get()).lastForegroundNotification
            assertNotNull(notification)
            assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
            assertEquals(listOf(true), replies)
        } finally {
            ScreenShareService.onForeground = null
            service.destroy()
        }
    }
}
