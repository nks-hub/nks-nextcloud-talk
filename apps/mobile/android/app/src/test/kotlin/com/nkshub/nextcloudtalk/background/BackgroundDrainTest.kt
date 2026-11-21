package com.nkshub.nextcloudtalk.background

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.os.Build
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 35])
class BackgroundDrainTest {
    private val context = RuntimeEnvironment.getApplication()
    private val scheduler = context.getSystemService(JobScheduler::class.java)

    @Test
    fun oneOffWakeWaitsForANetworkAndDoesNotRepeat() {
        BackgroundDrain.scheduleOnce(context)

        val job = scheduler.getPendingJob(BackgroundDrain.ONCE_JOB_ID)
        assertNotNull(job)
        assertFalse(job!!.isPeriodic)
        assertEquals(JobInfo.NETWORK_TYPE_ANY, job.networkType)
        assertEquals(BackgroundDrainJobService::class.java.name, job.service.className)
    }

    @Test
    fun aPendingOneOffWakeIsKeptWhenAskedAgain() {
        BackgroundDrain.scheduleOnce(context)
        val first = scheduler.getPendingJob(BackgroundDrain.ONCE_JOB_ID)

        BackgroundDrain.scheduleOnce(context)

        assertSame(first, scheduler.getPendingJob(BackgroundDrain.ONCE_JOB_ID))
        assertEquals(1, scheduler.allPendingJobs.size)
    }

    @Test
    fun theOneOffWakeLeavesTheRecurringOneInPlace() {
        BackgroundDrain.ensureScheduled(context)
        BackgroundDrain.scheduleOnce(context)

        assertTrue(scheduler.getPendingJob(BackgroundDrain.JOB_ID)!!.isPeriodic)
        assertEquals(
            setOf(BackgroundDrain.JOB_ID, BackgroundDrain.ONCE_JOB_ID),
            scheduler.allPendingJobs.map { it.id }.toSet(),
        )
    }

    @Test
    fun aPushAsksForAnExpeditedDrainOnce() {
        BackgroundDrain.scheduleForPush(context)
        BackgroundDrain.scheduleForPush(context)

        val job = scheduler.getPendingJob(BackgroundDrain.PUSH_JOB_ID)!!
        assertEquals(JobInfo.NETWORK_TYPE_ANY, job.networkType)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            assertTrue(job.isExpedited)
        }
    }

    @Test
    fun revocationWriteRejectsAStaleSnapshot() {
        var stored: String? = "newer"
        val queue = PendingRevocationCompareAndSet(
            read = { stored },
            write = { stored = it },
        )

        assertFalse(queue.compareAndSet("older", null))
        assertEquals("newer", stored)
        assertTrue(queue.compareAndSet("newer", "latest"))
        assertEquals("latest", stored)
    }
}
