package com.nkshub.nextcloudtalk.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingRevocationStorageTest {
    @Test
    fun anotherEngineCannotRecoverAClaimUntilItsOwnerRetires() {
        val owners = PendingRevocationOwners()
        val foreground = Any()
        val headless = Any()
        assertTrue(owners.claim(foreground, "account-removal", "first"))
        assertTrue(owners.claim(headless, "another-account", "independent"))
        assertFalse(owners.claim(headless, "account-removal", "recovery"))
        owners.release(headless, "account-removal", "first")
        owners.release(foreground, "account-removal", "stale")
        assertFalse(owners.claim(headless, "account-removal", "recovery"))

        owners.detach(foreground)
        assertTrue(owners.claim(headless, "account-removal", "recovery"))
        owners.release(foreground, "account-removal", "first")
        assertFalse(owners.claim(foreground, "account-removal", "third"))
        assertFalse(owners.claim(foreground, "another-account", "third"))

        owners.release(headless, "account-removal", "recovery")
        assertTrue(owners.claim(foreground, "account-removal", "third"))
    }

    @Test
    fun drainWaitersRunInOrderAfterTheMatchingRelease() {
        val owners = PendingRevocationOwners()
        val foreground = Any()
        val headless = Any()
        val replies = mutableListOf<Pair<String, Boolean>>()
        owners.acquireDrain(foreground, "active") { replies.add("active" to it) }
        owners.acquireDrain(headless, "next") { replies.add("next" to it) }
        owners.acquireDrain(foreground, "last") { replies.add("last" to it) }

        assertTrue(owners.claim(foreground, "reservation", "independent"))
        owners.releaseDrain(headless, "active")
        owners.releaseDrain(foreground, "last")
        assertEquals(listOf("active" to true), replies)

        owners.releaseDrain(foreground, "active")
        assertEquals(listOf("active" to true, "next" to true), replies)
        owners.releaseDrain(headless, "next")
        assertEquals(listOf("active" to true, "next" to true, "last" to true), replies)
    }

    @Test
    fun retiringAnEngineCancelsItsWaitingDrainsAndGrantsTheNextLiveEngine() {
        val owners = PendingRevocationOwners()
        val foreground = Any()
        val stopped = Any()
        val surviving = Any()
        val replies = mutableListOf<Pair<String, Boolean>>()
        owners.acquireDrain(foreground, "active") { replies.add("active" to it) }
        owners.acquireDrain(stopped, "stopped") { replies.add("stopped" to it) }
        owners.acquireDrain(foreground, "another") { replies.add("another" to it) }
        owners.acquireDrain(surviving, "remaining") { replies.add("remaining" to it) }

        owners.detach(stopped)
        assertEquals(listOf("active" to true, "stopped" to false), replies)
        owners.detach(foreground)
        assertEquals(
            listOf("active" to true, "stopped" to false, "another" to false, "remaining" to true),
            replies,
        )
    }

    @Test
    fun oldVaultKeysAreMigratedAndDeletionDoesNotResurrectThePassword() {
        val legacy = "account.fixture.appPassword"
        val current = "credential.v2.account.fixture.appPassword"
        val version = "credential.account.fixture.version"
        val data = mutableMapOf(legacy to "fixture-password")
        val records = AndroidCredentialRecords(
            readKey = data::get,
            writeKey = { key, value -> data[key] = value },
            deleteKey = { data.remove(it) },
        )

        assertEquals("fixture-password", records.read("fixture"))
        assertEquals(mapOf(current to "fixture-password", version to "2"), data)
        records.delete("fixture")
        assertNull(records.read("fixture"))
        assertEquals(mapOf(version to "2"), data)
    }

    @Test
    fun changingOneAccountPreservesTheOtherAccountsCachedRead() {
        val first = "credential.v2.account.first.appPassword"
        val second = "credential.v2.account.second.appPassword"
        val data = mutableMapOf(first to "initial", second to "other")
        val reads = mutableListOf<String>()
        val records = AndroidCredentialRecords(
            readKey = { key ->
                reads.add(key)
                data[key]
            },
            writeKey = { key, value -> data[key] = value },
            deleteKey = { data.remove(it) },
        )

        assertEquals("initial", records.read("first"))
        assertEquals("other", records.read("second"))
        reads.clear()
        assertEquals("initial", records.read("first"))
        records.write("first", "replaced")
        assertEquals("replaced", records.read("first"))
        assertEquals("other", records.read("second"))
        records.delete("first")
        assertNull(records.read("first"))
        assertEquals("other", records.read("second"))
        assertEquals(listOf(first, first), reads)
    }

    @Test
    fun freshReadingClearsACachedPasswordOnMissingOrFailedRead() {
        val key = "credential.v2.account.fixture.appPassword"
        val data = mutableMapOf(key to "initial")
        var failRead = false
        val records = AndroidCredentialRecords(
            readKey = {
                check(!failRead)
                data[it]
            },
            writeKey = { name, value -> data[name] = value },
            deleteKey = { data.remove(it) },
        )

        assertEquals("initial", records.read("fixture"))
        data[key] = "replaced"
        assertEquals("replaced", records.read("fixture", refresh = true))
        assertEquals("replaced", records.read("fixture"))
        failRead = true
        assertThrows(IllegalStateException::class.java) {
            records.read("fixture", refresh = true)
        }
        assertThrows(IllegalStateException::class.java) { records.read("fixture") }
        failRead = false
        assertEquals("replaced", records.read("fixture"))
        data.remove(key)
        assertNull(records.read("fixture", refresh = true))
        assertNull(records.read("fixture"))
        data[key] = "available"
        assertEquals("available", records.read("fixture"))
    }

    @Test
    fun failedWritesAndDeletesDropThePreviouslyCachedValue() {
        val key = "credential.v2.account.fixture.appPassword"
        val data = mutableMapOf(key to "initial", "credential.account.fixture.version" to "2")
        val records = AndroidCredentialRecords(
            readKey = data::get,
            writeKey = { name, value ->
                data[name] = value
                error("Write failed after updating storage")
            },
            deleteKey = {
                data.remove(it)
                error("Delete failed after updating storage")
            },
        )

        assertEquals("initial", records.read("fixture"))
        assertThrows(IllegalStateException::class.java) { records.write("fixture", "replaced") }
        assertEquals("replaced", records.read("fixture"))
        assertThrows(IllegalStateException::class.java) { records.delete("fixture") }
        assertNull(records.read("fixture"))
    }

    @Test
    fun conflictingOldVaultKeysArePreserved() {
        val legacy = "account.fixture.appPassword"
        val current = "credential.v2.account.fixture.appPassword"
        val baseline = mapOf(legacy to "old-fixture-password", current to "new-fixture-password")
        val data = baseline.toMutableMap()
        val records = AndroidCredentialRecords(
            readKey = data::get,
            writeKey = { key, value -> data[key] = value },
            deleteKey = { data.remove(it) },
        )

        assertThrows(IllegalStateException::class.java) { records.delete("fixture") }
        assertEquals(baseline, data)
    }
}
