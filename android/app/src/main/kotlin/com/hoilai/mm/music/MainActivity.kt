package com.hoilai.mm.music

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.File

class MainActivity : AudioServiceActivity() {
    private data class PendingPublish(
        val sourcePath: String,
        val displayName: String,
        val mimeType: String,
        val result: MethodChannel.Result
    )

    private val pendingPublishes = mutableMapOf<Int, PendingPublish>()
    private var nextPublishRequestCode = 4100
    private val updateDownloads = mutableMapOf<Long, String>()
    private var downloadReceiverRegistered = false
    private var lyricsStateReceiverRegistered = false
    private var desktopLyricsChannel: MethodChannel? = null
    private var bassBoost: BassBoost? = null
    private var bassBoostSessionId: Int? = null
    private var equalizer: Equalizer? = null
    private var equalizerSessionId: Int? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var loudnessEnhancerSessionId: Int? = null

    private val downloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val downloadId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
            val fileName = updateDownloads.remove(downloadId) ?: return
            if (isDownloadSuccessful(downloadId)) {
                installDownloadedApk(fileName)
            }
        }
    }

    private val lyricsStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != LyricsOverlayService.ACTION_VISIBILITY_CHANGED) {
                return
            }
            desktopLyricsChannel?.invokeMethod(
                "onVisibilityChanged",
                mapOf(
                    "visible" to intent.getBooleanExtra(
                        LyricsOverlayService.EXTRA_VISIBLE,
                        false
                    ),
                    "userClosed" to intent.getBooleanExtra(
                        LyricsOverlayService.EXTRA_USER_CLOSED,
                        false
                    )
                )
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val enabled = call.arguments as? Boolean ?: false
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "moveTaskToBack" -> {
                        result.success(moveTaskToBack(true))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadAndInstallApk" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName") ?: "ka_music_update.apk"
                        if (url.isNullOrBlank()) {
                            result.error("invalid_url", "APK download url is empty", null)
                            return@setMethodCallHandler
                        }

                        runCatching {
                            enqueueApkDownload(url, fileName)
                        }.onSuccess {
                            result.success(null)
                        }.onFailure { error ->
                            result.error("download_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/downloads")
            .setMethodCallHandler { call, result ->
                runCatching {
                    when (call.method) {
                        "publish" -> {
                            val sourcePath = call.argument<String>("sourcePath")
                            val displayName = call.argument<String>("displayName")
                            val mimeType = call.argument<String>("mimeType") ?: "audio/mpeg"
                            require(!sourcePath.isNullOrBlank()) { "sourcePath is required" }
                            require(!displayName.isNullOrBlank()) { "displayName is required" }
                            if (needsLegacyStoragePermission()) {
                                requestPublishPermission(
                                    PendingPublish(sourcePath, displayName, mimeType, result)
                                )
                                return@setMethodCallHandler
                            }
                            publishToDownloads(sourcePath, displayName, mimeType)
                        }
                        "delete" -> {
                            val locator = call.argument<String>("locator")
                                ?: throw IllegalArgumentException("locator is required")
                            deletePublished(locator)
                            true
                        }
                        "size" -> {
                            val locator = call.argument<String>("locator")
                                ?: throw IllegalArgumentException("locator is required")
                            sizeOfPublished(locator)
                        }
                        else -> {
                            result.notImplemented()
                            return@setMethodCallHandler
                        }
                    }
                }.onSuccess { result.success(it) }
                    .onFailure { result.error("downloads_failed", it.message, null) }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kgka_music_hl/audio_effects")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getEqualizerConfig" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        runCatching {
                            equalizerConfig(audioSessionId)
                        }.onSuccess { config ->
                            result.success(config)
                        }.onFailure { error ->
                            result.error("equalizer_config_failed", error.message, null)
                        }
                    }
                    "configureEqualizer" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val levels = call.argument<List<Int>>("levels") ?: emptyList()

                        runCatching {
                            configureEqualizer(audioSessionId, enabled, levels)
                        }.onSuccess { supported ->
                            result.success(supported)
                        }.onFailure { error ->
                            releaseEqualizer()
                            result.error("equalizer_failed", error.message, null)
                        }
                    }
                    "configureBassBoost" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val strength = call.argument<Int>("strength") ?: 0

                        runCatching {
                            configureBassBoost(audioSessionId, enabled, strength)
                        }.onSuccess { supported ->
                            result.success(supported)
                        }.onFailure { error ->
                            releaseBassBoost()
                            result.error("bass_boost_failed", error.message, null)
                        }
                    }
                    "enableLoudnessEnhancer" -> {
                        val audioSessionId = call.argument<Int>("audioSessionId")
                        val gainMillibels = call.argument<Int>("gainMillibels") ?: 0

                        runCatching {
                            enableLoudnessEnhancer(audioSessionId, gainMillibels)
                        }.onSuccess {
                            result.success(true)
                        }.onFailure { error ->
                            result.error("loudness_failed", error.message, null)
                        }
                    }
                    "disableLoudnessEnhancer" -> {
                        releaseLoudnessEnhancer()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        desktopLyricsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kgka_music_hl/desktop_lyrics"
        )
        registerLyricsStateReceiver()
        desktopLyricsChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermission" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "requestPermission" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(null)
                    }
                    "show" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            result.error("no_permission", "No overlay permission", null)
                            return@setMethodCallHandler
                        }
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_LYRICS
                            putExtra(LyricsOverlayService.EXTRA_TITLE, title)
                            putExtra(LyricsOverlayService.EXTRA_ARTIST, artist)
                            putExtra(LyricsOverlayService.EXTRA_CURRENT_LYRIC, "")
                            putExtra(LyricsOverlayService.EXTRA_NEXT_LYRIC, "")
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "hide" -> {
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_HIDE
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "updateLyrics" -> {
                        val current = call.argument<String>("current") ?: ""
                        val next = call.argument<String>("next") ?: ""
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_LYRICS
                            putExtra(LyricsOverlayService.EXTRA_CURRENT_LYRIC, current)
                            putExtra(LyricsOverlayService.EXTRA_NEXT_LYRIC, next)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "updatePlayState" -> {
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_PLAY_STATE
                            putExtra(LyricsOverlayService.EXTRA_IS_PLAYING, isPlaying)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "isVisible" -> {
                        result.success(LyricsOverlayService.isRunning(this))
                    }
                    "updateKaraokeProgress" -> {
                        val progress = call.argument<Double>("progress")?.toFloat() ?: 0f
                        val lineDurationMs = call.argument<Int>("lineDurationMs") ?: 0
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_KARAOKE
                            putExtra(LyricsOverlayService.EXTRA_PROGRESS, progress)
                            putExtra(LyricsOverlayService.EXTRA_LINE_DURATION_MS, lineDurationMs)
                            putExtra(LyricsOverlayService.EXTRA_IS_PLAYING, isPlaying)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "updateSettings" -> {
                        val opacity = call.argument<Double>("opacity")?.toFloat() ?: 0.8f
                        val locked = call.argument<Boolean>("locked") ?: false
                        val passthrough = call.argument<Boolean>("passthrough") ?: false
                        val textColorLong = call.argument<Long>("textColor") ?: 0xFFFFFFFF
                        val backgroundColorLong = call.argument<Long>("backgroundColor") ?: 0xFF1A1A2E
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 16f
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_UPDATE_SETTINGS
                            putExtra(LyricsOverlayService.EXTRA_OPACITY, opacity)
                            putExtra(LyricsOverlayService.EXTRA_LOCKED, locked)
                            putExtra(LyricsOverlayService.EXTRA_PASSTHROUGH, passthrough)
                            putExtra(LyricsOverlayService.EXTRA_TEXT_COLOR, textColorLong.toInt())
                            putExtra(LyricsOverlayService.EXTRA_BACKGROUND_COLOR, backgroundColorLong.toInt())
                            putExtra(LyricsOverlayService.EXTRA_FONT_SIZE, fontSize)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "setAppForeground" -> {
                        val isForeground = call.argument<Boolean>("isForeground") ?: false
                        val intent = Intent(this, LyricsOverlayService::class.java).apply {
                            action = LyricsOverlayService.ACTION_SET_APP_FOREGROUND
                            putExtra(LyricsOverlayService.EXTRA_IS_FOREGROUND, isForeground)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun registerLyricsStateReceiver() {
        if (lyricsStateReceiverRegistered) {
            return
        }
        val filter = IntentFilter(LyricsOverlayService.ACTION_VISIBILITY_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(lyricsStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(lyricsStateReceiver, filter)
        }
        lyricsStateReceiverRegistered = true
    }

    private fun equalizerConfig(audioSessionId: Int?): Map<String, Any>? {
        if (audioSessionId == null || audioSessionId <= 0) {
            return null
        }
        val effect = ensureEqualizer(audioSessionId)
        val range = effect.bandLevelRange
        val bands = (0 until effect.numberOfBands).map { index ->
            val band = index.toShort()
            mapOf(
                "centerHz" to effect.getCenterFreq(band) / 1000,
                "level" to effect.getBandLevel(band).toInt()
            )
        }
        return mapOf(
            "range" to listOf(range[0].toInt(), range[1].toInt()),
            "bands" to bands
        )
    }

    private fun configureEqualizer(
        audioSessionId: Int?,
        enabled: Boolean,
        levels: List<Int>
    ): Boolean {
        if (!enabled) {
            releaseEqualizer()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = ensureEqualizer(audioSessionId)
        val range = effect.bandLevelRange
        val bandCount = minOf(effect.numberOfBands.toInt(), levels.size)
        for (index in 0 until bandCount) {
            val level = levels[index].coerceIn(range[0].toInt(), range[1].toInt())
            effect.setBandLevel(index.toShort(), level.toShort())
        }
        effect.enabled = true
        return true
    }

    private fun ensureEqualizer(audioSessionId: Int): Equalizer {
        if (equalizerSessionId == audioSessionId && equalizer != null) {
            return equalizer!!
        }
        releaseEqualizer()
        return Equalizer(0, audioSessionId).also {
            equalizer = it
            equalizerSessionId = audioSessionId
        }
    }

    private fun releaseEqualizer() {
        equalizer?.runCatching {
            enabled = false
            release()
        }
        equalizer = null
        equalizerSessionId = null
    }

    private fun configureBassBoost(
        audioSessionId: Int?,
        enabled: Boolean,
        strength: Int
    ): Boolean {
        if (!enabled) {
            releaseBassBoost()
            return true
        }
        if (audioSessionId == null || audioSessionId <= 0) {
            return false
        }

        val effect = if (bassBoostSessionId == audioSessionId && bassBoost != null) {
            bassBoost!!
        } else {
            releaseBassBoost()
            BassBoost(0, audioSessionId).also {
                bassBoost = it
                bassBoostSessionId = audioSessionId
            }
        }

        val clampedStrength = strength.coerceIn(0, 1000).toShort()
        if (effect.strengthSupported) {
            effect.setStrength(clampedStrength)
        } else {
            effect.setStrength(if (clampedStrength > 0) 1000 else 0)
        }
        effect.enabled = true
        return true
    }

    private fun releaseBassBoost() {
        bassBoost?.runCatching {
            enabled = false
            release()
        }
        bassBoost = null
        bassBoostSessionId = null
    }

    private fun enqueueApkDownload(url: String, fileName: String) {
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle("KA Music 更新包")
            .setDescription("正在下载新版本")
            .setMimeType("application/vnd.android.package-archive")
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, fileName)

        val downloadManager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        val downloadId = downloadManager.enqueue(request)
        updateDownloads[downloadId] = fileName
        registerDownloadReceiver()
    }

    private fun registerDownloadReceiver() {
        if (downloadReceiverRegistered) {
            return
        }
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(downloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(downloadReceiver, filter)
        }
        downloadReceiverRegistered = true
    }

    private fun isDownloadSuccessful(downloadId: Long): Boolean {
        val downloadManager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        val query = DownloadManager.Query().setFilterById(downloadId)
        var cursor: Cursor? = null
        return try {
            cursor = downloadManager.query(query)
            cursor != null &&
                cursor.moveToFirst() &&
                cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) ==
                DownloadManager.STATUS_SUCCESSFUL
        } finally {
            cursor?.close()
        }
    }

    private fun needsLegacyStoragePermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED

    private fun requestPublishPermission(pending: PendingPublish) {
        val requestCode = nextPublishRequestCode++
        pendingPublishes[requestCode] = pending
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            requestCode
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val pending = pendingPublishes.remove(requestCode) ?: return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            pending.result.error("downloads_permission", "需要存储权限才能保存到下载目录", null)
            return
        }
        runCatching {
            publishToDownloads(pending.sourcePath, pending.displayName, pending.mimeType)
        }.onSuccess { pending.result.success(it) }
            .onFailure { pending.result.error("downloads_failed", it.message, null) }
    }

    private fun publishToDownloads(
        sourcePath: String,
        displayName: String,
        mimeType: String
    ): String {
        val source = File(sourcePath)
        require(source.isFile && source.length() > 0) { "源文件不存在或为空" }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return publishWithMediaStore(source, displayName, mimeType)
        }
        @Suppress("DEPRECATION")
        return publishToPublicDirectory(source, displayName)
    }

    private fun publishWithMediaStore(
        source: File,
        displayName: String,
        mimeType: String
    ): String {
        val resolver = contentResolver
        val relativePath = Environment.DIRECTORY_DOWNLOADS + "/KA Music"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("无法创建下载条目")
        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("无法写入下载条目")
            output.use { out ->
                source.inputStream().use { input -> input.copyTo(out) }
            }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                null,
                null
            )
        } catch (error: Throwable) {
            resolver.delete(uri, null, null)
            throw error
        }
        return uri.toString()
    }

    @Suppress("DEPRECATION")
    private fun publishToPublicDirectory(source: File, displayName: String): String {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "KA Music"
        )
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("无法创建下载目录")
        }
        val target = File(directory, displayName)
        source.inputStream().use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), null, null)
        return target.absolutePath
    }

    private fun deletePublished(locator: String) {
        if (locator.startsWith("content://")) {
            contentResolver.delete(Uri.parse(locator), null, null)
            return
        }
        val file = File(locator)
        if (file.exists()) {
            file.delete()
        }
    }

    private fun sizeOfPublished(locator: String): Long {
        if (locator.startsWith("content://")) {
            val uri = Uri.parse(locator)
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (index >= 0) return cursor.getLong(index)
                    }
                }
            return 0L
        }
        val file = File(locator)
        return if (file.isFile) file.length() else 0L
    }

    private fun installDownloadedApk(fileName: String) {
        val apkFile = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), fileName)
        if (!apkFile.exists()) {
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )
        val installIntent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apkUri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(installIntent)
    }

    private fun enableLoudnessEnhancer(audioSessionId: Int?, gainMillibels: Int) {
        if (audioSessionId == null || audioSessionId <= 0) return
        if (loudnessEnhancerSessionId != audioSessionId || loudnessEnhancer == null) {
            releaseLoudnessEnhancer()
            LoudnessEnhancer(audioSessionId).also {
                loudnessEnhancer = it
                loudnessEnhancerSessionId = audioSessionId
            }
        }
        val clamped = gainMillibels.coerceIn(0, 3000)
        loudnessEnhancer?.setTargetGain(clamped)
        loudnessEnhancer?.enabled = true
    }

    private fun releaseLoudnessEnhancer() {
        loudnessEnhancer?.runCatching {
            enabled = false
            release()
        }
        loudnessEnhancer = null
        loudnessEnhancerSessionId = null
    }

    override fun onDestroy() {
        releaseEqualizer()
        releaseBassBoost()
        releaseLoudnessEnhancer()
        if (downloadReceiverRegistered) {
            unregisterReceiver(downloadReceiver)
            downloadReceiverRegistered = false
        }
        if (lyricsStateReceiverRegistered) {
            unregisterReceiver(lyricsStateReceiver)
            lyricsStateReceiverRegistered = false
        }
        super.onDestroy()
    }
}
