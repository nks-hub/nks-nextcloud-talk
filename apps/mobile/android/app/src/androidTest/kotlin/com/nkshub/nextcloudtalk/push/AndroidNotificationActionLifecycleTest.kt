package com.nkshub.nextcloudtalk.push

import android.app.NotificationManager
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidNotificationActionLifecycleTest {
    @Test
    fun durableActionSurvivesEveryBestEffortUiFailure() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val accountId = "instrumentation-action-effects"
        drainAllActions(store, accountId)
        val token = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountId,
            notificationId = 4108,
            roomToken = "roomgolf",
        )
        var failuresAttempted = false
        var statusAttempted = false
        var publishAttempted = false
        val effects = object : NotificationActionEffects {
            override fun showFailures(actions: List<StoredNotificationAction>) {
                failuresAttempted = true
                throw IllegalStateException("failure UI unavailable")
            }

            override fun showStatus(
                action: StoredNotificationAction,
                statusResource: Int,
            ): String {
                statusAttempted = true
                throw IllegalStateException("notification manager unavailable")
            }

            override fun publish(count: Int) {
                publishAttempted = true
                throw IllegalStateException("listener unavailable")
            }
        }

        val launch = AndroidSystemNotifications.performAction(
            context = context,
            kind = NotificationActionKind.REPLY,
            actionToken = token,
            replyText = "durable reply",
            effects = effects,
        )

        assertNotNull(launch)
        assertNull(launch!!.statusOpenToken)
        assertEquals(accountId, launch.route["accountId"])
        assertEquals("roomgolf", launch.route["objectId"])
        assertTrue(failuresAttempted)
        assertTrue(statusAttempted)
        assertTrue(publishAttempted)
        val queued = store.claimNotificationActions(accountId, 10).ready.single()
        assertEquals("durable reply", queued.replyText)
        store.resolveNotificationAction(accountId, queued.token)
    }

    @Test
    fun actionActivityLifecycleQueuesRemoteInputOnceAcrossCreateAndNewIntent() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(NotificationManager::class.java)
        val store = AndroidWebPushStore(context)
        val accountId = "instrumentation-action-lifecycle"
        drainAllActions(store, accountId)
        manager.cancelAll()
        val replyToken = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountId,
            notificationId = 4109,
            roomToken = "roomhotel",
        )
        val replyInput = RemoteInput.Builder(AndroidSystemNotifications.REPLY_RESULT_KEY)
            .build()
        val replyIntent = AndroidSystemNotifications.notificationActionIntent(
            context,
            NotificationActionKind.REPLY,
            replyToken,
        )
        RemoteInput.addResultsToIntent(
            arrayOf(replyInput),
            replyIntent,
            android.os.Bundle().apply {
                putCharSequence(AndroidSystemNotifications.REPLY_RESULT_KEY, "lifecycle reply")
            },
        )

        val launchIntent = Intent(replyIntent).addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK,
        )
        val scenario = ActivityScenario.launch<AndroidWebPushActivity>(launchIntent)
        val first = store.claimNotificationActions(accountId, 10).ready.single()
        assertEquals("lifecycle reply", first.replyText)
        store.resolveNotificationAction(accountId, first.token)

        scenario.onActivity { activity ->
            InstrumentationRegistry.getInstrumentation()
                .callActivityOnNewIntent(activity, replyIntent)
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertTrue(store.claimNotificationActions(accountId, 10).ready.isEmpty())

        val markReadToken = store.armNotificationAction(
            kind = NotificationActionKind.MARK_READ,
            accountId = accountId,
            notificationId = 4110,
            roomToken = "roomhotel",
        )
        val markReadIntent = AndroidSystemNotifications.notificationActionIntent(
            context,
            NotificationActionKind.MARK_READ,
            markReadToken,
        )
        scenario.onActivity { activity ->
            InstrumentationRegistry.getInstrumentation()
                .callActivityOnNewIntent(activity, markReadIntent)
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val second = store.claimNotificationActions(accountId, 10).ready.single()
        assertEquals(NotificationActionKind.MARK_READ, second.kind)
        assertNull(second.replyText)
        store.resolveNotificationAction(accountId, second.token)
        scenario.onActivity { activity -> activity.finish() }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        manager.cancelAll()
        val deadline = SystemClock.elapsedRealtime() + 2_000
        while (manager.activeNotifications.isNotEmpty() &&
            SystemClock.elapsedRealtime() < deadline
        ) {
            SystemClock.sleep(25)
        }
        assertTrue(manager.activeNotifications.isEmpty())
    }

    private fun drainAllActions(store: AndroidWebPushStore, accountId: String) {
        var guard = 0
        while (guard++ < 20) {
            val claim = store.claimNotificationActions(accountId, 100)
            if (claim.ready.isEmpty()) {
                return
            }
            claim.ready.forEach { store.resolveNotificationAction(accountId, it.token) }
        }
    }
}
