package com.nkshub.nextcloudtalk.attachments

import org.junit.Assert.assertEquals
import org.junit.Test

class AttachmentRuntimeQueueTest {
    @Test
    fun replacingAServiceInOneEngineWaitsForThePreviousReservation() {
        val queue = AttachmentRuntimeQueue()
        val foreground = Any()
        val grants = mutableListOf<Boolean>()

        queue.acquire(foreground, "old") { grants.add(it) }
        queue.acquire(foreground, "new") { grants.add(it) }
        assertEquals(listOf(true), grants)
        queue.release(Any(), "old")
        assertEquals(listOf(true), grants)

        queue.release(foreground, "old")
        assertEquals(listOf(true, true), grants)
        queue.acquire(foreground, "cancelled") { grants.add(it) }
        queue.release(foreground, "cancelled")
        assertEquals(listOf(true, true, false), grants)
    }

    @Test
    fun detachedHeadlessWaiterCannotHoldUpTheForeground() {
        val queue = AttachmentRuntimeQueue()
        val owningHeadless = Any()
        val waitingHeadless = Any()
        val foreground = Any()
        val grants = mutableListOf<String>()

        queue.acquire(owningHeadless, "active") { grants.add("active") }
        queue.acquire(waitingHeadless, "waiting") { grants.add("destroyed") }
        queue.acquire(foreground, "foreground") { grants.add("foreground") }
        queue.detach(waitingHeadless)
        assertEquals(listOf("active"), grants)

        queue.detach(owningHeadless)
        queue.release(owningHeadless, "active")
        assertEquals(listOf("active", "foreground"), grants)
        queue.acquire(foreground, "replacement") { grants.add("replacement") }
        assertEquals(listOf("active", "foreground"), grants)

        queue.release(foreground, "foreground")
        assertEquals(listOf("active", "foreground", "replacement"), grants)
    }
}
