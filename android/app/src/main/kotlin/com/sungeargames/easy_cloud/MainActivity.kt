package com.sungeargames.easy_cloud

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.Locale

class MainActivity : FlutterFragmentActivity() {
    private val createDocumentLauncher: ActivityResultLauncher<Intent> =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
            ::onCreateDocumentResult,
        )

    private var pendingExport: PendingExport? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                OPEN_FILE_METHOD -> openFile(call, result)
                SAVE_FILE_AS_METHOD -> saveFileAs(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun openFile(call: MethodCall, result: MethodChannel.Result) {
        try {
            val path = call.argument<String>(PATH_ARGUMENT)
                ?: throw InvalidOpenFileRequest()
            val displayName = call.argument<String>(DISPLAY_NAME_ARGUMENT)
                ?: throw InvalidOpenFileRequest()
            val file = validateCasObject(path)
            val safeDisplayName = sanitizeDisplayName(displayName)
            val authority = "${applicationContext.packageName}.fileprovider"
            val uri = FileProvider.getUriForFile(
                this,
                authority,
                file,
                safeDisplayName,
            )
            val mimeType = mimeTypeFor(safeDisplayName)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri(safeDisplayName, uri)
            }

            try {
                startActivity(intent)
            } catch (_: ActivityNotFoundException) {
                result.error(NO_HANDLER_CODE, SAFE_OPEN_ERROR_MESSAGE, null)
                return
            }
            result.success(null)
        } catch (_: InvalidOpenFileRequest) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_OPEN_ERROR_MESSAGE, null)
        } catch (_: IOException) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_OPEN_ERROR_MESSAGE, null)
        } catch (_: SecurityException) {
            result.error(OPEN_FAILED_CODE, SAFE_OPEN_ERROR_MESSAGE, null)
        } catch (_: ClassCastException) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_OPEN_ERROR_MESSAGE, null)
        } catch (_: IllegalArgumentException) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_OPEN_ERROR_MESSAGE, null)
        }
    }

    private fun saveFileAs(call: MethodCall, result: MethodChannel.Result) {
        if (pendingExport != null) {
            result.error(BUSY_CODE, SAFE_ERROR_MESSAGE, null)
            return
        }

        try {
            val path = call.argument<String>(PATH_ARGUMENT)
                ?: throw InvalidOpenFileRequest()
            val displayName = call.argument<String>(DISPLAY_NAME_ARGUMENT)
                ?: throw InvalidOpenFileRequest()
            val file = validateCasObject(path)
            val safeDisplayName = sanitizeDisplayName(displayName)
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeTypeFor(safeDisplayName)
                putExtra(Intent.EXTRA_TITLE, safeDisplayName)
            }

            pendingExport = PendingExport(file, result)
            try {
                createDocumentLauncher.launch(intent)
            } catch (_: ActivityNotFoundException) {
                pendingExport = null
                result.error(NO_HANDLER_CODE, SAFE_ERROR_MESSAGE, null)
            } catch (_: IllegalStateException) {
                pendingExport = null
                result.error(EXPORT_FAILED_CODE, SAFE_ERROR_MESSAGE, null)
            } catch (_: SecurityException) {
                pendingExport = null
                result.error(EXPORT_FAILED_CODE, SAFE_ERROR_MESSAGE, null)
            } catch (_: RuntimeException) {
                // Do not leave a request permanently busy if the launcher
                // rejects the intent before the picker is displayed.
                pendingExport = null
                result.error(EXPORT_FAILED_CODE, SAFE_ERROR_MESSAGE, null)
            }
        } catch (_: InvalidOpenFileRequest) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_ERROR_MESSAGE, null)
        } catch (_: IOException) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_ERROR_MESSAGE, null)
        } catch (_: SecurityException) {
            result.error(EXPORT_FAILED_CODE, SAFE_ERROR_MESSAGE, null)
        } catch (_: ClassCastException) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_ERROR_MESSAGE, null)
        } catch (_: IllegalArgumentException) {
            result.error(INVALID_ARGUMENT_CODE, SAFE_ERROR_MESSAGE, null)
        }
    }

    private fun onCreateDocumentResult(activityResult: ActivityResult) {
        val pending = pendingExport ?: return
        pendingExport = null

        if (activityResult.resultCode != RESULT_OK) {
            settleResult(pending.result, false)
            return
        }

        val destination = activityResult.data?.data
        if (destination == null) {
            settleError(pending.result, EXPORT_FAILED_CODE)
            return
        }

        try {
            // Revalidate after the picker returns: the source must still be the
            // canonical, final CAS object and never a path supplied by a user.
            val source = validateCasObject(pending.source.path)
            copyToUri(source, destination)
            settleResult(pending.result, true)
        } catch (_: InvalidOpenFileRequest) {
            settleError(pending.result, INVALID_ARGUMENT_CODE)
        } catch (_: IOException) {
            settleError(pending.result, EXPORT_FAILED_CODE)
        } catch (_: SecurityException) {
            settleError(pending.result, EXPORT_FAILED_CODE)
        } catch (_: IllegalArgumentException) {
            settleError(pending.result, EXPORT_FAILED_CODE)
        }
    }

    private fun settleResult(result: MethodChannel.Result, selected: Boolean) {
        try {
            result.success(selected)
        } catch (_: RuntimeException) {
            // The engine may have detached while the picker was visible.
        }
    }

    private fun settleError(result: MethodChannel.Result, code: String) {
        try {
            result.error(code, SAFE_ERROR_MESSAGE, null)
        } catch (_: RuntimeException) {
            // The engine may have detached while the picker was visible.
        }
    }

    private fun copyToUri(source: File, destination: Uri) {
        FileInputStream(source).use { input ->
            val output = contentResolver.openOutputStream(destination, "rwt")
                ?: throw IOException("Unable to open destination")
            output.use { input.copyTo(it, COPY_BUFFER_SIZE) }
        }
    }

    /**
     * Accept only the exact final object layout produced by the CAS cache.
     * Canonical-path equality rejects symlinks in every path component, while
     * the shape checks reject traversal, parts and arbitrary app files.
     */
    private fun validateCasObject(rawPath: String): File {
        if (rawPath.isBlank() || rawPath.indexOf('\u0000') >= 0) {
            throw InvalidOpenFileRequest()
        }
        val input = File(rawPath)
        if (!input.isAbsolute) throw InvalidOpenFileRequest()

        if (rawPath.split(File.separatorChar).any { it == "." || it == ".." }) {
            throw InvalidOpenFileRequest()
        }
        val canonical = input.canonicalFile
        if (canonical.path != input.absolutePath) {
            throw InvalidOpenFileRequest()
        }

        val filesRoot = filesDir.canonicalFile
        val rootPrefix = filesRoot.path + File.separator
        if (!canonical.path.startsWith(rootPrefix)) {
            throw InvalidOpenFileRequest()
        }
        val relative = canonical.path.removePrefix(rootPrefix)
        val parts = relative.split(File.separatorChar)
        if (parts.size != 6 || parts[0] != CLOUD_CACHE_DIRECTORY) {
            throw InvalidOpenFileRequest()
        }

        val accountHash = parts[1]
        val firstPrefix = parts[3]
        val secondPrefix = parts[4]
        val objectHash = parts[5]
        if (!ACCOUNT_HASH.matches(accountHash) || parts[2] != OBJECTS_DIRECTORY) {
            throw InvalidOpenFileRequest()
        }
        if (!PREFIX.matches(firstPrefix) || !PREFIX.matches(secondPrefix)) {
            throw InvalidOpenFileRequest()
        }
        if (!OBJECT_HASH.matches(objectHash) ||
            objectHash.substring(0, 2) != firstPrefix ||
            objectHash.substring(2, 4) != secondPrefix ||
            objectHash.endsWith(PART_SUFFIX)
        ) {
            throw InvalidOpenFileRequest()
        }
        if (!canonical.isFile) throw InvalidOpenFileRequest()
        return canonical
    }

    private fun sanitizeDisplayName(rawName: String): String {
        val basename = rawName
            .replace('\\', '/')
            .substringAfterLast('/')
        if (basename.isBlank() || basename == "." || basename == "..") {
            throw InvalidOpenFileRequest()
        }
        if (basename.any { it.isISOControl() }) {
            throw InvalidOpenFileRequest()
        }
        return basename
    }

    private fun mimeTypeFor(displayName: String): String {
        val dot = displayName.lastIndexOf('.')
        if (dot <= 0 || dot == displayName.lastIndex) {
            return DEFAULT_MIME_TYPE
        }
        val extension = displayName.substring(dot + 1).lowercase(Locale.ROOT)
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: DEFAULT_MIME_TYPE
    }

    override fun onDestroy() {
        // The Dart attempt may already have been invalidated (logout, dispose,
        // or a newer foreground action). Settling the native callback is still
        // important so the old MethodChannel invocation cannot remain stuck.
        val pending = pendingExport
        pendingExport = null
        pending?.result?.let { settleError(it, ACTIVITY_DESTROYED_CODE) }
        super.onDestroy()
    }

    private class InvalidOpenFileRequest : Exception()

    private data class PendingExport(
        val source: File,
        val result: MethodChannel.Result,
    )

    private companion object {
        const val CHANNEL = "easy_cloud/file_opener"
        const val OPEN_FILE_METHOD = "openFile"
        const val SAVE_FILE_AS_METHOD = "saveFileAs"
        const val PATH_ARGUMENT = "path"
        const val DISPLAY_NAME_ARGUMENT = "displayName"
        const val NO_HANDLER_CODE = "NO_HANDLER"
        const val INVALID_ARGUMENT_CODE = "INVALID_ARGUMENT"
        const val OPEN_FAILED_CODE = "OPEN_FAILED"
        const val EXPORT_FAILED_CODE = "EXPORT_FAILED"
        const val ACTIVITY_DESTROYED_CODE = "ACTIVITY_DESTROYED"
        const val BUSY_CODE = "BUSY"
        const val SAFE_OPEN_ERROR_MESSAGE = "Не удалось открыть файл."
        const val SAFE_ERROR_MESSAGE = "Не удалось сохранить файл."
        const val CLOUD_CACHE_DIRECTORY = "cloud_cache"
        const val OBJECTS_DIRECTORY = "objects"
        const val PART_SUFFIX = ".part"
        const val DEFAULT_MIME_TYPE = "application/octet-stream"
        const val COPY_BUFFER_SIZE = 64 * 1024
        val ACCOUNT_HASH = Regex("[0-9a-f]{64}")
        val PREFIX = Regex("[0-9A-F]{2}")
        val OBJECT_HASH = Regex("[0-9A-F]{40}")
    }
}
