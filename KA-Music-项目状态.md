# KA Music - 项目状态记录

> 保存时间：2026-07-02
> 项目路径：E:\Project\Claude\KAmusic
> Flutter 版本：3.44.4（D:\SDK\Flutter）
> Android SDK：37（D:\SDK\Android）
> JDK：21（D:\SDK\Java\jdk-21）

---

## 一、已完成功能

### 音量均衡（LUFS-Based Volume Leveling）

基于曲目 LUFS 响度数据的音量归一化，参照 EchoMusic 实现。

**控制工程视角（钱学森《工程控制论》）：**
- 纯前馈控制系统：LUFS 数据在播放开始前已知，增益一次计算
- 参考输入：用户配置的目标 LUFS（-16 ~ -6 dB，默认 -11）
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

---

## 二、音量均衡设置项

**位置：** 设置 → 播放 → 音量均衡

- **开关：** "音量均衡" — subtitle: "自动统一不同歌曲的播放音量"
- **参考响度滑块（仅开关开启时显示）：** -16 ~ -6 LUFS，步进 1，默认 -11
- 滑块右侧显示当前值标签，如 "-11 LUFS"

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

当前 `/song/url` 的 API 响应中是否包含 `volume` 字段尚未确认。需要在真机运行时查看 logcat：

```bash
adb logcat | grep "loudness"
```

如果输出包含 `volume` 字段则正常。否则需要修改后端 API 代理透传酷狗的 `volume`/`volume_gain`/`volume_peak` 字段。

### 4.2 背景图片渲染延迟

用户反馈自定义背景图在页面切换时延迟 ~0.7s。
- 尝试过预加载字节、预解码 `ui.Image`、架构分离等方案，均未彻底解决
- 当前方案已全部回退，`theme_controller.dart` 和 `main.dart` 保持原版
- 如需修复，建议方向：`Image.file()` 的缓存键问题或 Navigator 过渡动画的同步问题

### 4.3 Android 构建

- 构建时提示 `file_picker` 插件使用 Kotlin Gradle Plugin（KGP），未来 Flutter 版本可能不兼容
- 当前仅构建 `arm64-v8a` ABI

### 4.4 音量均衡增强

- 当前未实现 LUFS 数据持久化到本地数据库（仅在内存缓存）
- 未实现本地歌曲的 LUFS 离线计算
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