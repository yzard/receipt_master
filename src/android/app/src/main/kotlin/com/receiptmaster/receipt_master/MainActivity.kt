package com.receiptmaster.receipt_master

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class UpdateFileProvider : FileProvider()

class MainActivity : FlutterActivity() {
    private val updateWorker = Executors.newSingleThreadExecutor()
    private fun hash(file: File): String = file.inputStream().use { input ->
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(65536)
        while (true) {
            val size = input.read(buffer)
            if (size < 0) break
            digest.update(buffer, 0, size)
        }
        digest.digest().joinToString("") { "%02x".format(it) }
    }
    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signatureFlags(): Int =
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            ?.map { it.toCharsString() }?.toSet() ?: emptySet()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "receipt_master/android_update")
            .setMethodCallHandler { call, result ->
                if (call.method !in setOf("installedApp", "installUpdate")) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                updateWorker.execute {
                    try {
                        val installed = packageManager.getPackageInfo(packageName, signatureFlags())
                        if (call.method == "installedApp") {
                            val value = mapOf("version_code" to version(installed),
                                "version_name" to installed.versionName,
                                "sha256" to hash(File(applicationInfo.sourceDir)),
                                "abis" to Build.SUPPORTED_ABIS.toList())
                            runOnUiThread { result.success(value) }
                        } else {
                            val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                            require(file == File(cacheDir, "updates/client.apk").canonicalFile) { "Invalid update path" }
                            require(hash(file) == call.argument<String>("sha256")) { "APK hash mismatch" }
                            val archive = requireNotNull(packageManager.getPackageArchiveInfo(file.path, signatureFlags())) { "Invalid APK" }
                            require(archive.packageName == packageName) { "Wrong application package" }
                            require(version(archive) == call.argument<Number>("version_code")?.toLong() && version(archive) >= version(installed)) { "Invalid update version" }
                            require(signatures(installed).isNotEmpty() && signatures(installed) == signatures(archive)) { "APK signing identity differs" }
                            runOnUiThread {
                                try {
                                    if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                                        result.success("permission_required")
                                    } else {
                                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                                        startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                        result.success("installer_opened")
                                    }
                                } catch (error: Exception) {
                                    result.error("install_error", "无法打开系统安装器：${error.message}", null)
                                }
                            }
                        }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("update_error", "更新校验失败：${error.message}", null) }
                    }
                }
            }
    }
    override fun onDestroy() {
        updateWorker.shutdown()
        super.onDestroy()
    }
}
