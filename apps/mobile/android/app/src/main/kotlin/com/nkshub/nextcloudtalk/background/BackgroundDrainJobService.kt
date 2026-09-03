package com.nkshub.nextcloudtalk.background

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
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
    private var engine: FlutterEngine? = null
    private var timeout: Runnable? = null
    private var finished = false

    override fun onStartJob(params: JobParameters): Boolean {
        val app = BackgroundDrain.foregroundChannel()
        armTimeout(params)
        if (app != null) {
            app.invokeMethod(
                "runDrain",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = finish(params, false)

                    override fun error(code: String, message: String?, details: Any?) =
                        finish(params, true)

                    override fun notImplemented() = finish(params, false)
                },
            )
            return true
        }
        val created = FlutterEngine(applicationContext)
        engine = created
        MethodChannel(created.dartExecutor.binaryMessenger, BackgroundDrain.CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "finished") {
                    result.success(null)
                    finish(params, call.argument<Boolean>("retry") == true)
                } else {
                    result.notImplemented()
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

    /**
     * The system stops an unfinished job after about ten minutes and counts it
     * against the app. A drain that has not reported by then is stuck on a
     * server that never answers, and the next wake is a better bet than
     * holding this one open.
     */
    private fun armTimeout(params: JobParameters) {
        val runnable = Runnable { finish(params, true) }
        timeout = runnable
        mainHandler.postDelayed(runnable, TIMEOUT_MILLIS)
    }

    override fun onStopJob(params: JobParameters): Boolean {
        release()
        return !finished
    }

    private fun finish(params: JobParameters, reschedule: Boolean) {
        if (finished) {
            return
        }
        finished = true
        release()
        jobFinished(params, reschedule)
    }

    private fun release() {
        timeout?.let(mainHandler::removeCallbacks)
        timeout = null
        engine?.destroy()
        engine = null
    }

    private companion object {
        const val ENTRYPOINT = "backgroundDrainMain"
        const val TIMEOUT_MILLIS = 4L * 60L * 1000L
    }
}
