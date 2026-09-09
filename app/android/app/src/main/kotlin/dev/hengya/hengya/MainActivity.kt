package dev.hengya.hengya

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
 * 应用内更新（batch3 node1，云直链单通道）原生桥。
 *
 * 唯一 MethodChannel：dev.hengya.hengya/update，方法（全部返回 Map，错误不抛异常）：
 *  - getPackageInfo            -> {versionName: String, versionCode: Long}
 *  - canRequestInstall         -> {canRequestInstall: Boolean}（Android 8+ 安装未知应用授权态）
 *  - installApk {path}         -> {ok: true} | {ok: false, code, message}
 *                                 code: not_authorized / file_not_found / no_activity / error
 *  - openInstallPermissionSettings -> {ok: true}
 *    Android 8+ 跳「安装未知应用」授权页；更老系统跳应用详情设置。
 *
 * APK 经 FileProvider（authorities = dev.hengya.hengya.update_provider）只读共享给
 * 系统安装器；下载目录为 dataDir/update/（见 res/xml/update_file_paths.xml）。
 */
class MainActivity : FlutterActivity() {

    companion object {
private const val UPDATE_CHANNEL = "dev.hengya.hengya/update"
private const val UPDATE_PROVIDER_AUTHORITY = "dev.hengya.hengya.update_provider"
        private const val MIME_APK = "application/vnd.android.package-archive"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPackageInfo" -> {
                        try {
                            val pi = packageManager.getPackageInfo(packageName, 0)
                            val versionCode = if (Build.VERSION.SDK_INT >= 28) {
                                pi.longVersionCode
                            } else {
                                @Suppress("DEPRECATION")
                                pi.versionCode.toLong()
                            }
                            result.success(
                                mapOf(
                                    "versionName" to (pi.versionName ?: ""),
                                    "versionCode" to versionCode,
                                )
                            )
                        } catch (e: Exception) {
                            result.success(errMap("error", e.message ?: "getPackageInfo failed"))
                        }
                    }
                    "canRequestInstall" -> {
                        val can = Build.VERSION.SDK_INT < 26 ||
                            packageManager.canRequestPackageInstalls()
                        result.success(mapOf("canRequestInstall" to can))
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.success(errMap("bad_args", "path is required"))
                        } else {
                            installApk(result, path)
                        }
                    }
                    "openInstallPermissionSettings" -> {
                        openInstallPermissionSettings()
                        result.success(mapOf("ok" to true))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun errMap(code: String, message: String): Map<String, Any?> =
        mapOf("ok" to false, "code" to code, "message" to message)

    /**
     * 唤起系统安装器（用户在系统弹窗点一下确认）。
     * Android 8+ 未授「安装未知应用」→ 结构化错误 not_authorized（Dart 引导跳授权页）。
     */
    private fun installApk(result: MethodChannel.Result, path: String) {
        try {
            val file = File(path)
            if (!file.exists()) {
                result.success(errMap("file_not_found", "APK not found: $path"))
                return
            }
            if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                result.success(errMap("not_authorized", "install unknown apps not granted"))
                return
            }
            val uri = FileProvider.getUriForFile(this, UPDATE_PROVIDER_AUTHORITY, file)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, MIME_APK)
                .addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK
                )
            try {
                startActivity(intent)
                result.success(mapOf("ok" to true))
            } catch (e: Exception) {
                result.success(errMap("no_activity", e.message ?: "no activity to install apk"))
            }
        } catch (e: Exception) {
            result.success(errMap("error", e.message ?: "install failed"))
        }
    }

    /** 跳「安装未知应用」授权页（Android 8+）；失败或更老系统回退应用详情设置。 */
    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT >= 26) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return
            } catch (_: Exception) {
                // 个别 ROM 无此页面 → 回退应用详情设置
            }
        }
        openAppDetailsSettings()
    }

    private fun openAppDetailsSettings() {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Exception) {
            // 最后一级也失败：静默（Dart 侧文案已引导用户手动到设置）
        }
    }
}
