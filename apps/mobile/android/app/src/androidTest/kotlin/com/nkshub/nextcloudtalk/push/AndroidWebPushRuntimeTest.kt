package com.nkshub.nextcloudtalk.push

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.unifiedpush.android.connector.UnifiedPush
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class AndroidWebPushRuntimeTest {
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
