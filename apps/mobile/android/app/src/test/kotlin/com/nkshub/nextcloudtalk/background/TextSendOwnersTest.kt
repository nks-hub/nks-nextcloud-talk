package com.nkshub.nextcloudtalk.background

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
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

    @Test
    fun queuedAcquireCannotClaimAfterEngineDestroy() {
        val owners = TextSendOwners()
        val retiring = EngineBinding(owners)
        val remaining = EngineBinding(owners)
        val queuedHandler = checkNotNull(retiring.handler)
        val remainingHandler = checkNotNull(remaining.handler)
        assertEquals(true, acquire(queuedHandler, "retiring").value)
        assertEquals(true, acquire(remainingHandler, "remaining").value)

        retiring.binding.destroy()
        assertNull(retiring.handler)
        assertEquals(setOf("retiring", "remaining"), owners.active("account-a").toSet())
        assertEquals("retiredTextSendOwner", acquire(queuedHandler, "late").errorCode)

        retiring.flushDetach()
        assertEquals(listOf("remaining"), owners.active("account-a"))
        assertEquals("retiredTextSendOwner", acquire(queuedHandler, "late").errorCode)
        assertEquals(true, acquire(remainingHandler, "late").value)
    }

    @Test
    fun restartReplacesQueuedHandlerAndKeepsOtherEnginesClaim() {
        val owners = TextSendOwners()
        val restarting = EngineBinding(owners)
        val remaining = EngineBinding(owners)
        val queuedHandler = checkNotNull(restarting.handler)
        val remainingHandler = checkNotNull(remaining.handler)
        assertEquals(true, acquire(queuedHandler, "restarting").value)
        assertEquals(true, acquire(remainingHandler, "remaining").value)

        restarting.binding.restart()
        assertEquals("retiredTextSendOwner", acquire(queuedHandler, "late").errorCode)
        val replacementHandler = checkNotNull(restarting.handler)
        assertNotSame(queuedHandler, replacementHandler)
        assertEquals(false, acquire(replacementHandler, "restarting").value)
        assertEquals(true, acquire(replacementHandler, "new").value)

        restarting.flushDetach()
        assertEquals(setOf("remaining", "new"), owners.active("account-a").toSet())
        assertEquals("retiredTextSendOwner", acquire(queuedHandler, "restarting").errorCode)
        assertEquals(true, acquire(replacementHandler, "restarting").value)
        assertEquals(false, acquire(replacementHandler, "remaining").value)
    }

    private fun acquire(handler: MethodChannel.MethodCallHandler, id: String): ClaimResult {
        val call = MethodCall(
            "acquire",
            mapOf("accountId" to "account-a", "operationId" to id, "token" to "token"),
        )
        return ClaimResult().also { handler.onMethodCall(call, it) }
    }

    private class EngineBinding(owners: TextSendOwners) {
        var handler: MethodChannel.MethodCallHandler? = null
            private set
        private val pendingDetach = ArrayDeque<() -> Unit>()
        val binding = TextSendOwnershipBinding(owners, { handler = it }) { pendingDetach.addLast(it) }

        fun flushDetach() {
            pendingDetach.removeFirst().invoke()
            assertTrue(pendingDetach.isEmpty())
        }
    }

    private class ClaimResult : MethodChannel.Result {
        var value: Any? = null
            private set
        var errorCode: String? = null
            private set

        override fun success(result: Any?) {
            value = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
        }

        override fun notImplemented() = error("Unexpected unhandled acquire")
    }
}
