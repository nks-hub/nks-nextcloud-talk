package com.nkshub.nextcloudtalk.shortcuts

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import com.nkshub.nextcloudtalk.push.AndroidWebPushActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class ConversationShortcutsTest {
    private val context = RuntimeEnvironment.getApplication()
    private val manager = context.getSystemService(ShortcutManager::class.java)

    @Test
    fun writableConversationMatchesTheDeclaredShareTarget() {
        publish(listOf(entry(true)))
        val shortcut = manager.dynamicShortcuts.single()
        val activity = context.packageManager.getActivityInfo(
            ComponentName(context, AndroidWebPushActivity::class.java),
            PackageManager.GET_META_DATA,
        )
        val xml = activity.loadXmlMetaData(context.packageManager, "android.app.shortcuts")
        assertNotNull("Launcher activity must declare sharing targets", xml)
        xml.use {
            var targetClass: String? = null
            var mimeType: String? = null
            var category: String? = null
            while (it.next() != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                if (it.eventType != org.xmlpull.v1.XmlPullParser.START_TAG) continue
                when (it.name) {
                    "share-target" -> targetClass = it.getAttributeValue(ANDROID, "targetClass")
                    "data" -> mimeType = it.getAttributeValue(ANDROID, "mimeType")
                    "category" -> category = it.getAttributeValue(ANDROID, "name")
                }
            }
            assertEquals(AndroidWebPushActivity::class.java.name, targetClass)
            assertEquals("*/*", mimeType)
            assertTrue(shortcut.categories.orEmpty().contains(category))
        }
        assertEquals(Intent.ACTION_VIEW, shortcut.intent?.action)
    }

    @Test
    fun readOnlyConversationStaysOnLauncherWithoutBecomingShareTarget() {
        publish(listOf(entry(false)))
        assertTrue(manager.dynamicShortcuts.single().categories.isNullOrEmpty())
    }

    @Test
    fun clearingPublishedConversationsRemovesShareSuggestions() {
        publish(listOf(entry(true)))
        publish(emptyList())
        assertTrue(manager.dynamicShortcuts.isEmpty())
    }

    private fun entry(shareable: Boolean) = mapOf(
        "id" to "account-a|room-a",
        "label" to "Project",
        "uri" to "https://example.invalid/call/room-a",
        "shareable" to shareable,
    )

    private fun publish(entries: List<Map<String, Any>>) {
        ConversationShortcuts(context).onMethodCall(
            MethodCall("publish", mapOf("shortcuts" to entries)),
            object : MethodChannel.Result {
                override fun success(result: Any?) { assertEquals(entries.size, result) }
                override fun error(code: String, message: String?, details: Any?) { fail(code) }
                override fun notImplemented() { fail("publish not implemented") }
            },
        )
    }

    companion object {
        private const val ANDROID = "http://schemas.android.com/apk/res/android"
    }
}
