// Sustituye el contenido de client/android/app/src/main/kotlin/.../MainActivity.kt
// CONSERVA la primera línea "package ..." que ya tenga tu archivo (suele ser com.example.client).
package com.example.client

import android.Manifest
import android.app.UiModeManager
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var pipEnabled = false
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BookAudioService.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mistreaming/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "setPipEnabled" -> {
                    pipEnabled = (call.arguments as? Boolean) ?: false
                    result.success(null)
                }
                "enterPip" -> result.success(enterPip())
                "deviceName" -> result.success(deviceName())
                "isTv" -> result.success(isTv())
                "getBrightness" -> result.success(currentBrightness())
                "setBrightness" -> {
                    setBrightness(((call.arguments as? Number)?.toFloat()) ?: -1f)
                    result.success(null)
                }
                "appVersion" -> result.success(appVersion())
                "canInstallPackages" -> result.success(canInstall())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(null)
                }
                "installApk" -> result.success(installApk(call.arguments as? String))
                "startKeepAlive" -> { startKeepAlive(); result.success(null) }
                "stopKeepAlive" -> { stopService(Intent(this, KeepAliveService::class.java)); result.success(null) }
                "downloadProgress" -> {
                    val a = call.arguments as? Map<*, *>
                    KeepAliveService.showProgress(applicationContext,
                        (a?.get("title") as? String) ?: "Descargando",
                        (a?.get("text") as? String) ?: "",
                        ((a?.get("percent") as? Number)?.toInt()) ?: -1)
                    result.success(null)
                }
                "clearDownloadProgress" -> {
                    KeepAliveService.clearProgress(applicationContext)
                    result.success(null)
                }
                "notify" -> {
                    val a = call.arguments as? Map<*, *>
                    KeepAliveService.notifyEvent(applicationContext,
                        ((a?.get("id") as? Number)?.toInt()) ?: 0,
                        (a?.get("title") as? String) ?: "Lumen",
                        (a?.get("text") as? String) ?: "")
                    result.success(null)
                }
                "ignoringBatteryOpts" -> result.success(ignoringBattery())
                "requestIgnoreBatteryOpts" -> { requestIgnoreBattery(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        super.onNewIntent(intent)
        if (intent.action == BookAudioService.OPEN_BOOK) {
            flutterEngine?.let {
                MethodChannel(it.dartExecutor.binaryMessenger, "lumen/book_audio")
                    .invokeMethod("notificationTap", null)
            }
        }
    }

    /// ¿Es una TV / TV box? Modo de interfaz "televisión" o dispositivo con Leanback.
    private fun isTv(): Boolean {
        val ui = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        if (ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    /// Nombre del teléfono: el que muestra Ajustes (p. ej. "POCO X8 Pro"); si no hay,
    /// el nombre Bluetooth y, en último caso, fabricante + modelo.
    private fun deviceName(): String {
        fun read(get: () -> String?): String? =
            try { get()?.trim()?.takeIf { it.isNotEmpty() } } catch (_: Exception) { null }
        return read { Settings.Global.getString(contentResolver, "device_name") }
            ?: read { Settings.Secure.getString(contentResolver, "bluetooth_name") }
            ?: run {
                val maker = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
                val model = Build.MODEL.orEmpty()
                if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model".trim()
            }
    }

    /// Brillo de esta ventana (0..1); si no se ha tocado, el del sistema.
    private fun currentBrightness(): Double {
        val w = window.attributes.screenBrightness
        if (w >= 0f) return w.toDouble()
        return try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0
        } catch (_: Exception) {
            0.5
        }
    }

    /// Cambia el brillo solo de esta app; un valor negativo devuelve el brillo del sistema.
    private fun setBrightness(v: Float) {
        val lp = window.attributes
        lp.screenBrightness =
            if (v < 0f) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE else v.coerceIn(0.01f, 1f)
        window.attributes = lp
    }

    // ---------- actualización automática ----------
    /// Versión instalada: paquete, versionCode y versionName.
    private fun appVersion(): Map<String, Any> {
        val info = packageManager.getPackageInfo(packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
                   else @Suppress("DEPRECATION") info.versionCode.toLong()
        return mapOf("package" to packageName, "versionCode" to code,
                     "versionName" to (info.versionName ?: ""))
    }

    /// ¿Puede esta app instalar APK? (permiso "instalar apps desconocidas", Android 8+)
    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    /// Abre la pantalla de Ajustes donde se concede ese permiso a esta app.
    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val i = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i)
    }

    /// Lanza el instalador del sistema con el APK (por FileProvider). Devuelve "ok"
    /// o un código de error ("no_permission", "no_file", "error: ...").
    private fun installApk(path: String?): String {
        if (path == null) return "no_file"
        val f = File(path)
        if (!f.isFile) return "no_file"
        if (!canInstall()) return "no_permission"
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val i = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            "ok"
        } catch (e: Exception) {
            "error: ${e.message}"
        }
    }

    // ---------- segundo plano ----------
    private fun startKeepAlive() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 77)
        }
        try {
            val i = Intent(this, KeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
        } catch (_: Exception) {}
    }

    private fun ignoringBattery(): Boolean =
        (getSystemService(POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName)

    private fun requestIgnoreBattery() {
        val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i)
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val params = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
            .build()
        return enterPictureInPictureMode(params)
    }

    // Al pulsar Inicio con un video abierto, pasa a imagen en imagen.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipEnabled) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }
}
