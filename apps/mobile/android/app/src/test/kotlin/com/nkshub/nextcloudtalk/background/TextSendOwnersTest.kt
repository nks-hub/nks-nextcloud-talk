package com.nkshub.nextcloudtalk.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextSendOwnersTest {
    @Test
    fun engineOwnershipIsScopedToOneOperationAndOneAccount() {
        val owners = TextSendOwners()
        val first = Any()
        val second = Any()

        assertTrue(owners.acquire(first, "account-a", "op-1", "token-a"))
        assertFalse(owners.acquire(second, "account-a", "op-1", "token-b"))
        assertTrue(owners.acquire(second, "account-a", "op-2", "token-c"))
        assertTrue(owners.acquire(second, "account-b", "op-1", "token-d"))
        assertEquals(setOf("op-1", "op-2"), owners.active("account-a").toSet())

        owners.detach(first)
        assertEquals(listOf("op-2"), owners.active("account-a"))
        assertEquals(listOf("op-1"), owners.active("account-b"))
        assertTrue(owners.acquire(second, "account-a", "op-1", "token-e"))
    }

    @Test
    fun lateReleaseCannotRemoveReplacementClaim() {
        val owners = TextSendOwners()
        val first = Any()
        val second = Any()

        assertTrue(owners.acquire(first, "account-a", "op-1", "old"))
        owners.detach(first)
        assertTrue(owners.acquire(second, "account-a", "op-1", "new"))
        owners.release(first, "account-a", "op-1", "old")
        owners.release(second, "account-a", "op-1", "wrong-token")
        assertEquals(listOf("op-1"), owners.active("account-a"))

        owners.release(second, "account-a", "op-1", "new")
        assertTrue(owners.active("account-a").isEmpty())
    }
}
