> 文档编号：KA-05-01
> 级别：L1 📌
> 状态：现行
> 关联代码：android/app/src/main/kotlin/com/hoilai/mm/music/MainActivity.kt（515 行）、LyricsOverlayService.kt（500 行）、KaraokeTextView.kt（143 行）、android/app/src/main/AndroidManifest.xml、android/app/src/main/res/xml/update_file_paths.xml、android/app/src/main/res/layout/overlay_lyrics.xml、android/app/src/main/res/drawable/overlay_background.xml、lib/services/audio_effects_service.dart、lib/services/desktop_lyrics_service.dart、lib/services/app_update_service.dart、lib/services/volume_normalization_service.dart、lib/ui/pages/app_shell.dart、lib/ui/pages/player_page.dart、lib/controllers/player_controller.dart
> 最近更新：2026-09-08
> 变更触发条件：新增/删除自建 MethodChannel 或通道方法、改动 MainActivity / LyricsOverlayService / KaraokeTextView、改动 AndroidManifest 的组件声明、改动 audio_effects 的参数范围或默认值时，必须同步更新本文

# Android 原生集成

## TL;DR

- Android 侧共 **4 个自建 MethodChannel**（`kgka_music_hl/screen`、`kgka_music_hl/update`、`kgka_music_hl/audio_effects`、`kgka_music_hl/desktop_lyrics`）+ **1 条原生→Dart 回调**（`onVisibilityChanged`），全部在 `MainActivity.configureFlutterEngine` 中注册（`MainActivity.kt:66-282`）。
- 宿主 Activity 继承 audio_service 的 `AudioServiceActivity`（`MainActivity.kt:23`），**不是裸 FlutterActivity**；音频效果实例、下载完成广播、悬浮窗状态广播都挂在它上面，`onDestroy` 统一释放（`MainActivity.kt:501-514`）。
- 原生能力只有 3 个 Kotlin 文件，Dart 侧每个调用入口都先做 Android 平台判定，非 Android 直接短路返回，**不存在跨平台原生实现**。

---

## 1. 现状：原生代码清单

| 文件 | 行数 | 职责 | 关键入口 |
|---|---|---|---|
| `android/app/src/main/kotlin/com/hoilai/mm/music/MainActivity.kt` | 515 | 4 条 MethodChannel 注册、均衡器/低音增强/LoudnessEnhancer 实例管理、APK 下载安装、悬浮窗广播接收 | `configureFlutterEngine:66` |
| `.../LyricsOverlayService.kt` | 500 | 桌面歌词前台服务：悬浮窗渲染、拖动、卡拉OK 进度插值、设置持久化 | `onStartCommand:111` |
| `.../KaraokeTextView.kt` | 143 | 自绘歌词 View：底字 + 按进度裁剪的高亮字 | `onDraw:117` |
| `android/app/src/main/AndroidManifest.xml` | 90 | 权限、组件、FileProvider 声明 | 见 KA-05-03 |
| `android/app/src/main/res/xml/update_file_paths.xml` | 6 | FileProvider 可共享路径（`external-files-path Download/`） | — |
| `android/app/src/main/res/layout/overlay_lyrics.xml` | 70 | 悬浮窗布局（KaraokeTextView + 下一句 + 锁定/关闭按钮） | — |
| `android/app/src/main/res/drawable/overlay_background.xml` | 9 | 悬浮窗圆角背景（`#CC1A1A2E`，圆角 12dp，0.5dp 描边） | — |

> 说明：任务下发时的行数标注（482 / 452 / 123）与当前代码不符，实际为 515 / 500 / 143 行，以代码为准。

---

## 2. 通道总览

| 通道名 | Dart 侧定义 | Kotlin 侧注册 | 方法数 | 方向 |
|---|---|---|---|---|
| `kgka_music_hl/screen` | `lib/ui/pages/app_shell.dart:44`、`lib/ui/pages/player_page.dart:42` | `MainActivity.kt:69` | 2 | Dart → 原生 |
| `kgka_music_hl/update` | `lib/services/app_update_service.dart:10` | `MainActivity.kt:88` | 1 | Dart → 原生 |
| `kgka_music_hl/audio_effects` | `lib/services/audio_effects_service.dart:63`、`lib/services/volume_normalization_service.dart:24` | `MainActivity.kt:111` | 5 | Dart → 原生 |
| `kgka_music_hl/desktop_lyrics` | `lib/services/desktop_lyrics_service.dart:64` | `MainActivity.kt:172` | 10 + 1 回调 | 双向 |

未匹配到的方法一律走 `result.notImplemented()`（`MainActivity.kt:84,107,168,279`），Dart 侧表现为 `MissingPluginException`。

---

## 3. screen 通道（屏幕常亮 / 退到后台）

| 方法 | 参数 | 返回值 | Kotlin 实现 | Dart 调用点 | 异常处理 |
|---|---|---|---|---|---|
| `setKeepScreenOn` | `Boolean enabled`（非 Boolean 时按 `false`） | `null` | `MainActivity.kt:72-80` | `player_page.dart:108-116` | Dart 捕获 `MissingPluginException` 与 `PlatformException` 并忽略 |
| `moveTaskToBack` | 无 | `Boolean`（`moveTaskToBack(true)` 结果） | `MainActivity.kt:81-83` | `app_shell.dart:201-208` | Dart `catch(_)` 吞掉，保持路由不销毁 |

行为细节：

- `setKeepScreenOn(true)` 给窗口加 `FLAG_KEEP_SCREEN_ON`，`false` 清除（`MainActivity.kt:75-78`）。
- 触发条件由 Dart 决定：`_appResumed && routeCurrent && player.isPlaying`（`player_page.dart:90-97`），页面 dispose 时显式关闭（`player_page.dart:63`）。
- 返回键拦截只在 Android 生效：`defaultTargetPlatform != TargetPlatform.android` 时直接返回原 scaffold，不包 `PopScope`（`app_shell.dart:187-198`）。

---

## 4. update 通道（应用内安装 APK）

### 4.1 方法契约

| 方法 | 参数 | 默认值 | 返回值 | Kotlin 实现 | 错误码 |
|---|---|---|---|---|---|
| `downloadAndInstallApk` | `String url`、`String fileName` | `fileName` 缺省 `ka_music_update.apk` | `null`（入队成功即返回） | `MainActivity.kt:91-106` | `invalid_url`（url 空）、`download_failed`（enqueue 抛错） |

### 4.2 Dart 侧封装

| 项 | 值 | 锚点 |
|---|---|---|
| 平台判定 | `!kIsWeb && defaultTargetPlatform == TargetPlatform.android` | `app_update_service.dart:14-16` |
| 检查更新 | 非 Android 直接返回 `null`；Android 调 `_api.latestAppVersion(AppUpdatePlatform.android)` | `app_update_service.dart:18-28` |
| 是否新版本 | `versionCode > int(AppConfig.appVersionCode)`（当前 `220`） | `app_version.dart:35-38`、`app_config.dart:8` |
| 安装调用 | 非 Android 抛 `UnsupportedError`；无下载地址抛 `StateError` | `app_update_service.dart:30-42` |
| APK 文件名 | `ka_music_{versionName}.apk`，非法字符 `[^0-9A-Za-z._-]` 替换为 `_`，空则用 `latest` | `app_update_service.dart:44-51` |

### 4.3 下载与安装链路（Kotlin）

| 步骤 | 实现 | 说明 |
|---|---|---|
| 1. 入队下载 | `enqueueApkDownload:403-417` | `DownloadManager.Request`：标题「KA Music 更新包」、MIME `application/vnd.android.package-archive`、允许计费网络与漫游、`VISIBILITY_VISIBLE_NOTIFY_COMPLETED`、目标目录 `getExternalFilesDir(DIRECTORY_DOWNLOADS)/fileName` |
| 2. 登记回调 | `updateDownloads[downloadId] = fileName`（`:415`） | 内存 Map，进程被杀后丢失 |
| 3. 注册广播 | `registerDownloadReceiver:419-431` | 监听 `DownloadManager.ACTION_DOWNLOAD_COMPLETE`，Android 13+ 用 `Context.RECEIVER_NOT_EXPORTED` |
| 4. 判定成功 | `isDownloadSuccessful:433-446` | 查询 `COLUMN_STATUS == STATUS_SUCCESSFUL`，cursor 在 finally 关闭 |
| 5. 未知来源校验 | `installDownloadedApk:454-464` | `Build.VERSION.SDK_INT >= O && !packageManager.canRequestPackageInstalls()` 时跳转 `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES` 并 return |
| 6. 触发安装 | `installDownloadedApk:466-475` | `FileProvider.getUriForFile(this, "$packageName.fileprovider", apkFile)` + `ACTION_VIEW` + `FLAG_GRANT_READ_URI_PERMISSION` + `FLAG_ACTIVITY_NEW_TASK` |

### 4.4 FileProvider 配置

| 项 | 值 | 锚点 |
|---|---|---|
| 组件 | `androidx.core.content.FileProvider` | `AndroidManifest.xml:64-72` |
| authority | `${applicationId}.fileprovider` | `AndroidManifest.xml:66` |
| exported / grantUriPermissions | `false` / `true` | `AndroidManifest.xml:67-68` |
| 路径配置 | `@xml/update_file_paths` | `AndroidManifest.xml:71` |
| 可共享目录 | `external-files-path`，name `ka_music_updates`，path `Download/` | `update_file_paths.xml:3-5` |
| 权限 | `android.permission.REQUEST_INSTALL_PACKAGES` | `AndroidManifest.xml:8` |

### 4.5 升级 UI 入口

| 入口 | 行为 | 锚点 |
|---|---|---|
| 设置页「关于」 | 非 Android 时副标题退化为「版本与更新日志」 | `settings_page.dart:339-351` |
| 手动检查 | 非 Android 直接 return；有更新弹窗，强制更新时 `barrierDismissible=false` 且 `PopScope(canPop:false)` | `app_update_widgets.dart:72-106,108-160` |

---

## 5. audio_effects 通道（均衡器 / 低音增强 / 音量提升）

### 5.1 方法契约

| 方法 | 参数 | 默认值 | 返回值 | Kotlin 实现 | 错误码 |
|---|---|---|---|---|---|
| `getEqualizerConfig` | `int audioSessionId` | 无 | `Map`：`range` + `bands`；sessionId ≤ 0 时返回 `null` | `MainActivity.kt:114-123` + `equalizerConfig:298-315` | `equalizer_config_failed` |
| `configureEqualizer` | `int audioSessionId`、`bool enabled`、`List<Int> levels` | `enabled=false`、`levels=[]` | `bool`（未启用时恒 `true`，sessionId ≤ 0 时 `false`） | `MainActivity.kt:124-137` + `configureEqualizer:317-339` | `equalizer_failed`（并先释放实例） |
| `configureBassBoost` | `int audioSessionId`、`bool enabled`、`int strength` | `enabled=false`、`strength=0` | `bool`（同均衡器语义） | `MainActivity.kt:138-151` + `configureBassBoost:361-392` | `bass_boost_failed`（并先释放实例） |
| `enableLoudnessEnhancer` | `int audioSessionId`、`int gainMillibels` | `gainMillibels=0` | 恒 `true` | `MainActivity.kt:152-163` + `enableLoudnessEnhancer:478-490` | `loudness_failed` |
| `disableLoudnessEnhancer` | 无 | — | 恒 `true` | `MainActivity.kt:164-167` + `releaseLoudnessEnhancer:492-499` | 无（内部 runCatching） |

### 5.2 返回值结构（`getEqualizerConfig`）

| 字段 | 类型 | 单位 | 来源 |
|---|---|---|---|
| `range[0]` | `int` | 毫贝（mB） | `Equalizer.bandLevelRange[0]`（`MainActivity.kt:303,312`） |
| `range[1]` | `int` | 毫贝（mB） | `Equalizer.bandLevelRange[1]` |
| `bands[].centerHz` | `int` | 赫兹（Hz，已除以 1000） | `Equalizer.getCenterFreq(band) / 1000`（`MainActivity.kt:307`） |
| `bands[].level` | `int` | 毫贝（mB） | `Equalizer.getBandLevel(band).toInt()`（`MainActivity.kt:308`） |

Dart 侧解析：`EqualizerConfig.fromMap`（`audio_effects_service.dart:44-59`）缺省 `range = [-1200, 1200]`；设备能力获取失败时用固定 10 段回退配置（31 / 62 / 125 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 16000 Hz，`audio_effects_service.dart:29-42`）。

### 5.3 参数取值范围与钳制

| 参数 | Dart 侧范围 | Kotlin 侧钳制 | 生效条件 |
|---|---|---|---|
| 均衡器段增益 | `equalizerConfig.minMillibels ~ maxMillibels`（回退 −1200 ~ 1200） | `coerceIn(range[0], range[1])`（`MainActivity.kt:334`） | `audioSessionId > 0` |
| 低音增强强度 | 归一化 `0.0 ~ 1.0` → `(strength * 1000).round()`（`audio_effects_service.dart:128-133`） | `coerceIn(0, 1000)`；`strengthSupported == false` 时退化为「有强度即 1000」（`MainActivity.kt:384-389`） | 同上 |
| LoudnessEnhancer 增益 | `(gainDb * 100).round().clamp(0, 3000)`（`volume_normalization_service.dart:155`） | `coerceIn(0, 3000)`（`MainActivity.kt:487`） | 同上，且仅 Android（`volume_normalization_service.dart:151-154`） |

### 5.4 两个 Dart 调用方

| 调用方 | 覆盖方法 | 锚点 |
|---|---|---|
| `AudioEffectsService` | `getEqualizerConfig` / `configureEqualizer` / `configureBassBoost` | `audio_effects_service.dart:71-142` |
| `VolumeNormalizationService` | `enableLoudnessEnhancer` / `disableLoudnessEnhancer`（**不经 AudioEffectsService**） | `volume_normalization_service.dart:157,197` |

调用时机：`PlayerController` 订阅 `audioPlayer.androidAudioSessionIdStream`，session 变化时依次刷新配置、应用均衡器、应用低音增强、应用音量均衡（`player_controller.dart:169-177`）。

### 5.5 实例生命周期（Kotlin）

| 效果器 | 复用条件 | 释放时机 |
|---|---|---|
| `Equalizer` | `equalizerSessionId == audioSessionId && equalizer != null`（`:342`） | 关闭均衡器、session 变化、配置抛错、`onDestroy` |
| `BassBoost` | 同上（`:374`） | 关闭低音增强、session 变化、配置抛错、`onDestroy` |
| `LoudnessEnhancer` | `loudnessEnhancerSessionId == audioSessionId && != null`（`:480`） | `disableLoudnessEnhancer`、session 变化、`onDestroy` |

所有释放都走 `runCatching { enabled = false; release() }`，失败静默（`MainActivity.kt:353-357,394-398,492-496`）。

---

## 6. desktop_lyrics 通道（桌面歌词）

### 6.1 Dart → 原生方法

| 方法 | 参数 | Kotlin 默认值 | 返回值 | Kotlin 实现 |
|---|---|---|---|---|
| `checkPermission` | 无 | — | `Boolean`（`Settings.canDrawOverlays(this)`） | `MainActivity.kt:179-181` |
| `requestPermission` | 无 | — | `null`（跳转系统悬浮窗授权页） | `MainActivity.kt:182-190` |
| `show` | `title`、`artist` | `""` | `null`；无权限时 `error("no_permission")` | `MainActivity.kt:191-207` |
| `hide` | 无 | — | `null` | `MainActivity.kt:208-214` |
| `updateLyrics` | `current`、`next` | `""` | `null` | `MainActivity.kt:215-225` |
| `updatePlayState` | `isPlaying` | `false` | `null` | `MainActivity.kt:226-234` |
| `isVisible` | 无 | — | `Boolean`（`LyricsOverlayService.isRunning`） | `MainActivity.kt:235-237` |
| `updateKaraokeProgress` | `progress`、`lineDurationMs`、`isPlaying` | `0.0` / `0` / `false` | `null` | `MainActivity.kt:238-250` |
| `updateSettings` | `opacity`、`locked`、`passthrough`、`textColor`、`backgroundColor`、`fontSize` | `0.8` / `false` / `false` / `0xFFFFFFFF` / `0xFF1A1A2E` / `16.0` | `null` | `MainActivity.kt:251-269` |
| `setAppForeground` | `isForeground` | `false` | `null` | `MainActivity.kt:270-278` |

### 6.2 原生 → Dart 回调

| 回调方法 | 参数 | 触发点 | Kotlin 实现 | Dart 处理 |
|---|---|---|---|---|
| `onVisibilityChanged` | `visible`、`userClosed` | 悬浮窗显示/隐藏 | `MainActivity.kt:45-64`（接收 `ACTION_VISIBILITY_CHANGED` 广播） | `desktop_lyrics_service.dart:83-95` → `PlayerController._handleDesktopLyricsVisibility:2262-2274` |

用户从悬浮窗点「关闭」时，Dart 侧把 `settings.desktop_lyrics_enabled` 写回 `false`（`player_controller.dart:2266-2273`）。

### 6.3 Dart 侧封装与容错

| 行为 | 说明 | 锚点 |
|---|---|---|
| 平台判定 | 仅 Android（`!kIsWeb && defaultTargetPlatform == TargetPlatform.android`） | `desktop_lyrics_service.dart:72-74` |
| `show` 失败 | 捕获 `PlatformException` / `MissingPluginException` 返回 `false` | `desktop_lyrics_service.dart:117-130` |
| 其余方法失败 | 仅吞 `MissingPluginException`，静默忽略 | `desktop_lyrics_service.dart:108-115,132-202` |
| 显示条件 | `desktopLyricsEnabled && currentSong != null && (!_isAppForeground || _desktopLyricsPreviewVisible)` | `player_controller.dart:2102-2106` |
| 权限缺失 | 开关自动回滚为 `false` 并触发系统授权页 | `player_controller.dart:2084-2092` |
| 设置持久化 | `settings.desktop_lyrics_settings` 存 JSON，启动时回灌原生 | `player_controller.dart:2222-2233,2542-2554` |
| 歌词进度 | 有词级数据与无词级数据走同一 `updateKaraokeProgress`，行时长缺省时按「下一行时间差」或「曲尾」估算 | `player_controller.dart:2157-2220` |

---

## 7. LyricsOverlayService 细节

### 7.1 声明

| 项 | 值 | 锚点 |
|---|---|---|
| 组件 | `.LyricsOverlayService`，`exported="false"` | `AndroidManifest.xml:56-59` |
| 前台服务类型 | `specialUse` | `AndroidManifest.xml:59` |
| 用途声明 | `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE`（悬浮歌词说明文本） | `AndroidManifest.xml:60-62` |
| 通知渠道 | `kgka_music_hl.lyrics_overlay`，`IMPORTANCE_LOW`，`setShowBadge(false)` | `LyricsOverlayService.kt:28,459-472` |
| 通知 ID | `9001`，`setOngoing(true)`，点击回到主界面（`FLAG_IMMUTABLE`） | `LyricsOverlayService.kt:29,474-494` |
| 返回策略 | `START_STICKY` | `LyricsOverlayService.kt:158` |

### 7.2 Action 与 Extra 常量

| Action | 字符串 | 处理位置 |
|---|---|---|
| `ACTION_UPDATE_LYRICS` | `com.hoilai.mm.music.UPDATE_LYRICS` | `:113-122` |
| `ACTION_UPDATE_PLAY_STATE` | `com.hoilai.mm.music.UPDATE_PLAY_STATE` | `:123-126` |
| `ACTION_HIDE` | `com.hoilai.mm.music.HIDE_LYRICS` | `:127-130` |
| `ACTION_UPDATE_KARAOKE` | `com.hoilai.mm.music.UPDATE_KARAOKE` | `:131-136` |
| `ACTION_UPDATE_SETTINGS` | `com.hoilai.mm.music.UPDATE_SETTINGS` | `:137-150` |
| `ACTION_SET_APP_FOREGROUND` | `com.hoilai.mm.music.SET_APP_FOREGROUND` | `:151-156` |
| `ACTION_VISIBILITY_CHANGED` | `com.hoilai.mm.music.LYRICS_VISIBILITY_CHANGED` | 发送于 `:451-457` |

| Extra | 键名 | 默认值 |
|---|---|---|
| `EXTRA_CURRENT_LYRIC` | `current_lyric` | `""` |
| `EXTRA_NEXT_LYRIC` | `next_lyric` | `""` |
| `EXTRA_TITLE` | `title` | `""` |
| `EXTRA_ARTIST` | `artist` | `""` |
| `EXTRA_PROGRESS` | `progress` | `0f` |
| `EXTRA_LINE_DURATION_MS` | `line_duration_ms` | `0` |
| `EXTRA_IS_PLAYING` | `is_playing` | `false` |
| `EXTRA_IS_FOREGROUND` | `is_foreground` | `false` |
| `EXTRA_OPACITY` | `opacity` | 沿用当前值（默认 0.8） |
| `EXTRA_LOCKED` | `locked` | 沿用当前值（默认 false） |
| `EXTRA_PASSTHROUGH` | `passthrough` | 沿用当前值（默认 false） |
| `EXTRA_TEXT_COLOR` | `text_color` | `Color.WHITE` |
| `EXTRA_BACKGROUND_COLOR` | `background_color` | `#1A1A2E` |
| `EXTRA_FONT_SIZE` | `font_size` | `16f` |
| `EXTRA_VISIBLE` | `visible` | `false` |
| `EXTRA_USER_CLOSED` | `user_closed` | `false` |

### 7.3 悬浮窗参数

| 项 | 值 | 锚点 |
|---|---|---|
| 宽高 | `WRAP_CONTENT × WRAP_CONTENT` | `:191-193` |
| Window type | Android 8+ `TYPE_APPLICATION_OVERLAY`，否则 `TYPE_PHONE` | `:194-198` |
| 默认 flags | `FLAG_NOT_FOCUSABLE or FLAG_NOT_TOUCH_MODAL` | `:220-221` |
| 触摸穿透追加 | `FLAG_NOT_TOUCHABLE` | `:222-224` |
| 对齐 | `Gravity.TOP or Gravity.START` | `:202` |
| 默认坐标 | `x=50, y=100`（来自 SharedPreferences） | `:203-205` |
| 拖动阈值 | 位移 > 10px 才判定为拖动 | `:250-252` |
| 锁定行为 | `isLocked` 时不可拖动，且自动开启触摸穿透 | `:141,182,247,417` |
| 持久化 | SharedPreferences `lyrics_overlay_prefs`，键：`pos_x` / `pos_y` / `opacity` / `locked` / `passthrough` / `text_color` / `background_color` / `font_size` | `:56-64,413-433` |

### 7.4 卡拉OK 进度插值

| 项 | 说明 | 锚点 |
|---|---|---|
| 驱动器 | `Choreographer.postFrameCallback` 逐帧回调 | `:316-342` |
| 锚点 | `karaokeAnchorProgress` + `karaokeAnchorUptimeMs`（`SystemClock.uptimeMillis()`） | `:292-294` |
| 每帧计算 | `anchor + elapsed / lineDurationMs`，钳制 `0..1` | `:328-331` |
| 停止条件 | 未播放、行时长 ≤ 0、进度 ≥ 1 | `:322-325` |
| 行切换 | `ACTION_UPDATE_LYRICS` 会先 `stopKaraokeTicker()` 再重置进度为 0 | `:277-285` |

### 7.5 `isRunning` 判定

`LyricsOverlayService.isRunning` 通过 `ActivityManager.getRunningServices(Int.MAX_VALUE)` 比对类名（`LyricsOverlayService.kt:66-75`）。该 API 已标记废弃，且 Android 8+ 只返回调用方自身的服务；本用途（判断自己的服务是否存活）仍成立，但属于**技术债**。

---

## 8. KaraokeTextView 自绘逻辑

| 成员 | 类型 | 默认值 | 说明 | 锚点 |
|---|---|---|---|---|
| `text` | `String` | `""` | 变更时 `requestLayout() + invalidate()` | `:36-43` |
| `baseColor` | `Int` | `Color.argb(90,255,255,255)` | 底字颜色 | `:45-50` |
| `activeColor` | `Int` | `Color.WHITE` | 高亮字颜色 | `:52-57` |
| `textSizeSp` | `Float` | `16f` | SP → px 换算后设置到两个 Paint | `:59-69` |
| `progress` | `Float` | `0f` | 0.0~1.0，变化 > 0.001 才重绘 | `:72-79` |
| `maxLines` | `Int` | `2` | 仅参与高度测量 | `:81` |
| `basePaint` / `activePaint` | `Paint` | `ANTI_ALIAS_FLAG`、`Align.LEFT`、`isFakeBoldText = true` | 两套画刷 | `:24-32` |

| 绘制步骤 | 逻辑 | 锚点 |
|---|---|---|
| `onMeasure` | `EXACTLY` 用给定宽度；`AT_MOST` 取文本宽与上限较小值；否则取文本宽。高度 = `(bottom - top + leading) × maxLines` + 上下 padding | `:93-115` |
| 基线 | `y = paddingTop - fontMetrics.top` | `:122` |
| 底字 | 整句用 `basePaint` 画一遍 | `:125` |
| 高亮 | 裁剪矩形 `(x, 0, x + 文本总宽 × progress, height)`，在裁剪区内用 `activePaint` 重画 | `:128-141` |

原生设置与 Dart 设置的对应关系：`applySettings` 把 `textColor` 同步给 `activeColor`，把 `textColor` 取 alpha 90 作为 `baseColor`，把 `fontSizeSp` 同步给 `textSizeSp`（`LyricsOverlayService.kt:359-367`）；下一句歌词用半透明色（`:370-376`）。

---

## 9. MainActivity 配置与生命周期

| 项 | 值 | 锚点 |
|---|---|---|
| 类声明 | `class MainActivity : AudioServiceActivity()` | `MainActivity.kt:23` |
| 清单声明 | `.MainActivity`，`exported="true"`，`launchMode="singleTop"`，`taskAffinity=""` | `AndroidManifest.xml:17-25` |
| 主题 | 启动 `@style/LaunchTheme`，首帧后 `io.flutter.embedding.android.NormalTheme` | `AndroidManifest.xml:22,30-33` |
| configChanges | `orientation, keyboardHidden, keyboard, screenSize, smallestScreenSize, locale, layoutDirection, fontScale, screenLayout, density, uiMode` | `AndroidManifest.xml:23` |
| 其他 | `hardwareAccelerated="true"`、`windowSoftInputMode="adjustResize"` | `AndroidManifest.xml:24-25` |
| 通道注册 | `configureFlutterEngine` 内顺序：screen → update → audio_effects → desktop_lyrics（含注册广播） | `MainActivity.kt:66-282` |

| 广播接收器 | 监听 | 注册时机 | 注销 | 锚点 |
|---|---|---|---|---|
| `downloadReceiver` | `DownloadManager.ACTION_DOWNLOAD_COMPLETE` | 首次入队下载时惰性注册，标志 `downloadReceiverRegistered` | `onDestroy` | `:35-43,419-431,505-508` |
| `lyricsStateReceiver` | `ACTION_VISIBILITY_CHANGED` | `configureFlutterEngine` 中注册，标志 `lyricsStateReceiverRegistered` | `onDestroy` | `:45-64,284-296,509-512` |

两个接收器在 Android 13+ 都用 `Context.RECEIVER_NOT_EXPORTED` 注册，低版本走废弃重载（`:289-294,424-429`）。

`onDestroy` 释放顺序：`releaseEqualizer()` → `releaseBassBoost()` → `releaseLoudnessEnhancer()` → 注销两个广播 → `super.onDestroy()`（`MainActivity.kt:501-514`）。

---

## 10. 平台版本要求

| 特性 | 最低要求 | 依据 |
|---|---|---|
| `minSdkVersion` | 24 | 合并清单 `build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml:8` |
| `targetSdkVersion` | 36 | 同上 `:9` |
| 悬浮窗（`TYPE_APPLICATION_OVERLAY`） | API 26 | `LyricsOverlayService.kt:194-198` |
| 悬浮窗权限页（`ACTION_MANAGE_OVERLAY_PERMISSION`） | API 23 | `MainActivity.kt:182-190` |
| 通知渠道（`NotificationChannel`） | API 26 | `LyricsOverlayService.kt:459-472` |
| `registerReceiver` 带 flags 重载 | API 33 | `MainActivity.kt:289,424` |
| `canRequestPackageInstalls` | API 26 | `MainActivity.kt:454-456` |
| 前台服务类型声明（`mediaPlayback`） | API 29 声明 / API 34 强制 | `AndroidManifest.xml:41`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK` `:7` |
| `specialUse` 前台服务类型 | API 34 | `AndroidManifest.xml:59-62`、`FOREGROUND_SERVICE_SPECIAL_USE` `:10` |

---

## 11. 约束与坑

1. **通道契约没有单一来源**。Dart 与 Kotlin 各自硬编码字符串，改名不会编译报错，只会运行期 `MissingPluginException`（如 `app_update_service.dart:10` 对 `MainActivity.kt:88`）。
2. **`audio_effects` 的 Dart 封装不完整**：LoudnessEnhancer 的两个方法只存在于 Kotlin（`MainActivity.kt:152-167`）与 `VolumeNormalizationService`（`volume_normalization_service.dart:157,197`），`AudioEffectsService` 未暴露。
3. **未声明 `POST_NOTIFICATIONS`**（清单 8 条权限中无此项，全项目 grep 无申请代码）。桌面歌词通知与 audio_service 媒体通知在 Android 13+ 的实际可见性**待核实**。
4. **`startService` 全部未做异常处理**（`MainActivity.kt:205,212,223,232,248,267,276`）。Android 8+ 后台执行限制下，若进程不处于前台服务状态，从后台启动服务可能抛 `IllegalStateException`，当前无兜底。
5. **下载安装链路无 Dart 侧反馈**：`downloadAndInstallApk` 入队即返回 `null`，下载失败时 `downloadReceiver` 静默丢弃（`:38-41`），用户只看到「更新包下载中」提示（`app_update_widgets.dart:124`）。
6. **`updateDownloads` 是内存 Map**，进程被杀后已完成下载不会再触发安装。
7. **均衡器段数由设备决定**，Dart 回退配置固定 10 段；当设备段数更少时，`configureEqualizer` 只配置 `min(设备段数, levels.size)` 段（`MainActivity.kt:332-336`），多余滑块无效。
8. **效果器只在 `audioSessionId > 0` 时生效**；session 变化会释放重建，期间短暂失效。
9. **`isRunning` 依赖已废弃 API**（`LyricsOverlayService.kt:66-75`），未来 Android 版本行为可能变化。
10. **锁定与触摸穿透强耦合**：锁定会自动打开穿透，取消锁定时穿透保持原值（`LyricsOverlayService.kt:141,182,417`；Dart 侧同样逻辑 `desktop_lyrics_settings_page.dart:121-137`）。
11. **音量均衡「提升」路径依赖 Android 原生**，非 Android 平台直接旁路（`volume_normalization_service.dart:151-168`）；同时控制器默认参考响度 `-14.0`（`player_controller.dart:326`）与服务默认 `-11.0`（`volume_normalization_service.dart:45`）**不一致**，见「待办」。

---

## 12. 待办与关联

| 待办 | 说明 | 优先级 |
|---|---|---|
| 统一通道常量为单一契约文件 | Dart 与 Kotlin 共享通道名/方法名常量，消除字符串漂移 | 中 |
| 补齐 `AudioEffectsService` 的 LoudnessEnhancer 封装 | 把 `volume_normalization_service.dart` 里的裸通道调用收敛到服务层 | 中 |
| 核实 Android 13+ 通知可见性 | 确认是否需要 `POST_NOTIFICATIONS` 及申请时机 | 高 |
| `startService` 加异常兜底 | 包裹 `runCatching` 并把失败回传 Dart | 中 |
| 下载安装回传结果 | 增加 `onDownloadResult` 回调或轮询接口 | 低 |
| 参考响度默认值对齐 | 控制器 −14.0 与服务 −11.0 二选一 | 中 |
| `isRunning` 换实现 | 用静态标志位或 `ActivityManager` 替代方案 | 低 |

关联文档：

- 多平台判定依据与平台矩阵：`./多平台差异矩阵.md`
- 权限与清单逐条说明：`./权限与清单配置.md`
- 播放链路与效果器应用时序：`../03-模块详解/控制器层-PlayerController.md`
- 设置键与持久化键位：`../04-数据与接口/本地存储与配置项清单.md`
- 技术债登记：`../06-质量保障/已知问题与技术债台账.md`
