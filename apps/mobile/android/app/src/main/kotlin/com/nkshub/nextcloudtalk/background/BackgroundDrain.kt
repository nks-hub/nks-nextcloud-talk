package com.nkshub.nextcloudtalk.background

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import io.flutter.plugin.common.MethodChannel

/**
 * The recurring, network-constrained wake-up that lets the outbox deliver
 * while nobody is looking at the app.
 *
 * `JobScheduler` rather than WorkManager on purpose: on this app's minSdk 24
 * WorkManager is a wrapper around exactly this API, and the wrapper would add
 * a Maven dependency and a release-license entry for behaviour the framework
 * already provides. What WorkManager adds beyond it -- chained work, its own
 * observable state -- has nothing here that would use it.
 */
object BackgroundDrain {
    const val CHANNEL = "com.nkshub.nextcloudtalk/background_drain"

    /** Stable across installs so a reschedule replaces rather than duplicates. */
    const val JOB_ID = 5104

    /** `JobInfo.getMinPeriodMillis()`; anything shorter is clamped up anyway. */
    private const val PERIOD_MILLIS = 15L * 60L * 1000L

    /**
     * The channel of the app's own engine while one exists, main thread only.
     *
     * A wake that finds this alive must be served by it. Starting a second
     * engine in the same process would build a second outbox holding its own
     * snapshot of the same rows, and both would claim a queued message and
     * send it twice.
     */
    @Volatile
    private var foreground: MethodChannel? = null

    fun attachForeground(channel: MethodChannel?) {
        foreground = channel
    }

    fun foregroundChannel(): MethodChannel? = foreground

    /**
     * Registers the job unless it is already registered.
     *
     * Scheduling an existing periodic job restarts its period, so asking again
     * on every app start would keep pushing the next run out of reach.
     */
    fun ensureScheduled(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        if (scheduler.getPendingJob(JOB_ID) != null) {
            return
        }
        val job = JobInfo.Builder(
            JOB_ID,
            ComponentName(context, BackgroundDrainJobService::class.java),
        )
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .setPeriodic(PERIOD_MILLIS)
            .build()
        scheduler.schedule(job)
    }
}
