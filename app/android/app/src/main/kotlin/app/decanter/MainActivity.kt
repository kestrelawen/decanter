package app.decanter

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Exposes exactly what the updater needs from the platform: a directory to stage
 * a downloaded APK in, whether this app is currently allowed to install packages,
 * and the handoff to the system installer.
 *
 * Deliberately not a plugin: it is four methods on one channel, and the app
 * already owns this file.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "app.decanter/updates"

    private val libraryChannelName = "app.decanter/library"

    /// The call waiting on a file pick, so the activity result answers the right one.
    private var pendingPick: MethodChannel.Result? = null

    /// Any value will do; it only has to be ours.
    private val pickRequestCode = 4821

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateDirectory" -> result.success(updateDirectory().absolutePath)

                    "canInstallPackages" -> result.success(canInstallPackages())

                    "openInstallSettings" -> result.success(openInstallSettings())

                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "No APK path was supplied.", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(true)
                            } catch (error: Exception) {
                                result.error(
                                    "install_failed",
                                    error.message ?: error.toString(),
                                    null
                                )
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // The library side: where files live, and how a card gets in.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, libraryChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "documentsDirectory" -> result.success(filesDir.absolutePath)

                    "pickCardFile" -> {
                        if (pendingPick != null) {
                            result.error("pick_busy", "A file picker is already open.", null)
                        } else {
                            pendingPick = result
                            try {
                                launchCardPicker()
                            } catch (error: Exception) {
                                pendingPick = null
                                result.error(
                                    "pick_unavailable",
                                    error.message ?: "No file picker available.",
                                    null
                                )
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Opens the system document picker.
     *
     * `startActivityForResult` rather than the `ActivityResultContracts` API,
     * because `FlutterActivity` extends a plain `Activity` and therefore has no
     * `registerForActivityResult` — that lives on `ComponentActivity`. Getting it
     * would mean basing this on `FlutterFragmentActivity` and adding an
     * androidx.fragment dependency to the compile classpath for the sake of one
     * file pick. The older API is deprecated but intact, and this is a single
     * request with a known code.
     */
    private fun launchCardPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, pickRequestCode)
    }

    /// Our own request is handled here; everything else keeps going to the
    /// Flutter engine, which forwards it to plugins.
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingPick
        pendingPick = null
        if (result == null) return

        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            // The user backed out of the picker. Not a failure.
            result.success(null)
            return
        }

        try {
            result.success(copyPickedFileToCache(uri))
        } catch (error: Exception) {
            result.error("pick_failed", error.message ?: "Could not read that file.", null)
        }
    }

    /**
     * Copies a picked document into the app's own cache and returns its path.
     *
     * The content URI is only readable while the grant lasts, and Dart cannot open
     * a content:// URI at all, so the bytes are materialised before returning.
     */
    private fun copyPickedFileToCache(uri: Uri): String {
        // A display name is attacker-adjacent input as far as the filesystem is
        // concerned, so separators are stripped before it becomes a path.
        val rawName = displayNameOf(uri) ?: "card"
        val name = rawName.replace('/', '_').replace('\\', '_')
        val directory = File(cacheDir, "picked")
        if (!directory.exists()) directory.mkdirs()
        val target = File(directory, name)

        val input = contentResolver.openInputStream(uri)
            ?: throw java.io.FileNotFoundException("Could not open $uri")
        input.use { source ->
            target.outputStream().use { sink -> source.copyTo(sink) }
        }
        return target.absolutePath
    }

    private fun displayNameOf(uri: Uri): String? {
        val cursor = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        ) ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index < 0) return null
            return it.getString(index)
        }
    }

    /** A directory this app owns, so the installer can be granted read on it. */
    private fun updateDirectory(): File {
        val base = getExternalFilesDir(null) ?: filesDir
        val directory = File(base, "updates")
        if (!directory.exists()) directory.mkdirs()
        return directory
    }

    /** Android 8+ gates "install unknown apps"; below that it is always allowed. */
    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    /**
     * Opens the per-app "install unknown apps" screen. Some OEM builds reject the
     * package-scoped URI, so fall back to the app list rather than crashing.
     */
    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        val scoped = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
            .setData(Uri.parse("package:$packageName"))
        return try {
            startActivity(scoped)
            true
        } catch (notSupported: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES))
                true
            } catch (alsoUnsupported: Exception) {
                false
            }
        }
    }

    private fun installApk(path: String) {
        val apk = File(path)
        if (!apk.exists()) {
            throw java.io.FileNotFoundException("No file at $path")
        }

        // The APK sits in our own storage, which the installer process cannot
        // read. Hand it over as a content:// URI with a one-shot read grant.
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }
}
