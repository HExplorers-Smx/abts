package dev.pages.abts

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.app.PendingIntent
import android.content.pm.PackageInstaller
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private var audioManager: AudioManager? = null
    private var focusCallback: EventChannel.EventSink? = null
    private var focusRequest: AudioFocusRequest? = null

    private val focusListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 打断结束：通知 Dart 侧续播
                focusCallback?.success("gained")
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 来电/导航等暂时打断：暂停并等待恢复
                focusCallback?.success("interrupted")
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 短暂提示音：仅降低音量，不中断播放
                focusCallback?.success("ducked")
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                // 被其他播放器永久抢占：暂停且不自动恢复
                focusCallback?.success("lost")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // 音频焦点
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/audio_focus",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> result.success(requestFocus())
                "abandon" -> {
                    abandonFocus()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/audio_focus_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                focusCallback = events
            }

            override fun onCancel(arguments: Any?) {
                focusCallback = null
            }
        })

        // 保存图片到相册
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/gallery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "saveImage" -> {
                    val base64 = call.argument<String>("base64")
                    val name = call.argument<String>("name") ?: "image"
                    if (base64 == null) {
                        result.success(null)
                    } else {
                        result.success(saveImageToGallery(base64, name))
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 电池优化（后台留存）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/battery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoring" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }

                "requestIgnore" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                    } catch (_: Exception) {
                        try {
                            startActivity(Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS))
                        } catch (_: Exception) {
                            // 系统无对应设置页时忽略
                        }
                    }
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        // 内置更新：安装下载好的 APK
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "abts/installer",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    result.success(installApk(call.argument<String>("path")))
                }

                else -> result.notImplemented()
            }
        }
    }

    /** 是否已授予「安装未知来源应用」权限（Android 8+ 调起安装器前必须检查） */
    private fun canInstallApk(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    /** 打开系统「安装未知来源应用」权限设置页（Android 8+） */
    private fun openInstallPermissionSettings() {
        try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
            intent.data = Uri.parse("package:$packageName")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            // 部分 ROM 不支持带包名跳转，退化为应用详情页
            try {
                val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                fallback.data = Uri.parse("package:$packageName")
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fallback)
            } catch (e2: Exception) {
                // 都打不开就算了，由 Dart 侧提示用户手动去设置
            }
        }
    }

    /**
     * 安装下载好的 APK，返回 {ok, message}：
     *
     * 1) 优先用 PackageInstaller 会话安装（系统推荐路径，不依赖外部安装器
     *    Activity 的兼容性，且能拿到具体异常原因）；
     * 2) 失败回退 ACTION_VIEW + FileProvider（传统拉起系统安装器）；
     * 3) 仍失败且权限未授予 → 打开「安装未知来源应用」设置页。
     *
     * 不再把 canRequestPackageInstalls() 当作硬门槛：部分 ROM（如 ColorOS）
     * 在权限已开启时该 API 仍可能误报，直接尝试安装、失败再引导，更可靠。
     */
    private fun installApk(path: String?): Map<String, Any?> {
        if (path.isNullOrEmpty()) {
            return mapOf("ok" to false, "message" to "安装包路径为空")
        }
        val file = java.io.File(path)
        if (!file.exists() || file.length() == 0L) {
            return mapOf("ok" to false, "message" to "安装包不存在或未下载完整，请重新下载")
        }

        // 记录 PackageInstaller 失败原因（供兜底提示与排查）
        var sessionError: String? = null

        // 1) PackageInstaller 会话安装（Android 5.0+）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                val sessionParams =
                    PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                // createSession 返回会话 ID，须再 openSession 拿到可写会话
                val sessionId = packageManager.packageInstaller.createSession(sessionParams)
                val session = packageManager.packageInstaller.openSession(sessionId)
                try {
                    file.inputStream().use { input ->
                        val out = session.openWrite(file.name, 0, file.length())
                        input.copyTo(out)
                        session.fsync(out)
                        out.close()
                    }
                    // commit 后系统会弹出安装确认界面（非 root 必现）；
                    // 结果通过 statusReceiver 回调（此处回调无消费方，仅满足非空参数）
                    val statusReceiver = PendingIntent.getActivity(
                        this, 0, Intent(this, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE,
                    ).intentSender
                    session.commit(statusReceiver)
                    return mapOf("ok" to true, "message" to "已提交系统安装，请按屏幕提示完成安装")
                } finally {
                    session.close()
                }
            } catch (e: Exception) {
                // 权限不足 / ROM 不支持：记录原因，继续走 ACTION_VIEW 兜底
                sessionError = e.message
            }
        }

        // 2) ACTION_VIEW + FileProvider 兜底
        return try {
            val apkUri: Uri =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    androidx.core.content.FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        file,
                    )
                } else {
                    Uri.fromFile(file)
                }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(apkUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            if (sessionError.isNullOrEmpty()) {
                mapOf("ok" to true, "message" to "已拉起系统安装器，请按屏幕提示完成安装")
            } else {
                mapOf(
                    "ok" to true,
                    "message" to "已拉起系统安装器（会话安装不可用：$sessionError），请按屏幕提示完成安装",
                )
            }
        } catch (e: Exception) {
            // 3) 仍失败：引导「安装未知来源应用」权限
            if (!canInstallApk()) {
                openInstallPermissionSettings()
            }
            mapOf(
                "ok" to false,
                "message" to "系统拒绝安装（${e.message ?: "未知原因"}）。若提示缺少权限，请开启「允许从此来源安装应用」后重试",
            )
        }
    }

    private fun requestFocus(): Boolean {
        val am = audioManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .setAcceptsDelayedFocusGain(true)
                .build()
            focusRequest = request
            val r = am.requestAudioFocus(request)
            r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED || r == AudioManager.AUDIOFOCUS_REQUEST_DELAYED
        } else {
            val r = am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
            r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 必须使用同一个 AudioFocusRequest 实例才能真正释放
            val request = focusRequest ?: return
            am.abandonAudioFocusRequest(request)
            focusRequest = null
        } else {
            am.abandonAudioFocus(focusListener)
        }
    }

    /** 保存 PNG 到系统相册，返回保存路径；失败返回 null */
    private fun saveImageToGallery(base64: String, name: String): String? {
        return try {
            val bytes = android.util.Base64.decode(base64, android.util.Base64.DEFAULT)
            val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: return null
            val fileName = if (name.endsWith(".png")) name else "$name.png"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, fileName)
                    put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(
                        android.provider.MediaStore.Images.Media.RELATIVE_PATH,
                        "Pictures/阿B听书",
                    )
                    put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: return null
                contentResolver.openOutputStream(uri)?.use { os ->
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, os)
                }
                values.clear()
                values.put(android.provider.MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                uri.toString()
            } else {
                @Suppress("DEPRECATION")
                val dir = java.io.File(
                    android.os.Environment.getExternalStoragePublicDirectory(
                        android.os.Environment.DIRECTORY_PICTURES,
                    ),
                    "阿B听书",
                )
                if (!dir.exists() && !dir.mkdirs()) return null
                val file = java.io.File(dir, fileName)
                java.io.FileOutputStream(file).use { os ->
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, os)
                }
                android.media.MediaScannerConnection.scanFile(
                    this,
                    arrayOf(file.absolutePath),
                    arrayOf("image/png"),
                    null,
                )
                file.absolutePath
            }
        } catch (e: Exception) {
            null
        }
    }
}