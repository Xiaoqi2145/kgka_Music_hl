# KA Music - 项目状态记录

> 保存时间：2026-09-08
> 项目路径：E:\Project\Codex\Project\KAmusic
> Flutter 版本：3.44.4（D:\SDK\Flutter）
> Android SDK：37（D:\SDK\Android）
> JDK：21（D:\SDK\Java\jdk-21）

---

## 一、已完成功能

### 音量均衡（LUFS-Based Volume Leveling）

基于曲目 LUFS 响度数据的音量归一化，参照 EchoMusic 实现。

**控制工程视角（钱学森《工程控制论》）：**
- 纯前馈控制系统：LUFS 数据在播放开始前已知，增益一次计算
- 参考输入：用户配置的目标 LUFS（-16 ~ -6 dB，默认 -14）
- 增益计算：`gain = 10^((refLUFS - trackLUFS)/20)` + 服务端建议增益 + 峰值限制
- 执行器：Android `LoudnessEnhancer`（提升）或 `just_audio.setVolume`（衰减）

**新增文件：**

| 文件 | 说明 |
|------|------|
| `lib/models/loudness_data.dart` | LoudnessData 模型（lufs/gain/peak，JSON 解析） |
| `lib/services/volume_normalization_service.dart` | 核心服务：增益计算、双路径策略、LUFS 缓存 |

**修改文件：**

| 文件 | 说明 |
|------|------|
| `lib/models/music_models.dart` | PlayUrl 增加 `LoudnessData? loudness` 字段 |
| `lib/controllers/player_controller.dart` | 添加服务实例、设置存取、`_applyVolumeNormalization()`、切歌时缓存+应用 |
| `lib/ui/pages/settings_page.dart` | 设置页新增音量均衡开关 + 参考响度滑块 (-16 ~ -6 LUFS) |
| `lib/services/music_api.dart` | 加 debugPrint 验证 API 是否返回 volume 字段 |
| `android/.../MainActivity.kt` | audio_effects 通道添加 `enableLoudnessEnhancer`/`disableLoudnessEnhancer` |

### 缩略图缓存（Artwork Cache）

封面缩略图的磁盘缓存，目标是「看过一次的封面离线也能显示」，同时避免无上限增长。

**存储位置：** `getApplicationSupportDirectory()/ka_music_artwork/`
（Android 实为 `/data/user/0/com.hoilai.mm.music/files/ka_music_artwork/`，属于 app 数据目录，不会被系统「清除缓存」回收）

**缓存键：** `base64Url(utf8(url))` 去掉 `=` 填充 + `.img`；封面 URL 统一由 `normalizeImageUrl` 请求 480px 档。

**读取链路：**

```
API JSON → normalizeImageUrl(url, size: 480) → Song.coverUrl
  ├─ Artwork 组件（列表/详情封面）→ Image.file
  └─ CachedArtworkImage（播放页背景图）→ ImageProvider
        └─ ArtworkCacheService.load(url)
             ├─ 磁盘命中 → 刷新 mtime（LRU 依据）→ 直接解码
             ├─ 在途请求 → 复用 _pending 中的同一个 Future
             └─ 未命中   → HttpClient 下载 → .part → 原子 rename
```

**容量控制：**

| 项 | 值 |
|------|------|
| 默认上限 | 512MB（`AppConfig.defaultArtworkCacheMaxBytes`） |
| 可调范围 | 64MB ~ 4GB |
| 持久化键 | `settings.artwork_cache_max_bytes` |
| 淘汰策略 | LRU，按文件最后访问时间升序删除至上限以内 |
| 触发时机 | 启动扫描一次 + 每次新增缓存后 |

**设置入口：** 设置 → 缓存管理 → 缩略图缓存（占用大小 / 一键清理）+ 上限输入框

**新增文件：**

| 文件 | 说明 |
|------|------|
| `lib/ui/widgets/cached_artwork_image.dart` | 把磁盘缓存包装成 `ImageProvider`；播放页背景图与同屏封面共享同一次下载 |
| `test/artwork_cache_lru_test.dart` | `selectLruEvictions` 纯函数单测（7 例） |
| `test/cached_artwork_image_test.dart` | provider 相等性、同 URL 并发只发一次请求、磁盘命中不再请求（3 例） |

**修改文件：**

| 文件 | 说明 |
|------|------|
| `lib/services/artwork_cache_service.dart` | LRU 淘汰、可配置上限、内存计数、`selectLruEvictions` 纯函数 |
| `lib/config/app_config.dart` | 新增缩略图缓存上限常量 |
| `lib/ui/pages/settings_page.dart` | 缓存管理新增缩略图缓存条目与上限输入（与播放缓存共用 `_CacheLimitInput`） |
| `lib/ui/pages/player_page.dart` | `_ArtworkBackground` 背景图由 `Image.network` 改为 `CachedArtworkImage` |
| `lib/services/cache_service.dart` | 数据缓存不再聚合缩略图，改为独立展示与清理 |
| `lib/main.dart` | 启动时 `ArtworkCacheService.initialize()` 加载上限并扫描一次 |

**有意不缓存的位置：** 首页大卡（猜你喜欢 / 新碟上架）、FM 头图、歌手头图仍用 `Image.network`——这些图属于用后即弃，不进磁盘缓存，以免占用条目和淘汰压力。

**已知待改进：**

- `_prune` 用扫描快照覆盖内存计数（`artwork_cache_service.dart:250`），扫描期间并发下载的增量会被丢弃，导致计数偏小、上限可能被突破；应改为按删除量扣减或维护内存索引。
- 淘汰只到硬上限、无低水位：达到上限后每次新增缓存都会触发一次全目录扫描（每文件 2 次 syscall），万级文件时有卡顿风险。
- `.part` 残留文件不计入大小/条目，启动时也不清理。
- 无失败缓存：断网时每个未缓存封面都会重试一次 8s 连接超时。

---

## 二、音量均衡设置项

**位置：** 设置 → 播放 → 音量均衡

- **开关：** "音量均衡" — subtitle: "自动统一不同歌曲的播放音量"
- **参考响度滑块（仅开关开启时显示）：** -16 ~ -6 LUFS，步进 1，默认 -14
- 滑块右侧显示当前值标签，如 "-14 LUFS"

**SharedPreferences 持久化：**
- `settings.volume_normalization_enabled` (bool)
- `settings.volume_normalization_ref_lufs` (double)

---

## 三、音量均衡实现细节

### 增益计算算法（`VolumeNormalizationService.computeGainLinear`）

```dart
double? computeGainLinear(LoudnessData? data) {
  if (data == null || !data.isValid) return null;
  double gain = pow(10.0, (referenceLufs - data.lufs!) / 20.0);
  if (data.gain != null && data.gain != 0.0) {
    gain *= pow(10.0, data.gain! / 20.0);
  }
  if (data.peak != null && data.peak! > 0) {
    gain = min(gain, 0.95 / data.peak!);
  }
  return gain.clamp(0.1, 3.0);
}
```

### 双路径增益策略

| 增益范围 | 路径 | 实现 |
|---------|------|------|
| > 0.5 dB | 提升 | Android `LoudnessEnhancer`（MethodChannel） |
| < -0.5 dB | 衰减 | `just_audio.setVolume(gainLinear)` |
| 其余 | 旁路 | 不做处理 |

### LUFS 数据来源

- **API 字段：** `volume`（LUFS）、`volume_gain`（dB）、`volume_peak`（0~1）
- **API 端点：** `/song/url` 响应中
- 如果 API 未透传，音量均衡自动旁路（不影响正常播放）
- 内存缓存：`Map<String, LoudnessData>` keyed by 歌曲 hash

---

## 四、已知问题 / 待改进

### 4.1 API 响度数据透传

App 侧已完整解析并接入 LUFS 数据：`PlayUrl.fromJson` → `LoudnessData.fromJson` 读取 `volume`/`volume_gain`/`volume_peak`；增益计算、双路径策略、Native `LoudnessEnhancer` 及单测均已完成（`volume_normalization_service_test.dart`、`playback_loudness_test.dart`、`player_normalization_test.dart` 共 18 例全通过）。

唯一剩余的验证点在后端：`/song/url`（及 `/user/cloud/url`）响应是否真的透传了酷狗的 `volume`/`volume_gain`/`volume_peak`。若后端未返回，`LoudnessData.lufs` 为 null、`canNormalize` 为 false，音量均衡会静默旁路（gain=1.0），不影响正常播放。运行时确认（Flutter 日志走 logcat 的 `flutter` tag）：

```bash
adb logcat | grep -iE "loudness|VolumeNorm"
```

`music_api.dart` 的 `songUrl` 已打印响应 keys 与 `volume=...`，出现 `[KA Music][loudness] /song/url response keys: ...` 且含 `volume=` 即后端已透传。

### 4.2 背景图片渲染延迟

用户反馈自定义背景图在页面切换时延迟 ~0.7s。
- 尝试过预加载字节、预解码 `ui.Image`、架构分离等方案，均未彻底解决
- 当前方案已全部回退，`theme_controller.dart` 和 `main.dart` 保持原版
- 如需修复，建议方向：`Image.file()` 的缓存键问题或 Navigator 过渡动画的同步问题

### 4.3 Android 构建

- 构建时提示 `file_picker` 插件使用 Kotlin Gradle Plugin（KGP），未来 Flutter 版本可能不兼容
- 当前仅构建 `arm64-v8a` ABI

### 4.4 音量均衡增强

- LUFS 数据已本地持久化：下载/播放缓存曲目经 `updateLocalLoudness`（download_controller.dart）写回，内存缓存为有界 `LoudnessLookup`（`retainKeys`/`_retryAfter` 限定播放窗口）
- 仍未实现：为纯本地文件做离线 LUFS 计算
- 未实现 iOS 平台支持（LoudnessEnhancer 仅 Android）
- 归一化增益与用户音量的交互可进一步优化（当前衰减路径直接 `setVolume`）

---

## 五、构建命令

```bash
# 安装依赖
flutter pub get

# Debug APK
flutter build apk --debug

# Release APK
flutter build apk --release

# 安装到设备
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 查看日志
adb logcat | grep "loudness\|VolumeNorm"
```

---

## 六、项目文件结构（仅 lib/）

```
lib/
├── config/
│   └── app_config.dart
├── controllers/
│   ├── auth_controller.dart
│   ├── download_controller.dart
│   ├── local_music_controller.dart
│   ├── player_controller.dart      # 修改：音量均衡集成
│   └── theme_controller.dart
├── core/
│   └── api_client.dart
├── main.dart
├── models/
│   ├── app_version.dart
│   ├── loudness_data.dart          # 新增：响度数据模型
│   └── music_models.dart           # 修改：PlayUrl + loudness
├── services/
│   ├── app_update_service.dart
│   ├── artwork_cache_service.dart  # 新增：缩略图磁盘缓存（LRU + 可配置上限）
│   ├── audio_effects_service.dart
│   ├── cache_service.dart
│   ├── desktop_lyrics_service.dart
│   ├── download_service.dart
│   ├── music_api.dart              # 修改：songUrl 调试打印
│   ├── music_audio_handler.dart
│   ├── playback_history_service.dart
│   ├── playback_stats_service.dart
│   ├── search_history_service.dart
│   ├── vip_background_task.dart
│   └── volume_normalization_service.dart  # 新增：音量均衡核心
└── ui/
    ├── adaptive_layout.dart
    ├── app_theme.dart
    ├── pages/
    │   └── settings_page.dart       # 修改：音量均衡 UI
    └── widgets/
        ├── artwork.dart              # 封面组件
        └── cached_artwork_image.dart # 新增：缩略图缓存 ImageProvider
```

---

## 七、参考链接

- EchoMusic 音量均衡实现：`src/renderer/utils/player.ts` 中 `PlayerEngine` 类
- Kugou API 文档：`api.json`（项目根目录）

---

## 八、环境变量

```bash
JAVA_HOME=D:\SDK\Java\jdk-21
ANDROID_HOME=D:\SDK\Android
Flutter=D:\SDK\Flutter\bin
Gradle=D:\SDK\Gradle\gradle-9.6.1\bin
```