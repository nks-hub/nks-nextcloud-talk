package com.nkshub.nextcloudtalk.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.JsonReader
import android.util.JsonToken
import java.io.ByteArrayInputStream
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.nio.charset.CodingErrorAction

internal object AndroidWebPushNotifier {
    private var listener: ((Int) -> Unit)? = null

    @Synchronized
    fun attach(newListener: (Int) -> Unit) {
        listener = newListener
    }

    @Synchronized
    fun detach(attachedListener: (Int) -> Unit) {
        if (listener === attachedListener) {
            listener = null
        }
    }

    fun publish(count: Int) {
        val current = synchronized(this) { listener }
        current?.invoke(count)
    }
}

internal sealed interface AndroidWebPushPayload {
    data class Activation(val token: String) : AndroidWebPushPayload

    data class Message(
        val notificationId: Long?,
        val app: String?,
        val subject: String?,
        val type: String?,
        val objectId: String?,
    ) : AndroidWebPushPayload

    data class Delete(val notificationId: Long) : AndroidWebPushPayload

    data class DeleteMultiple(val notificationIds: List<Long>) : AndroidWebPushPayload

    data object DeleteAll : AndroidWebPushPayload

    data object Invalid : AndroidWebPushPayload
}

internal object AndroidWebPushPayloadParser {
    private val activationTokenPattern = Regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-" +
            "[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$",
    )

    fun parse(content: ByteArray, decrypted: Boolean): AndroidWebPushPayload {
        if (!decrypted || content.isEmpty() || content.size > MAX_PAYLOAD_BYTES) {
            return AndroidWebPushPayload.Invalid
        }
        return runCatching { parseStrictObject(content) }
            .getOrDefault(AndroidWebPushPayload.Invalid)
    }

    private fun parseStrictObject(content: ByteArray): AndroidWebPushPayload {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        JsonReader(InputStreamReader(ByteArrayInputStream(content), decoder)).use { reader ->
            reader.isLenient = false
            if (reader.peek() != JsonToken.BEGIN_OBJECT) {
                return AndroidWebPushPayload.Invalid
            }
            val members = linkedMapOf<String, Any>()
            reader.beginObject()
            while (reader.hasNext()) {
                val name = reader.nextName()
                if (name !in ALL_KEYS || members.containsKey(name)) {
                    return AndroidWebPushPayload.Invalid
                }
                members[name] = when (name) {
                    "activationToken", "app", "subject", "type", "id" ->
                        reader.readBoundedString(stringLimit(name))
                            ?: return AndroidWebPushPayload.Invalid
                    "nid" -> reader.readPositiveInt64()
                        ?: return AndroidWebPushPayload.Invalid
                    "nids" -> reader.readPositiveInt64List()
                        ?: return AndroidWebPushPayload.Invalid
                    "delete", "delete-multiple", "delete-all" ->
                        reader.readTrueBoolean()
                            ?: return AndroidWebPushPayload.Invalid
                    else -> return AndroidWebPushPayload.Invalid
                }
            }
            reader.endObject()
            if (reader.peek() != JsonToken.END_DOCUMENT || members.isEmpty()) {
                return AndroidWebPushPayload.Invalid
            }
            return members.toPayload()
        }
    }

    private fun Map<String, Any>.toPayload(): AndroidWebPushPayload {
        if (containsKey("activationToken")) {
            val token = this["activationToken"] as String
            return if (keys == ACTIVATION_KEYS && activationTokenPattern.matches(token)) {
                AndroidWebPushPayload.Activation(token)
            } else {
                AndroidWebPushPayload.Invalid
            }
        }
        val actions = keys.intersect(ACTION_KEYS)
        if (actions.size > 1) {
            return AndroidWebPushPayload.Invalid
        }
        return when (actions.singleOrNull()) {
            "delete" -> if (keys == DELETE_ONE_KEYS) {
                AndroidWebPushPayload.Delete(getValue("nid") as Long)
            } else {
                AndroidWebPushPayload.Invalid
            }
            "delete-multiple" -> if (keys == DELETE_MULTIPLE_KEYS) {
                @Suppress("UNCHECKED_CAST")
                AndroidWebPushPayload.DeleteMultiple(getValue("nids") as List<Long>)
            } else {
                AndroidWebPushPayload.Invalid
            }
            "delete-all" -> if (keys == DELETE_ALL_KEYS) {
                AndroidWebPushPayload.DeleteAll
            } else {
                AndroidWebPushPayload.Invalid
            }
            null -> if (keys.all(NORMAL_KEYS::contains)) {
                AndroidWebPushPayload.Message(
                    notificationId = this["nid"] as Long?,
                    app = this["app"] as String?,
                    subject = this["subject"] as String?,
                    type = this["type"] as String?,
                    objectId = this["id"] as String?,
                )
            } else {
                AndroidWebPushPayload.Invalid
            }
            else -> AndroidWebPushPayload.Invalid
        }
    }

    private fun JsonReader.readBoundedString(maximumLength: Int): String? {
        if (peek() != JsonToken.STRING) {
            return null
        }
        return nextString().takeIf { it.isNotEmpty() && it.length <= maximumLength }
    }

    private fun JsonReader.readTrueBoolean(): Boolean? {
        if (peek() != JsonToken.BOOLEAN || !nextBoolean()) {
            return null
        }
        return true
    }

    private fun JsonReader.readPositiveInt64(): Long? {
        if (peek() != JsonToken.NUMBER) {
            return null
        }
        val source = nextString()
        if (!POSITIVE_INTEGER_PATTERN.matches(source)) {
            return null
        }
        return source.toLongOrNull()?.takeIf { it > 0 }
    }

    private fun JsonReader.readPositiveInt64List(): List<Long>? {
        if (peek() != JsonToken.BEGIN_ARRAY) {
            return null
        }
        beginArray()
        val result = mutableListOf<Long>()
        val unique = mutableSetOf<Long>()
        while (hasNext()) {
            if (result.size >= MAX_DELETE_IDS) {
                return null
            }
            val value = readPositiveInt64() ?: return null
            if (!unique.add(value)) {
                return null
            }
            result.add(value)
        }
        endArray()
        return result.takeIf { it.isNotEmpty() }
    }

    private fun stringLimit(name: String): Int = when (name) {
        "activationToken" -> 36
        "app" -> MAX_APP_LENGTH
        "subject" -> MAX_SUBJECT_LENGTH
        "type" -> MAX_TYPE_LENGTH
        "id" -> MAX_OBJECT_ID_LENGTH
        else -> 0
    }

    private const val MAX_PAYLOAD_BYTES = 4096
    private const val MAX_DELETE_IDS = 10
    private const val MAX_APP_LENGTH = 128
    private const val MAX_SUBJECT_LENGTH = 2048
    private const val MAX_TYPE_LENGTH = 128
    private const val MAX_OBJECT_ID_LENGTH = 512
    private val POSITIVE_INTEGER_PATTERN = Regex("^[1-9][0-9]*$")
    private val ACTION_KEYS = setOf("delete", "delete-multiple", "delete-all")
    private val ACTIVATION_KEYS = setOf("activationToken")
    private val NORMAL_KEYS = setOf("app", "subject", "type", "id", "nid")
    private val DELETE_ONE_KEYS = setOf("delete", "nid")
    private val DELETE_MULTIPLE_KEYS = setOf("delete-multiple", "nids")
    private val DELETE_ALL_KEYS = setOf("delete-all")
    private val ALL_KEYS = ACTIVATION_KEYS + NORMAL_KEYS + ACTION_KEYS + setOf("nids")
}

internal object AndroidSystemNotifications {
    const val ACTION_OPEN_NOTIFICATION =
        "com.nkshub.nextcloudtalk.action.OPEN_PUSH_NOTIFICATION"

    fun apply(context: Context, accountId: String, payload: AndroidWebPushPayload) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val store = AndroidWebPushStore(context)
        val groupKey = accountGroupKey(accountId)
        when (payload) {
            is AndroidWebPushPayload.Message -> {
                show(context, manager, store, accountId, groupKey, payload)
            }
            is AndroidWebPushPayload.Delete -> {
                store.revokeNotificationOpen(accountId, payload.notificationId)
                manager.cancel(
                    notificationTag(groupKey, payload.notificationId),
                    PLATFORM_NOTIFICATION_ID,
                )
            }
            is AndroidWebPushPayload.DeleteMultiple -> {
                store.revokeNotificationOpens(accountId, payload.notificationIds.toSet())
                payload.notificationIds.forEach {
                    manager.cancel(notificationTag(groupKey, it), PLATFORM_NOTIFICATION_ID)
                }
            }
            AndroidWebPushPayload.DeleteAll -> {
                store.revokeAllNotificationOpens(accountId)
                manager.activeNotifications
                    .filter { it.tag?.startsWith("$groupKey:") == true }
                    .forEach { manager.cancel(it.tag, it.id) }
            }
            is AndroidWebPushPayload.Activation,
            AndroidWebPushPayload.Invalid -> Unit
        }
    }

    fun notificationOpenToken(intent: Intent, packageName: String): String? {
        if (intent.action != ACTION_OPEN_NOTIFICATION) {
            return null
        }
        val data = intent.data ?: return null
        if (
            data.scheme != packageName ||
            data.host != OPEN_URI_HOST ||
            data.query != null ||
            data.fragment != null ||
            data.pathSegments.size != 1
        ) {
            return null
        }
        return data.pathSegments.single()
            .takeIf(AndroidWebPushStore::isValidNotificationOpenToken)
    }

    fun notificationOpenIntent(context: Context, openToken: String): Intent {
        require(AndroidWebPushStore.isValidNotificationOpenToken(openToken))
        return Intent(context, AndroidWebPushActivity::class.java).apply {
            action = ACTION_OPEN_NOTIFICATION
            data = Uri.Builder()
                .scheme(context.packageName)
                .authority(OPEN_URI_HOST)
                .appendPath(openToken)
                .build()
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
    }

    fun notificationOpenPendingIntent(context: Context, openToken: String): PendingIntent {
        return PendingIntent.getActivity(
            context,
            0,
            notificationOpenIntent(context, openToken),
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun show(
        context: Context,
        manager: NotificationManager,
        store: AndroidWebPushStore,
        accountId: String,
        groupKey: String,
        payload: AndroidWebPushPayload.Message,
    ) {
        val notificationId = payload.notificationId ?: return
        val subject = payload.subject ?: return
        val app = payload.app ?: DEFAULT_NOTIFICATION_APP
        ensureChannel(manager)
        val openToken = store.storeNotificationOpen(
            accountId = accountId,
            notificationId = notificationId,
            app = app,
            type = payload.type,
            objectId = payload.objectId,
        )
        val pendingIntent = notificationOpenPendingIntent(context, openToken)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(if (app == "spreed") "NKS Talk" else app)
            .setContentText(subject)
            .setStyle(Notification.BigTextStyle().bigText(subject))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup(groupKey)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        manager.notify(
            notificationTag(groupKey, notificationId),
            PLATFORM_NOTIFICATION_ID,
            notification,
        )
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Talk messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Messages and call activity from Nextcloud Talk"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    private fun accountGroupKey(accountId: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(accountId.toByteArray(StandardCharsets.UTF_8))
        val accountHash = digest.joinToString(separator = "") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
        return "nextcloud-talk-$accountHash"
    }

    private fun notificationTag(groupKey: String, notificationId: Long): String {
        return "$groupKey:$notificationId"
    }

    private const val CHANNEL_ID = "nextcloud_talk_messages"
    private const val OPEN_URI_HOST = "notification-open"
    private const val DEFAULT_NOTIFICATION_APP = "Nextcloud"
    private const val PLATFORM_NOTIFICATION_ID = 1
}
