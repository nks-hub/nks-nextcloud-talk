package com.nkshub.nextcloudtalk.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.util.JsonReader
import android.util.JsonToken
import com.nkshub.nextcloudtalk.R
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
                val released = store.revokeNotificationOpen(accountId, payload.notificationId)
                cancelNotificationRoute(
                    manager,
                    accountId,
                    payload.notificationId,
                    released?.platformNotificationId,
                )
            }
            is AndroidWebPushPayload.DeleteMultiple -> {
                val released = store
                    .revokeNotificationOpens(accountId, payload.notificationIds.toSet())
                    .associateBy { it.notificationId }
                payload.notificationIds.forEach {
                    cancelNotificationRoute(
                        manager,
                        accountId,
                        it,
                        released[it]?.platformNotificationId,
                    )
                }
            }
            AndroidWebPushPayload.DeleteAll -> {
                cancelEvictedRoutes(manager, store.revokeAllNotificationOpens(accountId))
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

    fun isValidRoomToken(token: String): Boolean = ROOM_TOKEN_PATTERN.matches(token)

    fun notificationActionIntent(
        context: Context,
        kind: NotificationActionKind,
        actionToken: String,
    ): Intent {
        require(AndroidWebPushStore.isValidNotificationActionToken(actionToken))
        return Intent(context, AndroidNotificationActionReceiver::class.java).apply {
            action = ACTION_NOTIFICATION_ACTION
            // Only the opaque token travels in the intent. Account id, room
            // token and typed text stay in the encrypted store, so a dumpsys
            // of pending intents cannot reveal them.
            data = Uri.Builder()
                .scheme(context.packageName)
                .authority(actionUriHost(kind))
                .appendPath(actionToken)
                .build()
        }
    }

    fun notificationActionRequest(
        intent: Intent,
        packageName: String,
    ): Pair<NotificationActionKind, String>? {
        if (intent.action != ACTION_NOTIFICATION_ACTION) {
            return null
        }
        val data = intent.data ?: return null
        if (
            data.scheme != packageName ||
            data.query != null ||
            data.fragment != null ||
            data.pathSegments.size != 1
        ) {
            return null
        }
        val kind = when (data.host) {
            REPLY_URI_HOST -> NotificationActionKind.REPLY
            MARK_READ_URI_HOST -> NotificationActionKind.MARK_READ
            else -> return null
        }
        val token = data.pathSegments.single()
            .takeIf(AndroidWebPushStore::isValidNotificationActionToken)
            ?: return null
        return kind to token
    }

    fun notificationActionPendingIntent(
        context: Context,
        kind: NotificationActionKind,
        actionToken: String,
    ): PendingIntent {
        // Direct reply needs FLAG_MUTABLE: the system writes the typed text
        // into this exact intent through RemoteInput. Mark as read carries no
        // user input, so it stays immutable. Both are explicit component
        // intents to an unexported receiver of this app.
        val mutability = when (kind) {
            NotificationActionKind.REPLY -> PendingIntent.FLAG_MUTABLE
            NotificationActionKind.MARK_READ -> PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(
            context,
            0,
            notificationActionIntent(context, kind, actionToken),
            PendingIntent.FLAG_ONE_SHOT or mutability,
        )
    }

    /// Moves an armed action into the durable queue and repaints the
    /// notification so the tap is never a silent no-op.
    fun performAction(
        context: Context,
        kind: NotificationActionKind,
        actionToken: String,
        replyText: String?,
    ): Boolean {
        val store = AndroidWebPushStore(context)
        val fired = store.fireNotificationAction(actionToken, kind, replyText) ?: return false
        fired.evicted.forEach { showActionFailure(context, store, it) }
        val queued = fired.queued
        if (queued.kind == NotificationActionKind.REPLY && queued.replyText.isNullOrBlank()) {
            store.resolveNotificationAction(queued.accountId, queued.token)
            showActionStatus(context, store, queued, R.string.push_action_reply_empty)
            return true
        }
        showActionStatus(context, store, queued, queuedStatusResource(queued.kind))
        // Wakes a running Flutter engine; a dead process picks the queue up on
        // its next start instead.
        AndroidWebPushNotifier.publish(store.pendingEventCount(queued.accountId))
        return true
    }

    fun cancelNotification(context: Context, accountId: String, notificationId: Long) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val released = AndroidWebPushStore(context).revokeNotificationOpen(
            accountId,
            notificationId,
        )
        cancelNotificationRoute(
            manager,
            accountId,
            notificationId,
            released?.platformNotificationId,
        )
    }

    fun showActionFailure(
        context: Context,
        store: AndroidWebPushStore,
        action: StoredNotificationAction,
    ) {
        showActionStatus(context, store, action, failureStatusResource(action.kind))
    }

    private fun showActionStatus(
        context: Context,
        store: AndroidWebPushStore,
        action: StoredNotificationAction,
        statusResource: Int,
    ) {
        val manager = context.getSystemService(NotificationManager::class.java)
        ensureChannel(manager)
        val groupKey = accountGroupKey(action.accountId)
        // ponytail: the original subject is not kept in the action record, so
        // the status notification shows only the status line. Tapping it still
        // opens the exact room of the exact account.
        val prepared = store.prepareSystemNotification(
            accountId = action.accountId,
            notificationId = action.notificationId,
            app = DEFAULT_TALK_APP,
            type = "chat",
            objectId = action.roomToken,
        )
        cancelEvictedRoutes(manager, prepared.evicted)
        val status = context.getString(statusResource)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(context.getString(R.string.push_notification_app_name))
            .setContentText(status)
            .setStyle(Notification.BigTextStyle().bigText(status))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup(groupKey)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(notificationOpenPendingIntent(context, prepared.openToken))
            .build()
        val tag = notificationTag(groupKey, action.notificationId)
        manager.cancel(tag, LEGACY_PLATFORM_NOTIFICATION_ID)
        manager.notify(
            tag,
            prepared.platformNotificationId,
            notification,
        )
    }

    private fun queuedStatusResource(kind: NotificationActionKind): Int = when (kind) {
        NotificationActionKind.REPLY -> R.string.push_action_reply_queued
        NotificationActionKind.MARK_READ -> R.string.push_action_mark_read_queued
    }

    private fun failureStatusResource(kind: NotificationActionKind): Int = when (kind) {
        NotificationActionKind.REPLY -> R.string.push_action_reply_failed
        NotificationActionKind.MARK_READ -> R.string.push_action_mark_read_failed
    }

    private fun actionUriHost(kind: NotificationActionKind): String = when (kind) {
        NotificationActionKind.REPLY -> REPLY_URI_HOST
        NotificationActionKind.MARK_READ -> MARK_READ_URI_HOST
    }

    private fun chatActions(
        context: Context,
        store: AndroidWebPushStore,
        accountId: String,
        notificationId: Long,
        payload: AndroidWebPushPayload.Message,
    ): List<Notification.Action> {
        val roomToken = payload.objectId
        if (
            payload.app != DEFAULT_TALK_APP ||
            payload.type != "chat" ||
            roomToken == null ||
            !isValidRoomToken(roomToken)
        ) {
            return emptyList()
        }
        val replyToken = store.armNotificationAction(
            kind = NotificationActionKind.REPLY,
            accountId = accountId,
            notificationId = notificationId,
            roomToken = roomToken,
        )
        val markReadToken = store.armNotificationAction(
            kind = NotificationActionKind.MARK_READ,
            accountId = accountId,
            notificationId = notificationId,
            roomToken = roomToken,
        )
        val replyLabel = context.getString(R.string.push_action_reply)
        val replyAction = Notification.Action.Builder(
            Icon.createWithResource(context, android.R.drawable.ic_menu_send),
            replyLabel,
            notificationActionPendingIntent(context, NotificationActionKind.REPLY, replyToken),
        )
            .addRemoteInput(RemoteInput.Builder(REPLY_RESULT_KEY).setLabel(replyLabel).build())
            .setAllowGeneratedReplies(false)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setSemanticAction(Notification.Action.SEMANTIC_ACTION_REPLY)
                }
            }
            .build()
        val markReadAction = Notification.Action.Builder(
            Icon.createWithResource(context, android.R.drawable.ic_menu_view),
            context.getString(R.string.push_action_mark_read),
            notificationActionPendingIntent(
                context,
                NotificationActionKind.MARK_READ,
                markReadToken,
            ),
        )
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setSemanticAction(Notification.Action.SEMANTIC_ACTION_MARK_AS_READ)
                }
            }
            .build()
        return listOf(replyAction, markReadAction)
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
        val prepared = store.prepareSystemNotification(
            accountId = accountId,
            notificationId = notificationId,
            app = app,
            type = payload.type,
            objectId = payload.objectId,
        )
        cancelEvictedRoutes(manager, prepared.evicted)
        val pendingIntent = notificationOpenPendingIntent(context, prepared.openToken)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(
                if (app == DEFAULT_TALK_APP) {
                    context.getString(R.string.push_notification_app_name)
                } else {
                    app
                },
            )
            .setContentText(subject)
            .setStyle(Notification.BigTextStyle().bigText(subject))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup(groupKey)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .apply {
                chatActions(context, store, accountId, notificationId, payload)
                    .forEach(::addAction)
            }
            .build()
        val tag = notificationTag(groupKey, notificationId)
        manager.cancel(tag, LEGACY_PLATFORM_NOTIFICATION_ID)
        manager.notify(tag, prepared.platformNotificationId, notification)
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

    private fun cancelEvictedRoutes(
        manager: NotificationManager,
        routes: List<StoredPlatformNotificationId>,
    ) {
        routes.forEach { route ->
            cancelNotificationRoute(
                manager,
                route.accountId,
                route.notificationId,
                route.platformNotificationId,
            )
        }
    }

    private fun cancelNotificationRoute(
        manager: NotificationManager,
        accountId: String,
        notificationId: Long,
        platformNotificationId: Int?,
    ) {
        val tag = notificationTag(accountGroupKey(accountId), notificationId)
        platformNotificationId?.let { manager.cancel(tag, it) }
        manager.cancel(tag, LEGACY_PLATFORM_NOTIFICATION_ID)
        manager.activeNotifications
            .filter { it.tag == tag }
            .forEach { manager.cancel(it.tag, it.id) }
    }

    const val ACTION_NOTIFICATION_ACTION =
        "com.nkshub.nextcloudtalk.action.PUSH_NOTIFICATION_ACTION"
    const val REPLY_RESULT_KEY = "com.nkshub.nextcloudtalk.notification_reply"

    private const val CHANNEL_ID = "nextcloud_talk_messages"
    private const val OPEN_URI_HOST = "notification-open"
    private const val REPLY_URI_HOST = "notification-reply"
    private const val MARK_READ_URI_HOST = "notification-mark-read"
    private const val DEFAULT_NOTIFICATION_APP = "Nextcloud"
    private const val DEFAULT_TALK_APP = "spreed"
    private const val LEGACY_PLATFORM_NOTIFICATION_ID = 1
    private val ROOM_TOKEN_PATTERN = Regex("^[a-z0-9]{4,30}$")
}

/// Runs the reply and mark-as-read notification actions. It never talks to the
/// network: the work is queued durably and the Dart durable outbox performs it,
/// so a reply cannot bypass `referenceId` correlation and become a duplicate.
class AndroidNotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val request = AndroidSystemNotifications.notificationActionRequest(
            intent,
            context.packageName,
        ) ?: return
        val (kind, token) = request
        val replyText = if (kind == NotificationActionKind.REPLY) {
            RemoteInput.getResultsFromIntent(intent)
                ?.getCharSequence(AndroidSystemNotifications.REPLY_RESULT_KEY)
                ?.toString()
                ?.trim()
                ?.take(MAX_REPLY_LENGTH)
        } else {
            null
        }
        // ponytail: keystore-backed store work runs inline on the broadcast
        // thread; the payload is a few hundred bytes. Move to goAsync() with a
        // worker if a slow device ever trips the receiver timeout. A failure
        // here has no user-visible surface left, so it must not crash the app.
        runCatching {
            AndroidSystemNotifications.performAction(context, kind, token, replyText)
        }
    }

    private companion object {
        private const val MAX_REPLY_LENGTH = 8000
    }
}
