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
