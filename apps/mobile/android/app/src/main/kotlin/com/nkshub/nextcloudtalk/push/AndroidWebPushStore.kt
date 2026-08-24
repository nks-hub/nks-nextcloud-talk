package com.nkshub.nextcloudtalk.push

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class StoredRegistrationRequest(
    val result: BeginRegistrationResult,
    val pendingNativeUnregistrations: List<String>,
)

internal data class StoredEventResult(
    val stored: Boolean,
    val totalPendingCount: Int,
)

internal class AndroidWebPushStore(context: Context) {
    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )
    private val stateMachine = AndroidWebPushStateMachine()

    fun beginRegistration(
        accountId: String,
        generation: Long,
        instance: String,
    ): StoredRegistrationRequest = mutate { state ->
        val result = stateMachine.beginRegistration(
            state,
            accountId,
            generation,
            instance,
            System.currentTimeMillis(),
        )
        StoredRegistrationRequest(
            result = result,
            pendingNativeUnregistrations = stateMachine.pendingNativeUnregistrations(state),
        )
    }

    fun storeEndpoint(
        instance: String,
        url: String,
        publicKey: String?,
        authSecret: String?,
        temporary: Boolean,
    ): StoredEventResult {
        validateEndpoint(url, publicKey, authSecret)
        return mutate { state ->
            val event = stateMachine.appendEndpoint(
                state,
                instance,
                mapOf(
                    "url" to url,
                    "publicKey" to publicKey,
                    "authSecret" to authSecret,
                    "temporary" to temporary,
                ),
                System.currentTimeMillis(),
            )
            StoredEventResult(
                stored = event != null,
                totalPendingCount = stateMachine.pendingEventCount(state, null),
            )
        }
    }

    fun storeActivation(
        instance: String,
        content: ByteArray,
        decrypted: Boolean,
    ): StoredEventResult = mutate { state ->
        val oversized = content.size > MAX_PUSH_PAYLOAD_BYTES
        val payload = mutableMapOf<String, Any?>(
            "decrypted" to decrypted,
            "payloadOversized" to oversized,
            "originalSize" to content.size,
        )
        if (!oversized) {
            payload["content"] = Base64.encodeToString(content, Base64.NO_WRAP)
        }
        val event = stateMachine.appendActivation(
            state,
            instance,
            payload,
            System.currentTimeMillis(),
        )
        StoredEventResult(
            stored = event != null,
            totalPendingCount = stateMachine.pendingEventCount(state, null),
        )
    }

    fun storeRegistrationFailed(instance: String, reason: String): StoredEventResult {
        return mutate { state ->
            val event = stateMachine.appendRegistrationFailed(
                state,
                instance,
                reason,
                System.currentTimeMillis(),
            )
            StoredEventResult(
                stored = event != null,
                totalPendingCount = stateMachine.pendingEventCount(state, null),
            )
        }
    }

    fun storeUnregistered(instance: String): StoredEventResult = mutate { state ->
        val event = stateMachine.appendUnregistered(
            state,
            instance,
            System.currentTimeMillis(),
        )
        StoredEventResult(
            stored = event != null,
            totalPendingCount = stateMachine.pendingEventCount(state, null),
        )
    }

    fun storeTemporaryUnavailable(instance: String): StoredEventResult = mutate { state ->
        val event = stateMachine.appendTemporaryUnavailable(
            state,
            instance,
            System.currentTimeMillis(),
        )
        StoredEventResult(
            stored = event != null,
            totalPendingCount = stateMachine.pendingEventCount(state, null),
        )
    }

    fun commitEndpoint(
        accountId: String,
        generation: Long,
        eventId: String,
    ): CommitEndpointResult = mutate { state ->
        stateMachine.commitEndpoint(
            state,
            accountId,
            generation,
            eventId,
            System.currentTimeMillis(),
        )
    }

    fun retireAfterServerRevocation(
        accountId: String,
        generation: Long,
    ): List<String> = mutate { state ->
        stateMachine.retireAfterServerRevocation(
            state,
            accountId,
            generation,
            System.currentTimeMillis(),
        )
    }

    fun pendingNativeUnregistrations(): List<String> = read { state ->
        stateMachine.pendingNativeUnregistrations(state)
    }

    fun markRetired(instance: String) {
        mutate { state ->
            stateMachine.markRetired(state, instance, System.currentTimeMillis())
        }
    }

    fun drain(accountId: String, limit: Int): List<Map<String, Any?>> = read { state ->
        stateMachine.drain(state, accountId, limit).map(StoredPushEvent::toChannelMap)
    }

    fun acknowledge(accountId: String, eventIds: Set<String>): Int = mutate { state ->
        stateMachine.acknowledge(state, accountId, eventIds)
    }

    fun pendingEventCount(accountId: String?): Int = read { state ->
        stateMachine.pendingEventCount(state, accountId)
    }

    private fun validateEndpoint(
        url: String,
        publicKey: String?,
        authSecret: String?,
    ) {
        if (url.length > MAX_ENDPOINT_LENGTH) {
            throw PushStoreException("endpoint_too_large")
        }
        val uri = runCatching { URI(url) }.getOrNull()
        if (
            uri == null ||
            !uri.scheme.equals("https", ignoreCase = true) ||
            uri.host.isNullOrBlank() ||
            uri.userInfo != null ||
            uri.fragment != null
        ) {
            throw PushStoreException("invalid_endpoint")
        }
        if (
            (publicKey != null && publicKey.length > MAX_KEY_MATERIAL_LENGTH) ||
            (authSecret != null && authSecret.length > MAX_KEY_MATERIAL_LENGTH)
        ) {
            throw PushStoreException("endpoint_key_too_large")
        }
    }

    private fun <T> read(block: (AndroidWebPushState) -> T): T = synchronized(STORE_LOCK) {
        block(readState())
    }

    private fun <T> mutate(block: (AndroidWebPushState) -> T): T = synchronized(STORE_LOCK) {
        val state = readState()
        val result = block(state)
        writeState(state)
        result
    }

    private fun readState(): AndroidWebPushState {
        val envelopeText = preferences.getString(STATE_KEY, null) ?: return AndroidWebPushState()
        try {
            val envelope = JSONObject(envelopeText)
            if (envelope.getInt("version") != ENVELOPE_VERSION) {
                throw PushStoreException("unsupported_store_version")
            }
            val key = getKey(create = false)
            val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
            val iv = Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)
            val ciphertext = Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            cipher.updateAAD(aad())
            val plaintext = cipher.doFinal(ciphertext)
            return decodeState(JSONObject(String(plaintext, StandardCharsets.UTF_8)))
        } catch (error: PushStoreException) {
            throw error
        } catch (error: Exception) {
            throw PushStoreException("store_decryption_failed", error)
        }
    }

    private fun writeState(state: AndroidWebPushState) {
        try {
            val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getKey(create = true))
            cipher.updateAAD(aad())
            val plaintext = encodeState(state).toString().toByteArray(StandardCharsets.UTF_8)
            val ciphertext = cipher.doFinal(plaintext)
            val envelope = JSONObject()
                .put("version", ENVELOPE_VERSION)
                .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            if (!preferences.edit().putString(STATE_KEY, envelope.toString()).commit()) {
                throw PushStoreException("store_commit_failed")
            }
        } catch (error: PushStoreException) {
            throw error
        } catch (error: Exception) {
            throw PushStoreException("store_encryption_failed", error)
        }
    }

    private fun getKey(create: Boolean): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) {
            return existing
        }
        if (!create) {
            throw PushStoreException("store_key_missing")
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            KEYSTORE_PROVIDER,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun aad(): ByteArray {
        return "${applicationContext.packageName}:$STATE_KEY:$ENVELOPE_VERSION"
            .toByteArray(StandardCharsets.UTF_8)
    }

    private fun encodeState(state: AndroidWebPushState): JSONObject {
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
        return JSONObject()
            .put("schema", STATE_SCHEMA)
            .put("registrations", registrations)
            .put("events", events)
            .put("generationHighWatermarks", highWatermarks)
    }

    private fun decodeState(json: JSONObject): AndroidWebPushState {
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
        return AndroidWebPushState(registrations, events, highWatermarks)
    }

    companion object {
        private val STORE_LOCK = Any()
        private val SECURE_RANDOM = SecureRandom()

        private const val PREFERENCES_NAME = "android_web_push_state"
        private const val STATE_KEY = "encrypted_state"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "com.nkshub.nextcloudtalk.android_web_push.v1"
        private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val ENVELOPE_VERSION = 1
        private const val STATE_SCHEMA = 1
        private const val MAX_PUSH_PAYLOAD_BYTES = 64 * 1024
        private const val MAX_ENDPOINT_LENGTH = 8 * 1024
        private const val MAX_KEY_MATERIAL_LENGTH = 512

        fun newOpaqueInstance(): String {
            val random = ByteArray(24).also(SECURE_RANDOM::nextBytes)
            return "nks1_${Base64.encodeToString(random, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)}"
        }
    }
}

internal class PushStoreException(
    val code: String,
    cause: Throwable? = null,
) : IllegalStateException(code, cause)

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
