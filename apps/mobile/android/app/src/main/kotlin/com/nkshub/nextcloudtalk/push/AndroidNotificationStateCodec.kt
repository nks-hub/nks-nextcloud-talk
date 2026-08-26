package com.nkshub.nextcloudtalk.push

import org.json.JSONArray
import org.json.JSONObject

internal class AndroidNotificationStateCodec(
    private val validateOpen: (String, Long, String, String?, String?) -> Unit,
    private val validateAction: (StoredNotificationAction) -> Unit,
) {
    fun encode(state: AndroidNotificationOpenState): JSONObject {
        val notificationOpens = JSONArray()
        state.notificationOpens.forEach { open ->
            notificationOpens.put(
                JSONObject()
                    .put("token", open.token)
                    .put("accountId", open.accountId)
                    .put("notificationId", open.notificationId)
                    .put("app", open.app)
                    .putNullable("type", open.type)
                    .putNullable("objectId", open.objectId)
                    .put("createdAtMillis", open.createdAtMillis),
            )
        }
        val notificationActions = JSONArray()
        state.notificationActions.forEach { action ->
            notificationActions.put(
                JSONObject()
                    .put("token", action.token)
                    .put("kind", action.kind.name)
                    .put("accountId", action.accountId)
                    .put("notificationId", action.notificationId)
                    .put("roomToken", action.roomToken)
                    .putNullable("replyText", action.replyText)
                    .put("queued", action.queued)
                    .put("attempts", action.attempts)
                    .put("createdAtMillis", action.createdAtMillis),
            )
        }
        val platformNotificationIds = JSONArray()
        state.platformNotificationIds.forEach { route ->
            platformNotificationIds.put(
                JSONObject()
                    .put("accountId", route.accountId)
                    .put("notificationId", route.notificationId)
                    .put("platformNotificationId", route.platformNotificationId)
                    .put("createdAtMillis", route.createdAtMillis)
                    .put("updatedAtMillis", route.updatedAtMillis),
            )
        }
        return JSONObject()
            .put("schema", CURRENT_SCHEMA)
            .put("notificationOpens", notificationOpens)
            .put("notificationActions", notificationActions)
            .put("platformNotificationIds", platformNotificationIds)
    }

    fun decode(json: JSONObject): AndroidNotificationOpenState {
        val schema = json.getInt("schema")
        if (schema !in SUPPORTED_SCHEMAS) {
            throw PushStoreException("unsupported_notification_open_state_schema")
        }
        return AndroidNotificationOpenState(
            notificationOpens = decodeOpens(json).toMutableList(),
            notificationActions = decodeActions(json).toMutableList(),
            platformNotificationIds = decodePlatformIds(json, schema).toMutableList(),
        )
    }

    private fun decodeOpens(json: JSONObject): List<StoredNotificationOpen> {
        val array = json.getJSONArray("notificationOpens")
        if (array.length() > AndroidWebPushStateMachine.MAX_NOTIFICATION_OPENS) {
            throw PushStoreException("notification_open_store_too_large")
        }
        val opens = array.mapObjects { item ->
            val open = StoredNotificationOpen(
                token = item.getString("token"),
                accountId = item.getString("accountId"),
                notificationId = item.getLong("notificationId"),
                app = item.getString("app"),
                type = item.nullableString("type"),
                objectId = item.nullableString("objectId"),
                createdAtMillis = item.getLong("createdAtMillis"),
            )
            validateOpen(
                open.accountId,
                open.notificationId,
                open.app,
                open.type,
                open.objectId,
            )
            if (
                !AndroidWebPushStore.isValidNotificationOpenToken(open.token) ||
                open.createdAtMillis < 0
            ) {
                throw PushStoreException("invalid_notification_open_state")
            }
            open
        }
        if (
            opens.map { it.token }.toSet().size != opens.size ||
            opens.map { it.accountId to it.notificationId }.toSet().size != opens.size
        ) {
            throw PushStoreException("invalid_notification_open_state")
        }
        return opens
    }

    private fun decodeActions(json: JSONObject): List<StoredNotificationAction> {
        if (json.isNull("notificationActions")) {
            return emptyList()
        }
        val array = json.getJSONArray("notificationActions")
        if (array.length() > AndroidWebPushStateMachine.MAX_NOTIFICATION_ACTIONS) {
            throw PushStoreException("notification_action_store_too_large")
        }
        val actions = array.mapObjects { item ->
            val action = StoredNotificationAction(
                token = item.getString("token"),
                kind = NotificationActionKind.parse(item.getString("kind"))
                    ?: throw PushStoreException("invalid_notification_action_state"),
                accountId = item.getString("accountId"),
                notificationId = item.getLong("notificationId"),
                roomToken = item.getString("roomToken"),
                replyText = item.nullableString("replyText"),
                queued = item.getBoolean("queued"),
                attempts = item.getInt("attempts"),
                createdAtMillis = item.getLong("createdAtMillis"),
            )
            validateAction(action)
            action
        }
        if (actions.map { it.token }.toSet().size != actions.size) {
            throw PushStoreException("invalid_notification_action_state")
        }
        return actions
    }

    private fun decodePlatformIds(
        json: JSONObject,
        schema: Int,
    ): List<StoredPlatformNotificationId> {
        if (schema < CURRENT_SCHEMA) {
            return emptyList()
        }
        val array = json.getJSONArray("platformNotificationIds")
        if (array.length() > AndroidPlatformNotificationIdLedger.MAX_TOTAL_ROUTES) {
            throw PushStoreException("notification_route_store_too_large")
        }
        val routes = array.mapObjects { item ->
            StoredPlatformNotificationId(
                accountId = item.getString("accountId"),
                notificationId = item.getLong("notificationId"),
                platformNotificationId = item.getInt("platformNotificationId"),
                createdAtMillis = item.getLong("createdAtMillis"),
                updatedAtMillis = item.getLong("updatedAtMillis"),
            ).also(::validatePlatformId)
        }
        if (
            routes.map { it.route }.toSet().size != routes.size ||
            routes.map { it.platformNotificationId }.toSet().size != routes.size ||
            routes.groupingBy { it.accountId }.eachCount().values.any {
                it > AndroidPlatformNotificationIdLedger.MAX_ROUTES_PER_ACCOUNT
            }
        ) {
            throw PushStoreException("invalid_notification_route_state")
        }
        return routes
    }

    private fun validatePlatformId(route: StoredPlatformNotificationId) {
        if (
            route.accountId.isBlank() || route.accountId.length > MAX_ACCOUNT_ID_LENGTH ||
            route.notificationId <= 0 ||
            route.platformNotificationId < AndroidPlatformNotificationIdLedger.MIN_PLATFORM_ID ||
            route.createdAtMillis < 0 || route.updatedAtMillis < route.createdAtMillis
        ) {
            throw PushStoreException("invalid_notification_route_state")
        }
    }

    companion object {
        private const val CURRENT_SCHEMA = 3
        private const val MAX_ACCOUNT_ID_LENGTH = 256
        private val SUPPORTED_SCHEMAS = setOf(1, 2, 3)
    }
}

private fun JSONObject.putNullable(key: String, value: String?): JSONObject {
    return put(key, value ?: JSONObject.NULL)
}

private fun JSONObject.nullableString(key: String): String? {
    return if (isNull(key)) null else getString(key)
}

private fun <T> JSONArray.mapObjects(transform: (JSONObject) -> T): List<T> {
    return List(length()) { index -> transform(getJSONObject(index)) }
}
