package com.nkshub.nextcloudtalk.background

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
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
    fun stoppingAJobOnlyReleasesItsEngineAndIgnoresItsLateCompletion() {
        val runs = BackgroundDrainRuns()
        val released = mutableListOf<String>()
        val periodic = runs.start(BackgroundDrain.JOB_ID) { released.add("periodic") }
        val once = runs.start(BackgroundDrain.ONCE_JOB_ID) { released.add("once") }

        assertTrue(runs.stop(BackgroundDrain.JOB_ID))
        assertEquals(listOf("periodic"), released)
        val replacement = runs.start(BackgroundDrain.JOB_ID) { released.add("replacement") }

        assertFalse(runs.finish(periodic))
        assertTrue(runs.finish(once))
        assertEquals(listOf("periodic", "once"), released)
        runs.stopAll()
        assertEquals(listOf("periodic", "once", "replacement"), released)
        assertFalse(runs.finish(replacement))
    }

    @Test
    fun lateActivityDetachLeavesTheCurrentForegroundChannelAvailable() {
        val old = MethodChannel(NoopMessenger, BackgroundDrain.CHANNEL)
        val current = MethodChannel(NoopMessenger, BackgroundDrain.CHANNEL)
        try {
            BackgroundDrain.attachForeground(old)
            BackgroundDrain.attachForeground(current)
            BackgroundDrain.detachForeground(old)

            assertSame(current, BackgroundDrain.foregroundChannel())
        } finally {
            BackgroundDrain.detachForeground(current)
        }
        assertEquals(null, BackgroundDrain.foregroundChannel())
    }

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

private object NoopMessenger : BinaryMessenger {
    override fun send(channel: String, message: ByteBuffer?) = Unit

    override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit

    override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) = Unit
}
