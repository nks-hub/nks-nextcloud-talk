package com.nkshub.nextcloudtalk.attachments

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

internal interface AttachmentSaverActivityLifecycle {
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean

    fun dispose()
}

internal fun interface AttachmentSaveWriter {
    fun write(source: File, destination: Uri)
}

internal interface AttachmentSaveExecution {
    fun execute(task: () -> Unit)

    fun post(task: () -> Unit)

    fun shutdown()
}

private class AndroidAttachmentSaveExecution : AttachmentSaveExecution {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun execute(task: () -> Unit) {
        executor.execute(task)
    }

    override fun post(task: () -> Unit) {
        mainHandler.post(task)
    }

    override fun shutdown() {
        executor.shutdownNow()
    }
}

private class ResolverAttachmentSaveWriter(
    private val resolver: ContentResolver,
) : AttachmentSaveWriter {
    override fun write(source: File, destination: Uri) {
        val output = resolver.openOutputStream(destination, "w")
            ?: throw IOException("The selected document cannot be opened.")
        source.inputStream().buffered().use { input ->
            output.buffered().use { target ->
                input.copyTo(target, bufferSize = 64 * 1024)
                target.flush()
            }
        }
    }
}

internal class ChatAttachmentSaver(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val ownedRoots: List<File> = listOf(activity.cacheDir),
    private val writer: AttachmentSaveWriter =
        ResolverAttachmentSaveWriter(activity.contentResolver),
    private val execution: AttachmentSaveExecution =
        AndroidAttachmentSaveExecution(),
) : MethodChannel.MethodCallHandler, AttachmentSaverActivityLifecycle {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var pending: PendingSave? = null
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "save") {
            result.notImplemented()
            return
        }
        if (disposed) {
            result.error("cancelled", "The attachment saver is closed.", null)
            return
        }
        if (pending != null) {
            result.error("save_in_progress", "An attachment save is already active.", null)
            return
        }
        val sourcePath = call.argument<String>("sourcePath")
        val fileName = call.argument<String>("fileName")
        val contentType = call.argument<String>("contentType")
        val source = try {
            validateAttachmentSaveSource(
                sourcePath = sourcePath,
                fileName = fileName,
                contentType = contentType,
                ownedRoots = ownedRoots,
            )
        } catch (error: AttachmentSaveSourceException) {
            result.error(error.code, error.message, null)
            return
        }
        val operation = PendingSave(
            source.file,
            source.fileName,
            source.contentType,
            result,
        )
        pending = operation
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            type = source.contentType
            putExtra(Intent.EXTRA_TITLE, source.fileName)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            finishError(operation, "unavailable", "No document provider is available.")
        } catch (_: SecurityException) {
            finishError(operation, "permission_denied", "Document access was denied.")
        } catch (_: RuntimeException) {
            // Document-provider implementations do not share a narrower failure type.
            finishError(operation, "storage_failed", "The document picker could not be opened.")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val operation = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            pending = null
            operation.result.success("cancelled")
            return true
        }
        val destination = data?.data
        if (destination == null) {
            finishError(operation, "storage_failed", "No document destination was returned.")
            return true
        }
        if (operation.copyStarted) return true
        operation.copyStarted = true
        try {
            execution.execute {
                val outcome = try {
                    val source = validateAttachmentSaveSource(
                        sourcePath = operation.source.path,
                        fileName = operation.fileName,
                        contentType = operation.contentType,
                        ownedRoots = ownedRoots,
                    )
                    writer.write(source.file, destination)
                    SaveOutcome.Saved
                } catch (error: AttachmentSaveSourceException) {
                    SaveOutcome.Failed(error.code, error.message)
                } catch (_: SecurityException) {
                    SaveOutcome.Failed(
                        "permission_denied",
                        "The selected location denied access.",
                    )
                } catch (_: IOException) {
                    SaveOutcome.Failed(
                        "storage_failed",
                        "The attachment could not be written.",
                    )
                } catch (_: RuntimeException) {
                    // Content providers can throw implementation-specific runtime failures.
                    SaveOutcome.Failed(
                        "storage_failed",
                        "The attachment could not be written.",
                    )
                }
                execution.post { finish(operation, outcome) }
            }
        } catch (_: RejectedExecutionException) {
            finishError(operation, "cancelled", "The attachment saver is closed.")
        }
        return true
    }

    private fun finish(operation: PendingSave, outcome: SaveOutcome) {
        if (pending !== operation) return
        pending = null
        when (outcome) {
            SaveOutcome.Saved -> operation.result.success("saved")
            is SaveOutcome.Failed -> operation.result.error(
                outcome.code,
                outcome.message,
                null,
            )
        }
    }

    private fun finishError(operation: PendingSave, code: String, message: String) {
        finish(operation, SaveOutcome.Failed(code, message))
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        val operation = pending
        pending = null
        operation?.result?.error(
            "cancelled",
            "The attachment save was cancelled.",
            null,
        )
        channel.setMethodCallHandler(null)
        execution.shutdown()
    }

    private data class PendingSave(
        val source: File,
        val fileName: String,
        val contentType: String,
        val result: MethodChannel.Result,
        var copyStarted: Boolean = false,
    )

    private sealed interface SaveOutcome {
        data object Saved : SaveOutcome

        data class Failed(val code: String, val message: String) : SaveOutcome
    }

    companion object {
        const val CHANNEL_NAME = "com.nkshub.nextcloudtalk/attachment_saver"
        internal const val REQUEST_CODE = 4119
        internal const val MAXIMUM_BYTES = 64L * 1024 * 1024
    }
}

private class AttachmentSaveSourceException(
    val code: String,
    override val message: String,
) : IllegalArgumentException(message)

private data class ValidatedAttachmentSaveSource(
    val file: File,
    val fileName: String,
    val contentType: String,
)

private fun validateAttachmentSaveSource(
    sourcePath: String?,
    fileName: String?,
    contentType: String?,
    ownedRoots: List<File>,
): ValidatedAttachmentSaveSource {
    if (sourcePath.isNullOrBlank() ||
        fileName.isNullOrBlank() ||
        contentType.isNullOrBlank() ||
        !SAFE_FILE_NAME.matches(fileName) ||
        fileName.endsWith('.') ||
        !MEDIA_TYPE.matches(contentType)
    ) {
        throw AttachmentSaveSourceException(
            "invalid_source",
            "The attachment source is invalid.",
        )
    }
    val source = try {
        File(sourcePath).canonicalFile
    } catch (_: SecurityException) {
        throw AttachmentSaveSourceException(
            "permission_denied",
            "The attachment source cannot be accessed.",
        )
    } catch (_: IOException) {
        throw AttachmentSaveSourceException(
            "invalid_source",
            "The attachment source is invalid.",
        )
    }
    val insideOwnedRoot = ownedRoots.any { root ->
        val canonicalRoot = try {
            root.canonicalFile
        } catch (_: SecurityException) {
            return@any false
        } catch (_: IOException) {
            return@any false
        }
        val rootPrefix = canonicalRoot.path.trimEnd(File.separatorChar) + File.separator
        source.path.startsWith(rootPrefix)
    }
    if (!insideOwnedRoot || !source.isFile || source.name != fileName) {
        throw AttachmentSaveSourceException(
            "invalid_source",
            "The attachment source is invalid.",
        )
    }
    if (source.length() > ChatAttachmentSaver.MAXIMUM_BYTES) {
        throw AttachmentSaveSourceException(
            "too_large",
            "The attachment is too large.",
        )
    }
    if (source.length() < 1) {
        throw AttachmentSaveSourceException(
            "invalid_source",
            "The attachment source is empty.",
        )
    }
    return ValidatedAttachmentSaveSource(source, fileName, contentType)
}

private val SAFE_FILE_NAME = Regex("^[A-Za-z0-9._-]{1,128}$")
private val MEDIA_TYPE = Regex("^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$")
