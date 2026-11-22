package com.nkshub.nextcloudtalk.background

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
import com.nkshub.nextcloudtalk.attachments.AttachmentRuntimeChannel
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs one outbox drain for [BackgroundDrain]'s job.
 *
 * Two shapes, because the process may or may not already be running:
 * a live app engine is asked to drain over its own channel, and only a process
 * that has none starts a headless engine on `backgroundDrainMain`.
 */
class BackgroundDrainJobService : JobService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val runs = BackgroundDrainRuns()

    override fun onStartJob(params: JobParameters): Boolean {
        val resources = DrainResources(mainHandler)
        val run = runs.start(params.jobId, resources::release)
        val app = BackgroundDrain.foregroundChannel()
        val timeout = Runnable { finish(params, run, true) }
        resources.timeout = timeout
        mainHandler.postDelayed(timeout, TIMEOUT_MILLIS)
        if (app != null) {
            app.invokeMethod(
                "runDrain",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = finish(params, run, false)

                    override fun error(code: String, message: String?, details: Any?) =
                        finish(params, run, true)

                    override fun notImplemented() = finish(params, run, false)
                },
            )
            return true
        }
        val created = FlutterEngine(applicationContext)
        resources.engine = created
        TextSendOwnershipChannel.attach(created)
        AttachmentRuntimeChannel.attach(created)
        PendingRevocationStorage.attach(created, applicationContext)
        MethodChannel(created.dartExecutor.binaryMessenger, BackgroundDrain.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "finished" -> {
                        result.success(null)
                        finish(params, run, call.argument<Boolean>("retry") == true)
                    }
                    else -> result.notImplemented()
                }
            }
        created.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                ENTRYPOINT,
            ),
        )
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = runs.stop(params.jobId)

    override fun onDestroy() {
        runs.stopAll()
        super.onDestroy()
    }

    private fun finish(params: JobParameters, run: BackgroundDrainRuns.Run, reschedule: Boolean) {
        if (runs.finish(run)) jobFinished(params, reschedule)
    }

    private class DrainResources(private val handler: Handler) {
        var engine: FlutterEngine? = null
        var timeout: Runnable? = null

        fun release() {
            timeout?.let(handler::removeCallbacks)
            timeout = null
            engine?.destroy()
            engine = null
        }
    }

    private companion object {
        const val ENTRYPOINT = "backgroundDrainMain"
        const val TIMEOUT_MILLIS = 4L * 60L * 1000L
    }
}

/** A JobService instance can receive callbacks for several job IDs. */
internal class BackgroundDrainRuns {
    class Run(val jobId: Int, val release: () -> Unit)

    private val active = mutableMapOf<Int, Run>()

    fun start(jobId: Int, release: () -> Unit): Run {
        val run = Run(jobId, release)
        active.put(jobId, run)?.release?.invoke()
        return run
    }

    fun stop(jobId: Int): Boolean = active[jobId]?.let(::finish) ?: false

    fun stopAll() {
        val runs = active.values.toList()
        active.clear()
        runs.forEach { it.release() }
    }

    fun finish(run: Run): Boolean {
        if (active[run.jobId] !== run) return false
        active.remove(run.jobId)
        run.release()
        return true
    }
}
