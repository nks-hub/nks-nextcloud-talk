package com.nkshub.nextcloudtalk.push

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.unifiedpush.android.connector.UnifiedPush
import org.unifiedpush.android.connector.data.PushMessage
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class AndroidWebPushRuntimeTest {
    @Test
    fun nativeChannelImplementsTheDartBootstrapMethodMatrix() {
        ActivityScenario.launch(AndroidWebPushActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val channel = AndroidWebPushChannel(activity.applicationContext, activity)

                val registration = CapturingResult()
                channel.onMethodCall(
                    MethodCall(
                        "getRegistrationState",
                        mapOf("accountId" to "instrumentation-method-matrix"),
                    ),
                    registration,
                )
                val registrationMap = registration.value as Map<*, *>
                assertEquals(1L, registrationMap["nextGeneration"])
                assertEquals(0, registrationMap["pendingEventCount"])
                assertNull(registration.errorCode)

                val permission = CapturingResult()
                channel.onMethodCall(MethodCall("getNotificationPermission", null), permission)
                assertTrue(
                    (permission.value as Map<*, *>)["status"] in
                        setOf("notDetermined", "denied", "granted"),
                )
                assertNull(permission.errorCode)

                val launch = CapturingResult()
                channel.onMethodCall(MethodCall("getLaunchNotification", null), launch)
                assertNull(launch.value)
                assertNull(launch.errorCode)
            }
        }
    }

    @Test
    fun notificationOpenIsDurableOneTimeAndRejectsForgedExtras() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val tokenA = store.storeNotificationOpen(
            accountId = "instrumentation-open-account-a",
            notificationId = Long.MAX_VALUE,
            app = "spreed",
            type = "chat",
            objectId = "room-a",
        )
        val tokenB = store.storeNotificationOpen(
            accountId = "instrumentation-open-account-b",
            notificationId = Long.MAX_VALUE,
            app = "spreed",
            type = "chat",
            objectId = "room-b",
        )
        assertTrue(tokenA != tokenB)

        val openPreferences = context.getSharedPreferences(
            AndroidNotificationOpenStore.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        val encryptedBeforeMiss = openPreferences.getString(
            AndroidNotificationOpenStore.STATE_KEY,
            null,
        )
        assertNotNull(encryptedBeforeMiss)
        assertFalse(encryptedBeforeMiss!!.contains(tokenA))
        assertFalse(encryptedBeforeMiss.contains("instrumentation-open-account-a"))
        assertNull(store.consumeNotificationOpen("nksopen1_${"A".repeat(43)}"))
        assertEquals(
            encryptedBeforeMiss,
            openPreferences.getString(AndroidNotificationOpenStore.STATE_KEY, null),
        )

        val pendingIntentA = AndroidSystemNotifications.notificationOpenPendingIntent(context, tokenA)
        val pendingIntentB = AndroidSystemNotifications.notificationOpenPendingIntent(context, tokenB)
        assertNotEquals(pendingIntentA, pendingIntentB)
        assertNotEquals(pendingIntentA.intentSender, pendingIntentB.intentSender)
        pendingIntentA.cancel()
        pendingIntentB.cancel()

        val reopenedStore = AndroidWebPushStore(context)
        val first = reopenedStore.consumeNotificationOpen(tokenA)
        assertEquals("instrumentation-open-account-a", first?.get("accountId"))
        assertEquals(Long.MAX_VALUE, first?.get("notificationId"))
        assertEquals("room-a", first?.get("objectId"))
        assertNull(reopenedStore.consumeNotificationOpen(tokenA))
        assertEquals(
            "instrumentation-open-account-b",
            reopenedStore.consumeNotificationOpen(tokenB)?.get("accountId"),
        )

        val activityToken = store.storeNotificationOpen(
            accountId = "instrumentation-open-account-c",
            notificationId = Long.MAX_VALUE,
            app = "spreed",
            type = "chat",
            objectId = "room-c",
        )
        val openIntent = AndroidSystemNotifications.notificationOpenIntent(context, activityToken)
        val forgedIntent = Intent(context, AndroidWebPushActivity::class.java)
            .putExtra("push.accountId", "forged-account")
            .putExtra("push.notificationId", 1)
            .putExtra("push.app", "spreed")
        ActivityScenario.launch<AndroidWebPushActivity>(forgedIntent).use { scenario ->
            scenario.onActivity { activity ->
                val channel = AndroidWebPushChannel(activity.applicationContext, activity)
                val launch = CapturingResult()
                channel.onMethodCall(MethodCall("getLaunchNotification", null), launch)
                assertNull(launch.value)
                val value = activity.notificationOpen(openIntent) as Map<*, *>
                assertEquals("instrumentation-open-account-c", value["accountId"])
                assertEquals(Long.MAX_VALUE, value["notificationId"])
                assertEquals("room-c", value["objectId"])
                assertNull(activity.notificationOpen(openIntent))
            }
        }
    }

    @Test
    fun cancelledNotificationPermissionRequestCanBeAskedAgain() {
        ActivityScenario.launch(AndroidWebPushActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val preferences = activity.getSharedPreferences(
                    AndroidWebPushActivity.PERMISSION_PREFERENCES,
                    Context.MODE_PRIVATE,
                )
                preferences.edit()
                    .putBoolean(AndroidWebPushActivity.PERMISSION_ASKED, true)
                    .commit()

                activity.onRequestPermissionsResult(
                    AndroidWebPushActivity.NOTIFICATION_PERMISSION_REQUEST,
                    emptyArray(),
                    intArrayOf(),
                )

                assertFalse(
                    preferences.getBoolean(AndroidWebPushActivity.PERMISSION_ASKED, true),
                )
            }
        }
    }

    @Test
    fun strictInvalidPayloadIsDurablySanitizedBeforeDart() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val accountId = "instrumentation-invalid-payload"
        val instance = AndroidWebPushStore.newOpaqueInstance()
        val generation = System.currentTimeMillis()
        val previous = store.drain(accountId, 100).mapNotNull { it["id"] as? String }.toSet()
        if (previous.isNotEmpty()) {
            store.acknowledge(accountId, previous)
        }
        store.beginRegistration(accountId, generation, instance)

        AndroidWebPushEventSink.message(
            context,
            PushMessage(
                """{"activationToken":"9f9bcfc4-93db-4f23-a8f4-5f2403f722cc","app":"spreed"}"""
                    .toByteArray(StandardCharsets.UTF_8),
                true,
            ),
            instance,
        )

        val event = store.drain(accountId, 10).single()
        assertEquals(StoredPushEventType.MESSAGE.wireName, event["type"])
        assertEquals(false, event["decrypted"])
        assertEquals(false, event["payloadOversized"])
        assertEquals(0, event["originalSize"])
        assertFalse(event.containsKey("content"))
        store.acknowledge(accountId, setOf(event.getValue("id") as String))
        store.markRetired(instance)
    }

    @Test
    fun embeddedDistributorPersistsEndpointBeforeNotification() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val accountId = DURABILITY_ACCOUNT_ID
        val generation = System.currentTimeMillis()
        val instance = AndroidWebPushStore.newOpaqueInstance()
        val eventAvailable = CountDownLatch(1)
        val listener: (Int) -> Unit = { eventAvailable.countDown() }

        val oldEventIds = store.drain(accountId, 100)
            .mapNotNull { it["id"] as? String }
            .toSet()
        if (oldEventIds.isNotEmpty()) {
            store.acknowledge(accountId, oldEventIds)
        }

        assertTrue(UnifiedPush.getDistributors(context).contains(context.packageName))
        val savedDistributor = UnifiedPush.getSavedDistributor(context)
        assertTrue(savedDistributor == null || savedDistributor == context.packageName)
        if (savedDistributor == null) {
            UnifiedPush.saveDistributor(context, context.packageName)
        }

        store.beginRegistration(accountId, generation, instance)
        AndroidWebPushNotifier.attach(listener)
        try {
            UnifiedPush.register(
                context,
                instance,
                "NKS Talk instrumentation",
                TEST_VAPID,
            )
            assertTrue(eventAvailable.await(45, TimeUnit.SECONDS))
            val endpointEvent = store.drain(accountId, 10).firstOrNull {
                it["type"] == StoredPushEventType.ENDPOINT.wireName
            }
            assertTrue(endpointEvent != null)
            assertTrue(endpointEvent?.get("coalescedCount") == 1)
            assertTrue(store.pendingEventCount(accountId) > 0)
        } finally {
            AndroidWebPushNotifier.detach(listener)
            UnifiedPush.unregister(context, instance)
            store.markRetired(instance)
        }
    }

    @Test
    fun encryptedQueueSurvivesProcessRestart() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val events = store.drain(DURABILITY_ACCOUNT_ID, 100)

        assertTrue(events.any { it["type"] == StoredPushEventType.ENDPOINT.wireName })
        val eventIds = events.mapNotNull { it["id"] as? String }.toSet()
        assertTrue(eventIds.isNotEmpty())
        assertTrue(store.acknowledge(DURABILITY_ACCOUNT_ID, eventIds) > 0)
    }

    companion object {
        private const val DURABILITY_ACCOUNT_ID = "instrumentation-durable-account"
        private const val TEST_VAPID =
            "BJVlg_p7GZr_ZluA2ace8aWj8dXVG6hB5L19VhMX3lbVd3c8IqrziiHVY3ERNVhB9Jje5HNZQI4nUOtF_XkUIyI"
    }
}

private class CapturingResult : MethodChannel.Result {
    var value: Any? = null
    var errorCode: String? = null

    override fun success(result: Any?) {
        value = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        this.errorCode = errorCode
    }

    override fun notImplemented() {
        errorCode = "not_implemented"
    }
}
