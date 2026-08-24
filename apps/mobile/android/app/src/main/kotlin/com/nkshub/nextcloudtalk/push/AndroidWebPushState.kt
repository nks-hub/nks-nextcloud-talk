package com.nkshub.nextcloudtalk.push

import java.util.UUID

internal enum class PushRegistrationPhase {
    REGISTERING,
    ACTIVE,
    SERVER_REVOKE_PENDING,
    UNREGISTERED,
    NATIVE_UNREGISTERING,
    RETIRED,
}

internal enum class StoredPushEventType(val wireName: String) {
    ENDPOINT("endpoint"),
    ACTIVATION("activation"),
    REGISTRATION_FAILED("registrationFailed"),
    UNREGISTERED("unregistered"),
    TEMPORARY_UNAVAILABLE("temporaryUnavailable"),
}

internal data class PushRegistrationRecord(
    val accountId: String,
    val generation: Long,
    val instance: String,
    var phase: PushRegistrationPhase,
    var currentEndpointEventId: String? = null,
    var committedEndpointEventId: String? = null,
    val createdAtMillis: Long,
    var updatedAtMillis: Long,
) {
    override fun toString(): String {
        return "PushRegistrationRecord(accountId=<redacted>, generation=$generation, " +
            "instance=<redacted>, phase=$phase)"
    }
}

internal data class StoredPushEvent(
    val id: String,
    val accountId: String,
    val generation: Long,
    val type: StoredPushEventType,
    val createdAtMillis: Long,
    var coalescedCount: Int,
    var stale: Boolean,
    val payload: MutableMap<String, Any?>,
) {
    fun toChannelMap(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>(
            "id" to id,
            "accountId" to accountId,
            "generation" to generation,
            "type" to type.wireName,
            "createdAtMillis" to createdAtMillis,
            "coalescedCount" to coalescedCount,
            "stale" to stale,
        )
        result.putAll(payload)
        return result
    }

    override fun toString(): String {
        return "StoredPushEvent(id=<redacted>, accountId=<redacted>, generation=$generation, " +
            "type=$type, coalescedCount=$coalescedCount, stale=$stale, payload=<redacted>)"
    }
}

internal data class AndroidWebPushState(
    val registrations: MutableList<PushRegistrationRecord> = mutableListOf(),
    val events: MutableList<StoredPushEvent> = mutableListOf(),
    val generationHighWatermarks: MutableMap<String, Long> = mutableMapOf(),
) {
    override fun toString(): String {
        return "AndroidWebPushState(registrations=${registrations.size}, events=${events.size}, " +
            "accounts=${generationHighWatermarks.size})"
    }
}

internal data class BeginRegistrationResult(
    val record: PushRegistrationRecord,
    val created: Boolean,
)

internal data class CommitEndpointResult(
    val serverRevokeGenerations: List<Long>,
    val nativeUnregisterInstances: List<String>,
)

internal class AndroidWebPushStateMachine(
    private val newId: () -> String = { UUID.randomUUID().toString() },
) {
    fun beginRegistration(
        state: AndroidWebPushState,
        accountId: String,
        generation: Long,
        instance: String,
        nowMillis: Long,
    ): BeginRegistrationResult {
        pruneRetired(state, nowMillis)
        val highWatermark = state.generationHighWatermarks[accountId]
        if (highWatermark != null && generation < highWatermark) {
            throw PushStateException("stale_generation")
        }

        val existing = state.registrations.firstOrNull {
            it.accountId == accountId &&
                it.generation == generation &&
                it.phase != PushRegistrationPhase.RETIRED
        }
        if (existing != null) {
            if (
                existing.phase == PushRegistrationPhase.SERVER_REVOKE_PENDING ||
                existing.phase == PushRegistrationPhase.NATIVE_UNREGISTERING
            ) {
                throw PushStateException("generation_retiring")
            }
            if (existing.phase == PushRegistrationPhase.UNREGISTERED) {
                throw PushStateException("generation_unregistered")
            }
            return BeginRegistrationResult(existing, created = false)
        }
        if (highWatermark == generation) {
            throw PushStateException("generation_already_retired")
        }

        val activeAccounts = state.registrations
            .asSequence()
            .filter { it.phase != PushRegistrationPhase.RETIRED }
            .map { it.accountId }
            .toSet()
        if (accountId !in activeAccounts && activeAccounts.size >= MAX_ACTIVE_ACCOUNTS) {
            throw PushStateException("account_limit_reached")
        }

        state.generationHighWatermarks[accountId] = generation
        state.registrations
            .filter {
                it.accountId == accountId &&
                    it.phase != PushRegistrationPhase.ACTIVE &&
                    it.phase != PushRegistrationPhase.SERVER_REVOKE_PENDING &&
                    it.phase != PushRegistrationPhase.RETIRED
            }
            .forEach { markNativeUnregistering(state, it, nowMillis) }

        val record = PushRegistrationRecord(
            accountId = accountId,
            generation = generation,
            instance = instance,
            phase = PushRegistrationPhase.REGISTERING,
            createdAtMillis = nowMillis,
            updatedAtMillis = nowMillis,
        )
        state.registrations.add(record)
        return BeginRegistrationResult(record, created = true)
    }

    fun appendEndpoint(
        state: AndroidWebPushState,
        instance: String,
        endpoint: Map<String, Any?>,
        nowMillis: Long,
    ): StoredPushEvent? {
        val record = callbackRecord(state, instance) ?: return null
        val previous = removeCoalescedEvent(state, record, StoredPushEventType.ENDPOINT)
        ensureEventCapacity(state)
        val stale = record.phase == PushRegistrationPhase.SERVER_REVOKE_PENDING
        val event = StoredPushEvent(
            id = newId(),
            accountId = record.accountId,
            generation = record.generation,
            type = StoredPushEventType.ENDPOINT,
            createdAtMillis = nowMillis,
            coalescedCount = (previous?.coalescedCount ?: 0) + 1,
            stale = stale,
            payload = mutableMapOf("endpoint" to endpoint),
        )
        state.events.add(event)
        record.currentEndpointEventId = event.id.takeUnless { stale }
        record.updatedAtMillis = nowMillis
        return event
    }

    fun appendActivation(
        state: AndroidWebPushState,
        instance: String,
        payload: Map<String, Any?>,
        nowMillis: Long,
    ): StoredPushEvent? {
        val record = callbackRecord(state, instance) ?: return null
        val previous = removeCoalescedEvent(state, record, StoredPushEventType.ACTIVATION)
        ensureEventCapacity(state)
        return StoredPushEvent(
            id = newId(),
            accountId = record.accountId,
            generation = record.generation,
            type = StoredPushEventType.ACTIVATION,
            createdAtMillis = nowMillis,
            coalescedCount = (previous?.coalescedCount ?: 0) + 1,
            stale = false,
            payload = payload.toMutableMap(),
        ).also(state.events::add)
    }

    fun appendRegistrationFailed(
        state: AndroidWebPushState,
        instance: String,
        reason: String,
        nowMillis: Long,
    ): StoredPushEvent? {
        return appendSimpleEvent(
            state,
            instance,
            StoredPushEventType.REGISTRATION_FAILED,
            mutableMapOf("failureReason" to reason),
            nowMillis,
        )
    }

    fun appendTemporaryUnavailable(
        state: AndroidWebPushState,
        instance: String,
        nowMillis: Long,
    ): StoredPushEvent? {
        return appendSimpleEvent(
            state,
            instance,
            StoredPushEventType.TEMPORARY_UNAVAILABLE,
            mutableMapOf(),
            nowMillis,
        )
    }

    fun appendUnregistered(
        state: AndroidWebPushState,
        instance: String,
        nowMillis: Long,
    ): StoredPushEvent? {
        val event = appendSimpleEvent(
            state,
            instance,
            StoredPushEventType.UNREGISTERED,
            mutableMapOf(),
            nowMillis,
        ) ?: return null
        state.registrations.first { it.instance == instance }.apply {
            phase = PushRegistrationPhase.UNREGISTERED
            currentEndpointEventId = null
            updatedAtMillis = nowMillis
        }
        return event
    }

    fun commitEndpoint(
        state: AndroidWebPushState,
        accountId: String,
        generation: Long,
        eventId: String,
        nowMillis: Long,
    ): CommitEndpointResult {
        val highestGeneration = state.generationHighWatermarks[accountId]
        if (highestGeneration != generation) {
            throw PushStateException("stale_generation")
        }
        val record = state.registrations.firstOrNull {
            it.accountId == accountId &&
                it.generation == generation &&
                (
                    it.phase == PushRegistrationPhase.REGISTERING ||
                        it.phase == PushRegistrationPhase.ACTIVE
                )
        } ?: throw PushStateException("registration_not_found")

        if (record.committedEndpointEventId != eventId) {
            if (record.currentEndpointEventId != eventId) {
                throw PushStateException("stale_endpoint_event")
            }
            val event = state.events.firstOrNull {
                it.id == eventId &&
                    it.accountId == accountId &&
                    it.generation == generation &&
                    it.type == StoredPushEventType.ENDPOINT &&
                    !it.stale
            } ?: throw PushStateException("endpoint_event_not_found")
            record.phase = PushRegistrationPhase.ACTIVE
            record.currentEndpointEventId = null
            record.committedEndpointEventId = event.id
            record.updatedAtMillis = nowMillis
        }

        state.registrations
            .filter {
                it.accountId == accountId &&
                    it.instance != record.instance &&
                    it.phase != PushRegistrationPhase.RETIRED
            }
            .forEach {
                when (it.phase) {
                    PushRegistrationPhase.ACTIVE,
                    PushRegistrationPhase.SERVER_REVOKE_PENDING,
                    -> markServerRevokePending(state, it, nowMillis)
                    PushRegistrationPhase.REGISTERING,
                    PushRegistrationPhase.UNREGISTERED,
                    PushRegistrationPhase.NATIVE_UNREGISTERING,
                    -> markNativeUnregistering(state, it, nowMillis)
                    PushRegistrationPhase.RETIRED -> Unit
                }
            }
        return CommitEndpointResult(
            serverRevokeGenerations = pendingServerRevocations(state, accountId),
            nativeUnregisterInstances = pendingNativeUnregistrations(state),
        )
    }

    fun retireAfterServerRevocation(
        state: AndroidWebPushState,
        accountId: String,
        generation: Long,
        nowMillis: Long,
    ): List<String> {
        val record = state.registrations.firstOrNull {
            it.accountId == accountId &&
                it.generation == generation
        } ?: return pendingNativeUnregistrations(state)
        when (record.phase) {
            PushRegistrationPhase.SERVER_REVOKE_PENDING,
            PushRegistrationPhase.UNREGISTERED,
            -> markNativeUnregistering(state, record, nowMillis)
            PushRegistrationPhase.NATIVE_UNREGISTERING,
            PushRegistrationPhase.RETIRED,
            -> Unit
            PushRegistrationPhase.REGISTERING,
            PushRegistrationPhase.ACTIVE,
            -> throw PushStateException("server_revocation_not_pending")
        }
        return pendingNativeUnregistrations(state)
    }

    fun markRetired(
        state: AndroidWebPushState,
        instance: String,
        nowMillis: Long,
    ) {
        state.registrations.firstOrNull { it.instance == instance }?.apply {
            phase = PushRegistrationPhase.RETIRED
            currentEndpointEventId = null
            updatedAtMillis = nowMillis
            markEventsStale(state, this)
        }
    }

    fun pendingNativeUnregistrations(state: AndroidWebPushState): List<String> {
        return state.registrations
            .filter { it.phase == PushRegistrationPhase.NATIVE_UNREGISTERING }
            .map { it.instance }
    }

    fun pendingServerRevocations(
        state: AndroidWebPushState,
        accountId: String,
    ): List<Long> {
        return state.registrations
            .filter {
                it.accountId == accountId &&
                    it.phase == PushRegistrationPhase.SERVER_REVOKE_PENDING
            }
            .map { it.generation }
            .distinct()
            .sorted()
    }

    fun drain(
        state: AndroidWebPushState,
        accountId: String,
        limit: Int,
    ): List<StoredPushEvent> {
        return state.events
            .asSequence()
            .filter { it.accountId == accountId }
            .sortedWith(compareBy<StoredPushEvent> { it.createdAtMillis }.thenBy { it.id })
            .take(limit)
            .toList()
    }

    fun acknowledge(
        state: AndroidWebPushState,
        accountId: String,
        eventIds: Set<String>,
    ): Int {
        val protectedEndpointIds = state.registrations
            .mapNotNull { it.currentEndpointEventId }
            .toSet()
        if (state.events.any {
                it.accountId == accountId &&
                    it.id in eventIds &&
                    it.id in protectedEndpointIds
            }
        ) {
            throw PushStateException("endpoint_not_committed")
        }
        val before = state.events.size
        state.events.removeAll { it.accountId == accountId && it.id in eventIds }
        return before - state.events.size
    }

    fun pendingEventCount(state: AndroidWebPushState, accountId: String?): Int {
        return if (accountId == null) {
            state.events.size
        } else {
            state.events.count { it.accountId == accountId }
        }
    }

    private fun appendSimpleEvent(
        state: AndroidWebPushState,
        instance: String,
        type: StoredPushEventType,
        payload: MutableMap<String, Any?>,
        nowMillis: Long,
    ): StoredPushEvent? {
        val record = callbackRecord(state, instance) ?: return null
        val previous = removeCoalescedEvent(state, record, type)
        ensureEventCapacity(state)
        return StoredPushEvent(
            id = newId(),
            accountId = record.accountId,
            generation = record.generation,
            type = type,
            createdAtMillis = nowMillis,
            coalescedCount = (previous?.coalescedCount ?: 0) + 1,
            stale = false,
            payload = payload,
        ).also(state.events::add)
    }

    private fun callbackRecord(
        state: AndroidWebPushState,
        instance: String,
    ): PushRegistrationRecord? {
        return state.registrations.firstOrNull {
            it.instance == instance &&
                (
                    it.phase == PushRegistrationPhase.REGISTERING ||
                        it.phase == PushRegistrationPhase.ACTIVE ||
                        it.phase == PushRegistrationPhase.SERVER_REVOKE_PENDING
                )
        }
    }

    private fun removeCoalescedEvent(
        state: AndroidWebPushState,
        record: PushRegistrationRecord,
        type: StoredPushEventType,
    ): StoredPushEvent? {
        val previous = state.events.lastOrNull {
                it.accountId == record.accountId &&
                it.generation == record.generation &&
                it.type == type
        }
        if (previous != null) {
            state.events.remove(previous)
        }
        return previous
    }

    private fun ensureEventCapacity(state: AndroidWebPushState) {
        if (state.events.size < MAX_STORED_EVENTS) {
            return
        }
        val evictable = state.events
            .asSequence()
            .filter {
                it.type != StoredPushEventType.ENDPOINT &&
                    it.type != StoredPushEventType.ACTIVATION
            }
            .minWithOrNull(compareBy<StoredPushEvent> { it.createdAtMillis }.thenBy { it.id })
        if (evictable != null) {
            state.events.remove(evictable)
            return
        }
        throw PushStateException("event_backlog_full")
    }

    private fun markServerRevokePending(
        state: AndroidWebPushState,
        record: PushRegistrationRecord,
        nowMillis: Long,
    ) {
        record.phase = PushRegistrationPhase.SERVER_REVOKE_PENDING
        record.currentEndpointEventId = null
        record.updatedAtMillis = nowMillis
        markEventsStale(state, record)
    }

    private fun markNativeUnregistering(
        state: AndroidWebPushState,
        record: PushRegistrationRecord,
        nowMillis: Long,
    ) {
        record.phase = PushRegistrationPhase.NATIVE_UNREGISTERING
        record.currentEndpointEventId = null
        record.updatedAtMillis = nowMillis
        markEventsStale(state, record)
    }

    private fun markEventsStale(
        state: AndroidWebPushState,
        record: PushRegistrationRecord,
    ) {
        state.events
            .filter {
                it.accountId == record.accountId &&
                    it.generation == record.generation
            }
            .forEach { it.stale = true }
    }

    private fun pruneRetired(state: AndroidWebPushState, nowMillis: Long) {
        val cutoff = nowMillis - RETIRED_RETENTION_MILLIS
        val removableInstances = state.registrations
            .filter {
                it.phase == PushRegistrationPhase.RETIRED &&
                    it.updatedAtMillis < cutoff &&
                    state.events.none { event ->
                        event.accountId == it.accountId && event.generation == it.generation
                    }
            }
            .map { it.instance }
            .toSet()
        state.registrations.removeAll { it.instance in removableInstances }
    }

    companion object {
        internal const val MAX_ACTIVE_ACCOUNTS = 32
        internal const val MAX_STORED_EVENTS = 384
        internal const val RETIRED_RETENTION_MILLIS = 7L * 24L * 60L * 60L * 1000L
    }
}

internal class PushStateException(val code: String) : IllegalStateException(code)
