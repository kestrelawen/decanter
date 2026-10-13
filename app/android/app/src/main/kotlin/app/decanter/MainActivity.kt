package app.decanter

import android.content.Intent
import android.net.Uri
import android.os.Build
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
