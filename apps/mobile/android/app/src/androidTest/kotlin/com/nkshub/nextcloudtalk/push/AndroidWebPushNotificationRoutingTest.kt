package com.nkshub.nextcloudtalk.push

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidWebPushNotificationRoutingTest {
    @Test
    fun sameServerIdStaysStableAcrossAccountsRestartAndDeletes() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        grantNotificationPermission(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        val accountA = "instrumentation-routing-account-a"
        val accountB = "instrumentation-routing-account-b"
        val firstId = 920001L
        val secondId = 920002L
        cleanup(context, manager, accountA, accountB)

        post(context, accountA, firstId, "routing a first")
        post(context, accountB, firstId, "routing b first")
        val firstA = awaitNotificationWithText(manager, "routing a first")
        val firstB = awaitNotificationWithText(manager, "routing b first")
        assertNotEquals(firstA.id, firstB.id)
        assertTrue(firstA.id > 1)
        assertTrue(firstB.id > 1)
        val encrypted = context.getSharedPreferences(
            AndroidNotificationOpenStore.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        ).getString(AndroidNotificationOpenStore.STATE_KEY, null)
        assertTrue(encrypted != null)
        assertFalse(encrypted!!.contains(accountA))
        assertFalse(encrypted.contains(accountB))
        assertFalse(encrypted.contains(firstId.toString()))

        // Every apply call reopens the encrypted store, matching a callback
        // delivered to a process recreated for an inactive account.
        post(context, accountA, firstId, "routing a replaced")
        val replacedA = awaitNotificationWithText(manager, "routing a replaced")
        assertEquals(firstA.id, replacedA.id)
        assertEquals(firstB.id, awaitNotificationWithText(manager, "routing b first").id)

        AndroidSystemNotifications.apply(
            context,
            accountA,
            AndroidWebPushPayload.Delete(firstId),
        )
        assertEquals(listOf("routing b first"), awaitActiveTexts(manager, setOf("routing b first")))

        post(context, accountA, firstId, "routing a restored")
        post(context, accountA, secondId, "routing a second")
        post(context, accountB, secondId, "routing b second")
        AndroidSystemNotifications.apply(
            context,
            accountA,
            AndroidWebPushPayload.DeleteMultiple(listOf(firstId, secondId)),
        )
        assertEquals(
            setOf("routing b first", "routing b second"),
            awaitActiveTexts(manager, setOf("routing b first", "routing b second")).toSet(),
        )

        post(context, accountA, firstId, "routing a final")
        AndroidSystemNotifications.apply(context, accountA, AndroidWebPushPayload.DeleteAll)
        assertEquals(
            setOf("routing b first", "routing b second"),
            awaitActiveTexts(manager, setOf("routing b first", "routing b second")).toSet(),
        )

        cleanup(context, manager, accountA, accountB)
    }

    @Test
    fun markReadStatusAndCompletionStayOnTheSelectedAccountId() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        grantNotificationPermission(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        val store = AndroidWebPushStore(context)
        val accountA = "instrumentation-routing-action-a"
        val accountB = "instrumentation-routing-action-b"
        val notificationId = 920010L
        cleanup(context, manager, accountA, accountB)

        post(context, accountA, notificationId, "routing action a", "roomroutea")
        post(context, accountB, notificationId, "routing action b", "roomrouteb")
        val postedA = awaitNotificationWithText(manager, "routing action a")
        val postedB = awaitNotificationWithText(manager, "routing action b")
        assertNotEquals(postedA.id, postedB.id)

        val markReadToken = store.armNotificationAction(
            kind = NotificationActionKind.MARK_READ,
            accountId = accountA,
            notificationId = notificationId,
            roomToken = "roomroutea",
        )
        val markReadIntent = AndroidSystemNotifications.notificationActionIntent(
            context,
            NotificationActionKind.MARK_READ,
            markReadToken,
        )
        ActivityScenario.launch(AndroidWebPushActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                assertTrue(activity.notificationAction(markReadIntent) != null)
            }
        }
        val claimA = awaitClaim(store, accountA)
        assertEquals(1, claimA.ready.size)
        assertTrue(store.claimNotificationActions(accountB, 10).ready.isEmpty())
        val queued = claimA.ready.single()
        val statusA = awaitNotificationWithChangedText(
            manager,
            postedA.tag,
            "routing action a",
        )
        assertEquals(postedA.id, statusA.id)
        assertEquals(postedB.id, awaitNotificationWithText(manager, "routing action b").id)

        assertTrue(store.resolveNotificationAction(accountA, queued.token) != null)
        AndroidSystemNotifications.cancelNotification(context, accountA, notificationId)
        assertEquals(
            listOf("routing action b"),
            awaitActiveTexts(manager, setOf("routing action b")),
        )

        cleanup(context, manager, accountA, accountB)
    }

    private fun post(
        context: Context,
        accountId: String,
        notificationId: Long,
        subject: String,
        roomToken: String = "instrumentation-routing-room",
    ) {
        AndroidSystemNotifications.apply(
            context,
            accountId,
            AndroidWebPushPayload.Message(
                notificationId = notificationId,
                app = "spreed",
                subject = subject,
                type = "chat",
                objectId = roomToken,
            ),
        )
    }

    private fun awaitNotificationWithText(
        manager: NotificationManager,
        text: String,
    ) = awaitValue {
        manager.activeNotifications.singleOrNull {
            it.notification.extras.getString(Notification.EXTRA_TEXT) == text
        }
    }

    private fun awaitNotificationWithChangedText(
        manager: NotificationManager,
        tag: String?,
        previousText: String,
    ) = awaitValue {
        manager.activeNotifications.singleOrNull { it.tag == tag }?.takeIf {
            it.notification.extras.getString(Notification.EXTRA_TEXT) != previousText
        }
    }

    private fun awaitClaim(
        store: AndroidWebPushStore,
        accountId: String,
    ) = awaitValue {
        store.claimNotificationActions(accountId, 10).takeIf { it.ready.isNotEmpty() }
    }

    private fun awaitActiveTexts(
        manager: NotificationManager,
        expected: Set<String>,
    ): List<String> = awaitValue {
        activeTexts(manager).takeIf { it.toSet() == expected }
    }

    private fun <T> awaitValue(read: () -> T?): T {
        val deadline = SystemClock.elapsedRealtime() + 5_000
        do {
            read()?.let { return it }
            SystemClock.sleep(25)
        } while (SystemClock.elapsedRealtime() < deadline)
        throw AssertionError("Timed out waiting for notification state")
    }

    private fun activeTexts(manager: NotificationManager): List<String> {
        return manager.activeNotifications.mapNotNull {
            it.notification.extras.getString(Notification.EXTRA_TEXT)
        }.sorted()
    }

    private fun cleanup(
        context: Context,
        manager: NotificationManager,
        vararg accountIds: String,
    ) {
        accountIds.forEach {
            AndroidSystemNotifications.apply(context, it, AndroidWebPushPayload.DeleteAll)
        }
        manager.cancelAll()
    }

    private fun grantNotificationPermission(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(
                context.packageName,
                "android.permission.POST_NOTIFICATIONS",
            )
        }
    }
}
