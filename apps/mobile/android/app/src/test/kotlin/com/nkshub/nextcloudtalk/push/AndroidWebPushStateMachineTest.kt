package com.nkshub.nextcloudtalk.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidWebPushStateMachineTest {
    private var nextId = 0
    private val machine = AndroidWebPushStateMachine { "event-${++nextId}" }

    @Test
    fun newGenerationUsesMakeBeforeBreakAndWaitsForServerRevocation() {
        val state = AndroidWebPushState()
        val old = machine.beginRegistration(state, "account", 1, "instance-1", 1).record
        val oldEndpoint = machine.appendEndpoint(
            state,
            old.instance,
            endpoint("old"),
            2,
        )!!
        machine.commitEndpoint(state, "account", 1, oldEndpoint.id, 3)

        val replacement = machine.beginRegistration(
            state,
            "account",
            2,
            "instance-2",
            4,
        ).record

        assertEquals(PushRegistrationPhase.ACTIVE, old.phase)
        assertEquals(PushRegistrationPhase.REGISTERING, replacement.phase)

        val replacementEndpoint = machine.appendEndpoint(
            state,
            replacement.instance,
            endpoint("replacement"),
            5,
        )!!
        val commit = machine.commitEndpoint(
            state,
            "account",
            2,
            replacementEndpoint.id,
            6,
        )

        assertEquals(PushRegistrationPhase.SERVER_REVOKE_PENDING, old.phase)
        assertEquals(PushRegistrationPhase.ACTIVE, replacement.phase)
        assertEquals(listOf(1L), commit.serverRevokeGenerations)
        assertTrue(commit.nativeUnregisterInstances.isEmpty())

        val nativeUnregister = machine.retireAfterServerRevocation(
            state,
            "account",
            1,
            7,
        )

        assertEquals(listOf("instance-1"), nativeUnregister)
        assertEquals(PushRegistrationPhase.NATIVE_UNREGISTERING, old.phase)
    }

    @Test
    fun serverRevocationConfirmationRejectsRegisteringAndActiveGeneration() {
        val state = AndroidWebPushState()
        val registration = machine.beginRegistration(
            state,
            "account",
            1,
            "instance",
            1,
        ).record

        val registeringError = assertThrows(PushStateException::class.java) {
            machine.retireAfterServerRevocation(state, "account", 1, 2)
        }
        assertEquals("server_revocation_not_pending", registeringError.code)
        assertEquals(PushRegistrationPhase.REGISTERING, registration.phase)

        val endpoint = machine.appendEndpoint(
            state,
            registration.instance,
            endpoint("active"),
            3,
        )!!
        machine.commitEndpoint(state, "account", 1, endpoint.id, 4)

        val activeError = assertThrows(PushStateException::class.java) {
            machine.retireAfterServerRevocation(state, "account", 1, 5)
        }
        assertEquals("server_revocation_not_pending", activeError.code)
        assertEquals(PushRegistrationPhase.ACTIVE, registration.phase)
        assertTrue(machine.pendingNativeUnregistrations(state).isEmpty())
    }

    @Test
    fun acceptedServerRevocationRetirementIsIdempotent() {
        val state = AndroidWebPushState()
        val registration = machine.beginRegistration(
            state,
            "account",
            1,
            "instance",
            1,
        ).record
        machine.appendUnregistered(state, registration.instance, 2)

        assertEquals(
            listOf(registration.instance),
            machine.retireAfterServerRevocation(state, "account", 1, 3),
        )
        assertEquals(PushRegistrationPhase.NATIVE_UNREGISTERING, registration.phase)
        assertEquals(3L, registration.updatedAtMillis)

        assertEquals(
            listOf(registration.instance),
            machine.retireAfterServerRevocation(state, "account", 1, 4),
        )
        assertEquals(PushRegistrationPhase.NATIVE_UNREGISTERING, registration.phase)
        assertEquals(3L, registration.updatedAtMillis)

        machine.markRetired(state, registration.instance, 5)
        assertTrue(machine.retireAfterServerRevocation(state, "account", 1, 6).isEmpty())
        assertEquals(PushRegistrationPhase.RETIRED, registration.phase)
        assertEquals(5L, registration.updatedAtMillis)
    }

    @Test
    fun endpointCannotBeAcknowledgedBeforeServerCommit() {
        val state = AndroidWebPushState()
        val registration = machine.beginRegistration(
            state,
            "account",
            1,
            "instance",
            1,
        ).record
        val endpoint = machine.appendEndpoint(
            state,
            registration.instance,
            endpoint("one"),
            2,
        )!!

        val error = assertThrows(PushStateException::class.java) {
            machine.acknowledge(state, "account", setOf(endpoint.id))
        }
        assertEquals("endpoint_not_committed", error.code)

        machine.commitEndpoint(state, "account", 1, endpoint.id, 3)
        assertEquals(1, machine.acknowledge(state, "account", setOf(endpoint.id)))
    }

    @Test
    fun endpointRotationSupersedesTheOldEventAndRejectsItsCommit() {
        val state = AndroidWebPushState()
        val registration = machine.beginRegistration(
            state,
            "account",
            1,
            "instance",
            1,
        ).record
        val first = machine.appendEndpoint(
            state,
            registration.instance,
            endpoint("first"),
            2,
        )!!
        val second = machine.appendEndpoint(
            state,
            registration.instance,
            endpoint("second"),
            3,
        )!!

        assertFalse(state.events.any { it.id == first.id })
        assertEquals(2, second.coalescedCount)
        val error = assertThrows(PushStateException::class.java) {
            machine.commitEndpoint(state, "account", 1, first.id, 4)
        }
        assertEquals("stale_endpoint_event", error.code)
    }

    @Test
    fun activationCoalescingKeepsTheLatestWakeUpAndItsCount() {
        val state = AndroidWebPushState()
        val registration = machine.beginRegistration(
            state,
            "account",
            1,
            "instance",
            1,
        ).record
        machine.appendActivation(
            state,
            registration.instance,
            mapOf("content" to "first"),
            2,
        )
        val latest = machine.appendActivation(
            state,
            registration.instance,
            mapOf("content" to "second"),
            3,
        )!!

        assertEquals(1, state.events.size)
        assertEquals(2, latest.coalescedCount)
        assertEquals("second", latest.payload["content"])
    }

    @Test
    fun retiringGenerationAcceptsWakeUpsButCannotActivateANewEndpoint() {
        val state = AndroidWebPushState()
        val old = machine.beginRegistration(state, "account", 1, "old", 1).record
        val oldEndpoint = machine.appendEndpoint(state, old.instance, endpoint("old"), 2)!!
        machine.commitEndpoint(state, "account", 1, oldEndpoint.id, 3)
        val current = machine.beginRegistration(state, "account", 2, "current", 4).record
        val currentEndpoint = machine.appendEndpoint(
            state,
            current.instance,
            endpoint("current"),
            5,
        )!!
        machine.commitEndpoint(state, "account", 2, currentEndpoint.id, 6)

        val wakeUp = machine.appendActivation(
            state,
            old.instance,
            mapOf("content" to "wake"),
            7,
        )
        val staleEndpoint = machine.appendEndpoint(
            state,
            old.instance,
            endpoint("late"),
            8,
        )!!

        assertFalse(wakeUp!!.stale)
        assertTrue(staleEndpoint.stale)
        assertNull(old.currentEndpointEventId)
        val error = assertThrows(PushStateException::class.java) {
            machine.commitEndpoint(state, "account", 1, staleEndpoint.id, 9)
        }
        assertEquals("stale_generation", error.code)
    }

    @Test
    fun lowerGenerationCannotBeReintroduced() {
        val state = AndroidWebPushState()
        machine.beginRegistration(state, "account", 2, "new", 1)

        val error = assertThrows(PushStateException::class.java) {
            machine.beginRegistration(state, "account", 1, "old", 2)
        }

        assertEquals("stale_generation", error.code)
    }

    @Test
    fun distributorUnregistrationIgnoresLateEndpointAndRequiresANewGeneration() {
        val state = AndroidWebPushState()
        val record = machine.beginRegistration(state, "account", 1, "instance", 1).record
        machine.appendUnregistered(state, record.instance, 2)

        assertNull(machine.appendEndpoint(state, record.instance, endpoint("late"), 3))
        assertEquals(PushRegistrationPhase.UNREGISTERED, record.phase)

        val error = assertThrows(PushStateException::class.java) {
            machine.beginRegistration(state, "account", 1, "replacement", 4)
        }

        assertEquals("generation_unregistered", error.code)
        val replacement = machine.beginRegistration(state, "account", 2, "replacement", 5)
        assertEquals(2L, replacement.record.generation)
    }

    @Test
    fun unregisteredGenerationRejectsCommitFromItsFormerEndpoint() {
        val state = AndroidWebPushState()
        val record = machine.beginRegistration(state, "account", 1, "instance", 1).record
        val endpoint = machine.appendEndpoint(state, record.instance, endpoint("former"), 2)!!
        machine.commitEndpoint(state, "account", 1, endpoint.id, 3)
        machine.appendUnregistered(state, record.instance, 4)

        val error = assertThrows(PushStateException::class.java) {
            machine.commitEndpoint(state, "account", 1, endpoint.id, 5)
        }

        assertEquals("registration_not_found", error.code)
        assertEquals(PushRegistrationPhase.UNREGISTERED, record.phase)
        assertEquals(endpoint.id, record.committedEndpointEventId)
    }

    private fun endpoint(name: String): Map<String, Any?> {
        return mapOf(
            "url" to "https://push.example.test/$name",
            "publicKey" to null,
            "authSecret" to null,
            "temporary" to false,
        )
    }
}
