package com.nkshub.nextcloudtalk.calls

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ServiceController
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CallForegroundServiceTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private var service: ServiceController<out CallForegroundService>? = null
    private var channel: CallForegroundChannel? = null

    @After fun cleanup() {
        channel?.dispose()
        CallForegroundService.stop(context, "first")
        CallForegroundService.stop(context, "second")
        service?.destroy()
    }

    @Test fun foregroundAcknowledgementFollowsMicrophoneServicePromotion() {
        val replies = mutableListOf<Boolean>()
        CallForegroundService.start(context, "first", replies::add)
        assertTrue(replies.isEmpty())
        service = Robolectric.buildService(CallForegroundService::class.java).create()
        service!!.startCommand(0, 1)
        assertEquals(listOf(true), replies)
        val notification = shadowOf(service!!.get()).lastForegroundNotification
        assertNotNull(notification)
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            context.packageManager.getServiceInfo(ComponentName(context, CallForegroundService::class.java), 0).foregroundServiceType)
    }

    @Test fun cameraGrantWaitsForResumedOwnerAndDowngradesInBackground() {
        var resumed = true
        startChannel { resumed }
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.CAMERA)
        val result = Reply()
        channel!!.onMethodCall(cameraCall(true), result)
        assertNull(result.value)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
        resumed = false
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA)
        channel!!.onRequestPermissionsResult(CallForegroundChannel.CAMERA_REQUEST_CODE, intArrayOf(0))
        assertNull(result.value)
        resumed = true
        channel!!.onResume()
        assertEquals("started", result.value)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            service!!.get().foregroundServiceType)
        resumed = false
        val stoppedCamera = Reply()
        channel!!.onMethodCall(cameraCall(false), stoppedCamera)
        assertEquals("started", stoppedCamera.value)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
    }

    @Test fun backgroundCameraUpgradeIsRefusedEvenWithPermission() {
        var resumed = true
        startChannel { resumed }
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA)
        resumed = false
        val result = Reply()
        channel!!.onMethodCall(cameraCall(true), result)
        assertEquals("unavailable", result.value)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
    }

    @Test fun cameraOffCancelsPendingGrantWithoutStoppingAudio() {
        startChannel()
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.CAMERA)
        val pending = Reply()
        channel!!.onMethodCall(cameraCall(true), pending)
        val disable = Reply()
        channel!!.onMethodCall(cameraCall(false), disable)
        assertEquals("unavailable", pending.value)
        assertEquals("started", disable.value)
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA)
        channel!!.onRequestPermissionsResult(CallForegroundChannel.CAMERA_REQUEST_CODE, intArrayOf(0))
        channel!!.onResume()
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStoppedService)
    }

    @Test fun deniedCameraLeavesAudioOwnerRunning() {
        startChannel()
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.CAMERA)
        val result = Reply()
        channel!!.onMethodCall(cameraCall(true), result)
        channel!!.onRequestPermissionsResult(CallForegroundChannel.CAMERA_REQUEST_CODE, intArrayOf(-1))
        assertEquals("permission-denied", result.value)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStoppedService)
        var alive = false
        CallForegroundService.start(context, "first") { alive = it }
        assertTrue(alive)
    }

    @Test fun lateCameraGrantCannotReviveAStoppedOwner() {
        startChannel()
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.CAMERA)
        val result = Reply()
        channel!!.onMethodCall(cameraCall(true), result)
        channel!!.onMethodCall(MethodCall("stop", mapOf("owner" to "first")), Reply())
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA)
        channel!!.onRequestPermissionsResult(CallForegroundChannel.CAMERA_REQUEST_CODE, intArrayOf(0))
        channel!!.onResume()
        assertEquals("unavailable", result.value)
        assertFalse(CallForegroundService.setCameraEnabled("first", true))
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
    }

    @Test fun cameraDemandIsAggregatedAcrossExactOwners() {
        CallForegroundService.start(context, "first") {}
        service = Robolectric.buildService(CallForegroundService::class.java).create()
        service!!.startCommand(0, 1)
        assertTrue(CallForegroundService.setCameraEnabled("first", true))
        CallForegroundService.start(context, "second") {}
        assertTrue(CallForegroundService.setCameraEnabled("second", true))
        CallForegroundService.stop(context, "first")
        assertFalse(CallForegroundService.setCameraEnabled("first", false))
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            service!!.get().foregroundServiceType)
        assertTrue(CallForegroundService.setCameraEnabled("second", false))
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
    }

    @Test fun rejectedPromotionRollsBackCameraButKeepsMicrophone() {
        CallForegroundService.start(context, "first") {}
        service = Robolectric.buildService(RejectCameraForegroundService::class.java).create()
        service!!.startCommand(0, 1)
        assertFalse(CallForegroundService.setCameraEnabled("first", true))
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service!!.get().foregroundServiceType)
        assertTrue(CallForegroundService.setCameraEnabled("first", false))
        var secondStarted = false
        CallForegroundService.start(context, "second") { secondStarted = it }
        assertTrue(secondStarted)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStoppedService)
    }

    @Test @Config(sdk = [29]) fun audioOnlyOnAndroidTenDoesNotActivateDeclaredCameraType() {
        startChannel()
        assertEquals(0, service!!.get().foregroundServiceType)
    }

    @Test @Config(sdk = [29]) fun cameraOnAndroidTenUsesNoUnsupportedForegroundType() {
        startChannel()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA)
        val enabled = Reply()
        channel!!.onMethodCall(cameraCall(true), enabled)
        assertEquals("started", enabled.value)
        assertEquals(0, service!!.get().foregroundServiceType)
        val disabled = Reply()
        channel!!.onMethodCall(cameraCall(false), disabled)
        assertEquals("started", disabled.value)
        assertEquals(0, service!!.get().foregroundServiceType)
    }

    private fun cameraCall(enabled: Boolean) = MethodCall("setCameraEnabled",
        mapOf("owner" to "first", "enabled" to enabled))

    private fun startChannel(resumed: () -> Boolean = { true }) {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
        channel = CallForegroundChannel(activity, resumed)
        val result = Reply()
        channel!!.onMethodCall(MethodCall("start", mapOf("owner" to "first")), result)
        service = Robolectric.buildService(CallForegroundService::class.java).create()
        service!!.startCommand(0, 1)
        assertEquals("started", result.value)
    }

    @Test fun stoppingAnOldOwnerDoesNotStopAnotherCall() {
        CallForegroundService.start(context, "first") {}
        service = Robolectric.buildService(CallForegroundService::class.java).create()
        service!!.startCommand(0, 1)
        var acknowledged = false
        CallForegroundService.start(context, "second") { acknowledged = it }
        assertTrue(acknowledged)
        CallForegroundService.stop(context, "first")
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStoppedService)
        CallForegroundService.stop(context, "second")
        assertEquals(CallForegroundService::class.java.name,
            shadowOf(RuntimeEnvironment.getApplication()).nextStoppedService.component!!.className)
    }

    @Test fun backgroundRequestNeverStartsAMicrophoneService() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        channel = CallForegroundChannel(activity) { false }
        val result = Reply()
        channel!!.onMethodCall(MethodCall("start", mapOf("owner" to "first")), result)
        assertEquals("unavailable", result.value)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
    }

    @Test fun retiringServiceCannotClearTheNextCallGeneration() {
        CallForegroundService.start(context, "first") {}
        val oldService = Robolectric.buildService(CallForegroundService::class.java).create()
        oldService.startCommand(0, 1)
        CallForegroundService.stop(context, "first")
        val replies = mutableListOf<Boolean>()
        CallForegroundService.start(context, "second", replies::add)
        oldService.destroy()
        assertTrue(replies.isEmpty())
        service = Robolectric.buildService(CallForegroundService::class.java).create()
        service!!.startCommand(0, 2)
        assertEquals(listOf(true), replies)
        assertNotNull(shadowOf(service!!.get()).lastForegroundNotification)
    }

    @Test fun permissionGrantWaitsForResumedActivityBeforeStarting() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        var resumed = true
        channel = CallForegroundChannel(activity) { resumed }
        val result = Reply()
        channel!!.onMethodCall(MethodCall("start", mapOf("owner" to "first")), result)
        resumed = false
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
        channel!!.onRequestPermissionsResult(CallForegroundChannel.REQUEST_CODE, intArrayOf(0))
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
        resumed = true
        channel!!.onResume()
        assertNotNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
        assertNull(result.value)
        service = Robolectric.buildService(CallForegroundService::class.java).create()
        service!!.startCommand(0, 1)
        assertEquals("started", result.value)
    }

    @Test fun deniedMicrophonePermissionDoesNotStartTheService() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        channel = CallForegroundChannel(activity) { true }
        val result = Reply()
        channel!!.onMethodCall(MethodCall("start", mapOf("owner" to "first")), result)
        assertNull(result.value)
        channel!!.onRequestPermissionsResult(CallForegroundChannel.REQUEST_CODE, intArrayOf(-1))
        assertEquals("permission-denied", result.value)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
    }

    @Test fun cancelledPermissionRequestCannotStartAfterALateGrant() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        channel = CallForegroundChannel(activity) { true }
        val pending = Reply()
        channel!!.onMethodCall(MethodCall("start", mapOf("owner" to "first")), pending)
        channel!!.onMethodCall(MethodCall("stop", mapOf("owner" to "first")), Reply())
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
        channel!!.onRequestPermissionsResult(CallForegroundChannel.REQUEST_CODE, intArrayOf(0))
        channel!!.onResume()
        assertEquals("unavailable", pending.value)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
    }

    @Test fun unacknowledgedStartTimesOutAndCannotLeaveAnOwnerBehind() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
        channel = CallForegroundChannel(activity) { true }
        val result = Reply()
        channel!!.onMethodCall(MethodCall("start", mapOf("owner" to "first")), result)
        assertNull(result.value)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(3))
        assertEquals("unavailable", result.value)
        service = Robolectric.buildService(CallForegroundService::class.java).create()
        service!!.startCommand(0, 1)
        assertNull(shadowOf(service!!.get()).lastForegroundNotification)
    }

    private class Reply : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { fail(code) }
        override fun notImplemented() { fail("Unexpected method") }
    }
}

class RejectCameraForegroundService : CallForegroundService() {
    override fun promoteNotification(notification: Notification, types: Int) {
        if (types and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA != 0) {
            throw SecurityException("Synthetic camera type rejection")
        }
        super.promoteNotification(notification, types)
    }
}
