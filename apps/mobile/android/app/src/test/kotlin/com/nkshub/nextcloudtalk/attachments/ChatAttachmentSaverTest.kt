package com.nkshub.nextcloudtalk.attachments

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class ChatAttachmentSaverTest {
    @Test
    fun savedDocumentUsesSafAndCompletesAfterTheCopy() {
        val fixture = fixture()
        val source = fixture.source("report.pdf", "exact bytes")

        fixture.saver.onMethodCall(saveCall(source), fixture.result)

        val launch = shadowOf(fixture.activity).nextStartedActivityForResult
        assertEquals(Intent.ACTION_CREATE_DOCUMENT, launch.intent.action)
        assertEquals("application/pdf", launch.intent.type)
        assertEquals("report.pdf", launch.intent.getStringExtra(Intent.EXTRA_TITLE))
        assertTrue(launch.intent.categories!!.contains(Intent.CATEGORY_OPENABLE))
        assertNull(fixture.result.value)

        val destination = Uri.parse("content://documents/exported/report.pdf")
        assertTrue(
            fixture.saver.onActivityResult(
                ChatAttachmentSaver.REQUEST_CODE,
                Activity.RESULT_OK,
                Intent().setData(destination),
            ),
        )

        assertEquals("saved", fixture.result.value)
        assertEquals(listOf(source.canonicalFile), fixture.writer.sources)
        assertEquals(listOf(destination), fixture.writer.destinations)
    }

    @Test
    fun duplicateSaveIsRejectedUntilTheFirstResultFinishes() {
        val fixture = fixture()
        val source = fixture.source("report.pdf", "exact bytes")
        val duplicate = RecordingResult()

        fixture.saver.onMethodCall(saveCall(source), fixture.result)
        fixture.saver.onMethodCall(saveCall(source), duplicate)

        assertEquals("save_in_progress", duplicate.errorCode)
        assertNull(fixture.result.errorCode)
    }

    @Test
    fun cancelledSafPickerIsACompletedCancellation() {
        val fixture = fixture()
        val source = fixture.source("report.pdf", "exact bytes")

        fixture.saver.onMethodCall(saveCall(source), fixture.result)
        fixture.saver.onActivityResult(
            ChatAttachmentSaver.REQUEST_CODE,
            Activity.RESULT_CANCELED,
            null,
        )

        assertEquals("cancelled", fixture.result.value)
        assertTrue(fixture.writer.sources.isEmpty())
        assertNull(fixture.result.errorCode)
    }

    @Test
    fun sourceOutsideTheAppOwnedRootNeverLaunchesSaf() {
        val fixture = fixture()
        val outside = File.createTempFile("outside-attachment", ".pdf")
        outside.writeText("not owned")
        try {
            fixture.saver.onMethodCall(saveCall(outside), fixture.result)

            assertEquals("invalid_source", fixture.result.errorCode)
            assertNull(shadowOf(fixture.activity).nextStartedActivityForResult)
        } finally {
            outside.delete()
        }
    }

    @Test
    fun sourceIsRevalidatedAfterTheDocumentPickerReturns() {
        val fixture = fixture()
        val source = fixture.source("report.pdf", "exact bytes")

        fixture.saver.onMethodCall(saveCall(source), fixture.result)
        source.delete()
        fixture.saver.onActivityResult(
            ChatAttachmentSaver.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://documents/replaced")),
        )

        assertEquals("invalid_source", fixture.result.errorCode)
        assertTrue(fixture.writer.sources.isEmpty())
    }

    @Test
    fun duplicateActivityResultCannotStartTwoCopies() {
        val execution = RecordingExecution(immediate = false)
        val fixture = fixture(execution = execution)
        val source = fixture.source("report.pdf", "exact bytes")

        fixture.saver.onMethodCall(saveCall(source), fixture.result)
        fixture.saver.onActivityResult(
            ChatAttachmentSaver.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://documents/first")),
        )
        fixture.saver.onActivityResult(
            ChatAttachmentSaver.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://documents/second")),
        )

        assertEquals(1, execution.pendingTasks)
        execution.runNext()
        assertEquals(1, fixture.writer.destinations.size)
        assertEquals("saved", fixture.result.value)
    }

    @Test
    fun disposeCancelsPendingResultAndRejectsLateActivityResult() {
        val fixture = fixture()
        val source = fixture.source("report.pdf", "exact bytes")

        fixture.saver.onMethodCall(saveCall(source), fixture.result)
        fixture.saver.dispose()

        assertEquals("cancelled", fixture.result.errorCode)
        assertTrue(fixture.execution.shutdownCalled)
        assertTrue(
            fixture.saver.onActivityResult(
                ChatAttachmentSaver.REQUEST_CODE,
                Activity.RESULT_OK,
                Intent().setData(Uri.parse("content://documents/late")),
            ),
        )
        assertTrue(fixture.writer.sources.isEmpty())
    }

    @Test
    fun documentProviderPermissionFailureStaysTyped() {
        val fixture = fixture(RecordingWriter(SecurityException("denied")))
        val source = fixture.source("report.pdf", "exact bytes")

        fixture.saver.onMethodCall(saveCall(source), fixture.result)
        fixture.saver.onActivityResult(
            ChatAttachmentSaver.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://documents/denied")),
        )

        assertEquals("permission_denied", fixture.result.errorCode)
    }

    @Test
    fun documentProviderWriteFailureStaysTyped() {
        val fixture = fixture(RecordingWriter(IOException("full")))
        val source = fixture.source("report.pdf", "exact bytes")

        fixture.saver.onMethodCall(saveCall(source), fixture.result)
        fixture.saver.onActivityResult(
            ChatAttachmentSaver.REQUEST_CODE,
            Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://documents/full")),
        )

        assertEquals("storage_failed", fixture.result.errorCode)
    }

    @Test
    fun activityDestroyDisposesItsAttachmentSaver() {
        val activity = com.nkshub.nextcloudtalk.push.AndroidWebPushActivity()
        val lifecycle = RecordingLifecycle()
        activity.installAttachmentSaverForTest(lifecycle)

        activity.disposeAttachmentSaver()

        assertTrue(lifecycle.disposed)
    }

    private fun fixture(
        writer: RecordingWriter = RecordingWriter(),
        execution: RecordingExecution = RecordingExecution(),
    ): Fixture {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = File(activity.cacheDir, "attachment-test-root").apply { mkdirs() }
        return Fixture(
            activity = activity,
            root = root,
            writer = writer,
            execution = execution,
            result = RecordingResult(),
            saver = ChatAttachmentSaver(
                activity = activity,
                messenger = NoopMessenger(),
                ownedRoots = listOf(root),
                writer = writer,
                execution = execution,
            ),
        )
    }
}

private data class Fixture(
    val activity: Activity,
    val root: File,
    val writer: RecordingWriter,
    val execution: RecordingExecution,
    val result: RecordingResult,
    val saver: ChatAttachmentSaver,
) {
    fun source(name: String, contents: String): File = File(root, name).apply {
        writeText(contents)
    }
}

private fun saveCall(source: File): MethodCall = MethodCall(
    "save",
    mapOf(
        "sourcePath" to source.path,
        "fileName" to source.name,
        "contentType" to "application/pdf",
    ),
)

private class RecordingWriter(private val failure: Throwable? = null) : AttachmentSaveWriter {
    val sources = mutableListOf<File>()
    val destinations = mutableListOf<Uri>()

    override fun write(source: File, destination: Uri) {
        failure?.let { throw it }
        sources += source.canonicalFile
        destinations += destination
    }
}

private class RecordingExecution(private val immediate: Boolean = true) : AttachmentSaveExecution {
    var shutdownCalled = false
    private val tasks = ArrayDeque<() -> Unit>()

    val pendingTasks: Int
        get() = tasks.size

    override fun execute(task: () -> Unit) {
        if (immediate) task() else tasks.addLast(task)
    }

    override fun post(task: () -> Unit) = task()

    fun runNext() {
        tasks.removeFirst()()
    }

    override fun shutdown() {
        shutdownCalled = true
    }
}

private class RecordingLifecycle : AttachmentSaverActivityLifecycle {
    var disposed = false

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean = false

    override fun dispose() {
        disposed = true
    }
}

private class RecordingResult : MethodChannel.Result {
    var value: Any? = null
    var errorCode: String? = null

    override fun success(result: Any?) {
        value = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        this.errorCode = errorCode
    }

    override fun notImplemented() = Unit
}

private class NoopMessenger : BinaryMessenger {
    override fun send(channel: String, message: ByteBuffer?) = Unit

    override fun send(
        channel: String,
        message: ByteBuffer?,
        callback: BinaryMessenger.BinaryReply?,
    ) = Unit

    override fun setMessageHandler(
        channel: String,
        handler: BinaryMessenger.BinaryMessageHandler?,
    ) = Unit
}
