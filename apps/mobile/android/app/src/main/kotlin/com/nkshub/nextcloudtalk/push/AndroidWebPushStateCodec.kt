package com.nkshub.nextcloudtalk.push

import org.json.JSONArray
import org.json.JSONObject

internal object AndroidWebPushStateCodec {
    fun encode(state: AndroidWebPushState): JSONObject {
        val registrations = JSONArray()
        state.registrations.forEach { record ->
            registrations.put(
                JSONObject()
                    .put("accountId", record.accountId)
                    .put("generation", record.generation)
                    .put("instance", record.instance)
                    .put("phase", record.phase.name)
                    .putNullable("currentEndpointEventId", record.currentEndpointEventId)
                    .putNullable("committedEndpointEventId", record.committedEndpointEventId)
                    .put("createdAtMillis", record.createdAtMillis)
                    .put("updatedAtMillis", record.updatedAtMillis),
            )
        }
        val events = JSONArray()
        state.events.forEach { event ->
            events.put(
                JSONObject()
                    .put("id", event.id)
                    .put("accountId", event.accountId)
                    .put("generation", event.generation)
                    .put("type", event.type.name)
                    .put("createdAtMillis", event.createdAtMillis)
                    .put("coalescedCount", event.coalescedCount)
                    .put("stale", event.stale)
                    .put("payload", JSONObject(event.payload)),
            )
        }
        val highWatermarks = JSONObject()
        state.generationHighWatermarks.forEach(highWatermarks::put)
        val deliveryFingerprints = JSONArray()
        state.deliveryFingerprints.forEach { fingerprint ->
            deliveryFingerprints.put(
                JSONObject()
                    .put("accountId", fingerprint.accountId)
                    .put("value", fingerprint.value)
                    .put("expiresAtMillis", fingerprint.expiresAtMillis),
            )
        }
        return JSONObject()
            .put("schema", STATE_SCHEMA)
            .put("registrations", registrations)
            .put("events", events)
            .put("generationHighWatermarks", highWatermarks)
            .put("deliveryFingerprints", deliveryFingerprints)
    }

    fun decode(json: JSONObject): AndroidWebPushState {
        if (json.getInt("schema") != STATE_SCHEMA) {
            throw PushStoreException("unsupported_state_schema")
        }
        val registrations = json.getJSONArray("registrations").mapObjects { item ->
            PushRegistrationRecord(
                accountId = item.getString("accountId"),
                generation = item.getLong("generation"),
                instance = item.getString("instance"),
                phase = PushRegistrationPhase.valueOf(item.getString("phase")),
                currentEndpointEventId = item.nullableString("currentEndpointEventId"),
                committedEndpointEventId = item.nullableString("committedEndpointEventId"),
                createdAtMillis = item.getLong("createdAtMillis"),
                updatedAtMillis = item.getLong("updatedAtMillis"),
            )
        }.toMutableList()
        val events = json.getJSONArray("events").mapObjects { item ->
            StoredPushEvent(
                id = item.getString("id"),
                accountId = item.getString("accountId"),
                generation = item.getLong("generation"),
                type = StoredPushEventType.valueOf(item.getString("type")),
                createdAtMillis = item.getLong("createdAtMillis"),
                coalescedCount = item.getInt("coalescedCount"),
                stale = item.getBoolean("stale"),
                payload = item.getJSONObject("payload").toMutableMap(),
            )
        }.toMutableList()
        val highWatermarks = mutableMapOf<String, Long>()
        val highWatermarkJson = json.getJSONObject("generationHighWatermarks")
        highWatermarkJson.keys().forEach { accountId ->
            highWatermarks[accountId] = highWatermarkJson.getLong(accountId)
        }
        return AndroidWebPushState(
            registrations = registrations,
            events = events,
            generationHighWatermarks = highWatermarks,
            deliveryFingerprints = decodeDeliveryFingerprints(json),
        )
    }

    private fun decodeDeliveryFingerprints(
        json: JSONObject,
    ): MutableList<StoredPushDeliveryFingerprint> {
        if (!json.has("deliveryFingerprints") || json.isNull("deliveryFingerprints")) {
            return mutableListOf()
        }
        val array = json.getJSONArray("deliveryFingerprints")
        if (array.length() > AndroidWebPushDeliveryLedger.MAX_TOTAL) {
            throw PushStoreException("delivery_fingerprint_store_too_large")
        }
        val fingerprints = array.mapObjects { item ->
            StoredPushDeliveryFingerprint(
                accountId = item.getString("accountId"),
                value = item.getString("value"),
                expiresAtMillis = item.getLong("expiresAtMillis"),
            )
        }
        if (
            fingerprints.any {
                it.accountId.isBlank() ||
                    it.accountId.length > MAX_ACCOUNT_ID_LENGTH ||
                    !PushDeliveryFingerprint.isValid(it.value) ||
                    it.expiresAtMillis < 0
            } ||
            fingerprints.groupingBy { it.accountId }.eachCount().values.any {
                it > AndroidWebPushDeliveryLedger.MAX_PER_ACCOUNT
            } ||
            fingerprints.map { it.accountId to it.value }.toSet().size != fingerprints.size
        ) {
            throw PushStoreException("invalid_delivery_fingerprint_state")
        }
        return fingerprints.toMutableList()
    }

    private const val STATE_SCHEMA = 1
    private const val MAX_ACCOUNT_ID_LENGTH = 256
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

private fun JSONObject.toMutableMap(): MutableMap<String, Any?> {
    val result = mutableMapOf<String, Any?>()
    keys().forEach { key -> result[key] = jsonValueToKotlin(get(key)) }
    return result
}

private fun jsonValueToKotlin(value: Any?): Any? {
    return when (value) {
        JSONObject.NULL -> null
        is JSONObject -> value.toMutableMap()
        is JSONArray -> List(value.length()) { index -> jsonValueToKotlin(value.get(index)) }
        else -> value
    }
}
