package com.nkshub.nextcloudtalk.push

import android.app.Notification
import android.app.NotificationManager
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
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
    fun duplicateMessageIsSuppressedAcrossStoreReopenAndAccountScope() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                "android.permission.POST_NOTIFICATIONS",
            )
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val suffix = System.currentTimeMillis().toString()
        val accountA = "instrumentation-dedup-a-$suffix"
        val accountB = "instrumentation-dedup-b-$suffix"
        val instanceA = AndroidWebPushStore.newOpaqueInstance()
        val instanceB = AndroidWebPushStore.newOpaqueInstance()
        val first = PushMessage(
            """{"nid":5101,"app":"spreed","subject":"first","type":"chat","id":"roomalpha"}"""
                .toByteArray(StandardCharsets.UTF_8),
            true,
        )
        val second = PushMessage(
            """{"nid":5102,"app":"spreed","subject":"second","type":"chat","id":"roomalpha"}"""
                .toByteArray(StandardCharsets.UTF_8),
            true,
        )

        manager.cancelAll()
        try {
            AndroidWebPushStore(context).apply {
                beginRegistration(accountA, 1, instanceA)
                beginRegistration(accountB, 1, instanceB)
            }
            AndroidWebPushEventSink.message(context, first, instanceA)
            val firstNotification = manager.activeNotifications.single {
                it.notification.extras.getString(Notification.EXTRA_TEXT) == "first"
            }.notification
            val replyIntent = firstNotification.actions[0].actionIntent
            val markReadIntent = firstNotification.actions[1].actionIntent

            AndroidWebPushEventSink.message(context, first, instanceA)
            val afterDuplicate = manager.activeNotifications.single {
                it.notification.extras.getString(Notification.EXTRA_TEXT) == "first"
            }.notification
            assertEquals(replyIntent, afterDuplicate.actions[0].actionIntent)
            assertEquals(markReadIntent, afterDuplicate.actions[1].actionIntent)

            AndroidWebPushEventSink.message(context, first, instanceB)
            AndroidWebPushEventSink.message(context, second, instanceA)

            val reopened = AndroidWebPushStore(context)
            val eventsA = reopened.drain(accountA, 10)
            val eventsB = reopened.drain(accountB, 10)
            assertEquals(2, eventsA.size)
            assertEquals(1, eventsB.size)
            assertEquals(2, eventsA.map { it["content"] }.toSet().size)
        } finally {
            val cleanup = AndroidWebPushStore(context)
            listOf(accountA, accountB).forEach { accountId ->
                val ids = cleanup.drain(accountId, 10)
                    .map { it.getValue("id") as String }
                    .toSet()
                if (ids.isNotEmpty()) {
                    cleanup.acknowledge(accountId, ids)
                }
                cleanup.revokeAllNotificationOpens(accountId)
            }
            cleanup.markRetired(instanceA)
            cleanup.markRetired(instanceB)
            manager.cancelAll()
        }
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

    @Test
    fun notificationActionsAreAccountScopedDurableAndOneShot() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val accountA = "instrumentation-action-account-a"
        val accountB = "instrumentation-action-account-b"
        drainAllActions(store, accountA)
        drainAllActions(store, accountB)

        val replyA = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountA,
            notificationId = 4101,
            roomToken = "roomalpha",
        )
        val markReadA = store.armNotificationAction(
            kind = NotificationActionKind.MARK_READ,
            accountId = accountA,
            notificationId = 4101,
            roomToken = "roomalpha",
        )
        val replyB = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountB,
            notificationId = 4101,
            roomToken = "roombravo",
        )
        assertNotEquals(replyA, markReadA)
        assertNotEquals(replyA, replyB)

        val preferences = context.getSharedPreferences(
            AndroidNotificationOpenStore.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        val encrypted = preferences.getString(AndroidNotificationOpenStore.STATE_KEY, null)
        assertNotNull(encrypted)
        assertFalse(encrypted!!.contains(replyA))
        assertFalse(encrypted.contains(accountA))
        assertFalse(encrypted.contains("roomalpha"))

        // An armed token cannot be fired as the other kind.
        assertNull(store.fireNotificationAction(replyA, NotificationActionKind.MARK_READ, "x"))
        assertNull(
            store.fireNotificationAction(
                "nksact1_${"A".repeat(43)}",
                NotificationActionKind.REPLY,
                "x",
            ),
        )

        val fired = AndroidWebPushStore(context)
            .fireNotificationAction(replyA, NotificationActionKind.REPLY, "hello there")
        assertNotNull(fired)
        assertEquals(accountA, fired!!.queued.accountId)
        assertEquals("roomalpha", fired.queued.roomToken)
        assertEquals("hello there", fired.queued.replyText)
        assertTrue(fired.evicted.isEmpty())
        // One tap consumes every armed intent of that notification.
        assertNull(store.fireNotificationAction(replyA, NotificationActionKind.REPLY, "again"))
        assertNull(
            store.fireNotificationAction(markReadA, NotificationActionKind.MARK_READ, null),
        )

        val reopened = AndroidWebPushStore(context)
        assertTrue(reopened.claimNotificationActions(accountB, 10).ready.isEmpty())
        val claimed = reopened.claimNotificationActions(accountA, 10)
        assertEquals(1, claimed.ready.size)
        assertTrue(claimed.exhausted.isEmpty())
        val queued = claimed.ready.single()
        assertEquals(replyA, queued.token)
        assertEquals(NotificationActionKind.REPLY, queued.kind)
        assertEquals("hello there", queued.replyText)
        assertEquals(1, queued.attempts)
        assertFalse(queued.toString().contains("hello there"))
        assertFalse(queued.toString().contains("roomalpha"))
        assertFalse(queued.toString().contains(accountA))

        val channelMap = queued.toChannelMap()
        assertEquals(replyA, channelMap["id"])
        assertEquals("REPLY", channelMap["kind"])
        assertEquals(4101L, channelMap["notificationId"])

        // The other account cannot resolve it away.
        assertNull(reopened.resolveNotificationAction(accountB, replyA))
        assertNotNull(reopened.resolveNotificationAction(accountA, replyA))
        assertNull(reopened.resolveNotificationAction(accountA, replyA))
        assertTrue(reopened.claimNotificationActions(accountA, 10).ready.isEmpty())

        store.fireNotificationAction(replyB, NotificationActionKind.REPLY, "other account")
        drainAllActions(store, accountB)
    }

    @Test
    fun queuedActionSurvivesNotificationRevocationAndBoundsRetries() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val accountId = "instrumentation-action-retention"
        drainAllActions(store, accountId)

        val armed = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountId,
            notificationId = 4102,
            roomToken = "roomcharlie",
        )
        val keptArmed = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountId,
            notificationId = 4103,
            roomToken = "roomcharlie",
        )
        store.fireNotificationAction(armed, NotificationActionKind.REPLY, "typed text")

        // A server-side delete disarms pending intents but must never discard
        // text the user already sent off.
        store.revokeNotificationOpens(accountId, setOf(4102L, 4103L))
        assertNull(store.fireNotificationAction(keptArmed, NotificationActionKind.REPLY, "x"))
        assertEquals(1, store.claimNotificationActions(accountId, 10).ready.size)

        var exhausted: StoredNotificationAction? = null
        for (attempt in 2..AndroidWebPushStateMachine.MAX_NOTIFICATION_ACTION_ATTEMPTS + 1) {
            val claim = store.claimNotificationActions(accountId, 10)
            exhausted = claim.exhausted.singleOrNull() ?: exhausted
        }
        assertNotNull(exhausted)
        assertEquals("typed text", exhausted!!.replyText)
        assertTrue(store.claimNotificationActions(accountId, 10).ready.isEmpty())
    }

    @Test
    fun notificationActionIntentsAreExplicitOpaqueAndPerAccount() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val accountId = "instrumentation-action-intent"
        drainAllActions(store, accountId)
        val token = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountId,
            notificationId = 4104,
            roomToken = "roomdelta",
        )

        val intent = AndroidSystemNotifications.notificationActionIntent(
            context,
            NotificationActionKind.REPLY,
            token,
        )
        assertEquals(context.packageName, intent.component?.packageName)
        assertEquals(
            AndroidWebPushActivity::class.java.name,
            intent.component?.className,
        )
        val serialized = intent.toUri(Intent.URI_INTENT_SCHEME)
        assertFalse(serialized.contains(accountId))
        assertFalse(serialized.contains("roomdelta"))

        val parsed = AndroidSystemNotifications.notificationActionRequest(
            intent,
            context.packageName,
        )
        assertEquals(NotificationActionKind.REPLY to token, parsed)
        // A foreign scheme, an unknown host and a bad token are all rejected.
        assertNull(
            AndroidSystemNotifications.notificationActionRequest(intent, "com.example.other"),
        )
        assertNull(
            AndroidSystemNotifications.notificationActionRequest(
                Intent(intent).apply {
                    data = Uri.parse("${context.packageName}://notification-open/$token")
                },
                context.packageName,
            ),
        )
        assertNull(
            AndroidSystemNotifications.notificationActionRequest(
                Intent(intent).apply {
                    data = Uri.parse("${context.packageName}://notification-reply/not-a-token")
                },
                context.packageName,
            ),
        )

        val replyIntent = AndroidSystemNotifications.notificationActionPendingIntent(
            context,
            NotificationActionKind.REPLY,
            token,
        )
        val markReadToken = store.armNotificationAction(
            kind = NotificationActionKind.MARK_READ,
            accountId = accountId,
            notificationId = 4104,
            roomToken = "roomdelta",
        )
        val markReadIntent = AndroidSystemNotifications.notificationActionPendingIntent(
            context,
            NotificationActionKind.MARK_READ,
            markReadToken,
        )
        assertNotEquals(replyIntent, markReadIntent)
        assertNotEquals(replyIntent.intentSender, markReadIntent.intentSender)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            assertTrue(markReadIntent.isActivity)
            assertTrue(replyIntent.isActivity)
            assertFalse(markReadIntent.isImmutable == false)
            assertTrue(replyIntent.isImmutable == false)
        }
        replyIntent.cancel()
        markReadIntent.cancel()
        drainAllActions(store, accountId)
    }

    @Test
    fun channelRejectsForeignAccountAndInvalidActionArguments() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = AndroidWebPushStore(context)
        val accountA = "instrumentation-action-channel-a"
        val accountB = "instrumentation-action-channel-b"
        drainAllActions(store, accountA)
        drainAllActions(store, accountB)
        val token = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountA,
            notificationId = 4105,
            roomToken = "roomecho",
        )
        store.fireNotificationAction(token, NotificationActionKind.REPLY, "channel text")

        ActivityScenario.launch(AndroidWebPushActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val channel = AndroidWebPushChannel(activity.applicationContext, activity)

                val foreign = CapturingResult()
                channel.onMethodCall(
                    MethodCall(
                        "drainNotificationActions",
                        mapOf("accountId" to accountB, "limit" to 10),
                    ),
                    foreign,
                )
                assertTrue((foreign.value as List<*>).isEmpty())

                val badLimit = CapturingResult()
                channel.onMethodCall(
                    MethodCall(
                        "drainNotificationActions",
                        mapOf("accountId" to accountA, "limit" to 0),
                    ),
                    badLimit,
                )
                assertEquals("invalid_drain_limit", badLimit.errorCode)

                val drained = CapturingResult()
                channel.onMethodCall(
                    MethodCall(
                        "drainNotificationActions",
                        mapOf("accountId" to accountA, "limit" to 10),
                    ),
                    drained,
                )
                val action = (drained.value as List<*>).single() as Map<*, *>
                assertEquals(accountA, action["accountId"])
                assertEquals("roomecho", action["roomToken"])
                assertEquals("channel text", action["replyText"])

                val badOutcome = CapturingResult()
                channel.onMethodCall(
                    MethodCall(
                        "resolveNotificationAction",
                        mapOf(
                            "accountId" to accountA,
                            "actionId" to token,
                            "outcome" to "pretend-ok",
                        ),
                    ),
                    badOutcome,
                )
                assertEquals("invalid_outcome", badOutcome.errorCode)

                val foreignResolve = CapturingResult()
                channel.onMethodCall(
                    MethodCall(
                        "resolveNotificationAction",
                        mapOf(
                            "accountId" to accountB,
                            "actionId" to token,
                            "outcome" to "completed",
                        ),
                    ),
                    foreignResolve,
                )
                assertEquals(false, (foreignResolve.value as Map<*, *>)["resolved"])

                val resolved = CapturingResult()
                channel.onMethodCall(
                    MethodCall(
                        "resolveNotificationAction",
                        mapOf(
                            "accountId" to accountA,
                            "actionId" to token,
                            "outcome" to "completed",
                        ),
                    ),
                    resolved,
                )
                assertEquals(true, (resolved.value as Map<*, *>)["resolved"])
            }
        }
        assertTrue(store.claimNotificationActions(accountA, 10).ready.isEmpty())
    }

    @Test
    fun postedChatNotificationCarriesReplyAndMarkReadAndQueuesTheTap() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            instrumentation.uiAutomation.grantRuntimePermission(
                context.packageName,
                "android.permission.POST_NOTIFICATIONS",
            )
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val store = AndroidWebPushStore(context)
        val accountId = "instrumentation-action-runtime"
        drainAllActions(store, accountId)
        manager.cancelAll()

        AndroidSystemNotifications.apply(
            context,
            accountId,
            AndroidWebPushPayload.Message(
                notificationId = 4106,
                app = "spreed",
                subject = "instrumentation subject",
                type = "chat",
                objectId = "roomfoxtrot",
            ),
        )

        val posted = manager.activeNotifications.single {
            it.notification.extras.getString(Notification.EXTRA_TEXT) ==
                "instrumentation subject"
        }
        val actions = posted.notification.actions
        assertEquals(2, actions.size)
        val remoteInputs = actions[0].remoteInputs
        assertNotNull(remoteInputs)
        assertEquals(
            AndroidSystemNotifications.REPLY_RESULT_KEY,
            remoteInputs!!.single().resultKey,
        )
        assertNull(actions[1].remoteInputs)

        // Reproduce what the system does when the user submits the reply.
        val armed = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountId,
            notificationId = 4106,
            roomToken = "roomfoxtrot",
        )
        val replyIntent = AndroidSystemNotifications.notificationActionIntent(
            context,
            NotificationActionKind.REPLY,
            armed,
        )
        RemoteInput.addResultsToIntent(
            remoteInputs,
            replyIntent,
            android.os.Bundle().apply {
                putCharSequence(
                    AndroidSystemNotifications.REPLY_RESULT_KEY,
                    "  runtime reply  ",
                )
            },
        )
        ActivityScenario.launch(AndroidWebPushActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val launch = activity.notificationAction(replyIntent)
                assertNotNull(launch)
                val wakeRoute = launch!!.route
                assertEquals(accountId, wakeRoute["accountId"])
                assertEquals("roomfoxtrot", wakeRoute["objectId"])
                assertNotNull(launch.statusOpenToken)
                val statusRoute = store.consumeNotificationOpen(launch.statusOpenToken!!)
                assertEquals(accountId, statusRoute?.get("accountId"))
                assertEquals("roomfoxtrot", statusRoute?.get("objectId"))
            }
        }

        val queued = store.claimNotificationActions(accountId, 10).ready.single()
        assertEquals("runtime reply", queued.replyText)
        assertEquals("roomfoxtrot", queued.roomToken)
        assertEquals(accountId, queued.accountId)

        // The tap is visibly acknowledged: the notification is replaced by a
        // status without actions instead of silently staying as it was.
        val queuedNotification = manager.activeNotifications.single {
            it.tag == posted.tag
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            assertTrue(queuedNotification.notification.contentIntent.isActivity)
        }
        assertTrue(queuedNotification.notification.actions.isNullOrEmpty())
        assertNotEquals(
            "instrumentation subject",
            queuedNotification.notification.extras.getString(Notification.EXTRA_TEXT),
        )

        store.resolveNotificationAction(accountId, queued.token)
        manager.cancelAll()
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
