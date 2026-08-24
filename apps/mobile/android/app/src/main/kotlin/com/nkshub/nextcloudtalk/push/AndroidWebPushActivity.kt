package com.nkshub.nextcloudtalk.push

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class AndroidWebPushActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var channelHandler: AndroidWebPushChannel? = null
    private val notifierListener: (Int) -> Unit = { count ->
        mainHandler.post {
            methodChannel?.invokeMethod("eventsAvailable", mapOf("count" to count))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        val handler = AndroidWebPushChannel(applicationContext)
        channel.setMethodCallHandler(handler)
        methodChannel = channel
        channelHandler = handler
        AndroidWebPushNotifier.attach(notifierListener)
    }

    override fun onDestroy() {
        AndroidWebPushNotifier.detach(notifierListener)
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        channelHandler = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/android_web_push"
    }
}
