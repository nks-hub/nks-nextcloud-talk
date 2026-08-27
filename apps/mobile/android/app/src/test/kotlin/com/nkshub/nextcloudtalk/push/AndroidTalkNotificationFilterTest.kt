package com.nkshub.nextcloudtalk.push

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Nextcloud pushes every app's notifications to a registered device. A Deck
/// card once surfaced as a Talk notification because the notifier showed any
/// message payload it decoded, so the `app` field is now the gate.
class AndroidTalkNotificationFilterTest {
    @Test
    fun talkMessagesSurface() {
        assertTrue(
            AndroidSystemNotifications.surfacesAsTalkNotification(
                AndroidWebPushPayload.Message(11L, "spreed", "Someone: hi", "chat", "roomtoken"),
            ),
        )
    }

    @Test
    fun otherAppsDoNotSurface() {
        for (app in listOf("deck", "files", "files_sharing", "notifications", "Nextcloud")) {
            assertFalse(
                app,
                AndroidSystemNotifications.surfacesAsTalkNotification(
                    AndroidWebPushPayload.Message(12L, app, "Board updated", null, null),
                ),
            )
        }
    }

    @Test
    fun aMissingAppIsNotAssumedToBeTalk() {
        assertFalse(
            AndroidSystemNotifications.surfacesAsTalkNotification(
                AndroidWebPushPayload.Message(13L, null, "wake", null, null),
            ),
        )
    }
}
