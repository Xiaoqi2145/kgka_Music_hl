> 文档编号：KA-03-09
> 级别：L2 📖
> 状态：现行
> 关联代码：lib/controllers/player_controller.dart（2833 行 LF / 2639 行非空，最大控制器）、lib/services/music_audio_handler.dart、lib/services/playback_loudness.dart、lib/services/volume_normalization_service.dart
> 最近更新：2026-09-08
> 变更触发条件：播放链路、状态字段、音质策略、会话持久化、无缝播放逻辑发生变化时

# 控制器层 · PlayerController

## TL;DR

`PlayerController` 是整个应用的核心，2 833 行（LF 口径）、约 120 个成员，承担**音源解析、音质降级、无缝预载、歌词加载、音效应用、音量均衡、队列管理、会话持久化、播放统计、睡眠定时**十个关注点。它通过订阅 7 个 `just_audio` 流驱动状态，用 `_playRequestGeneration` 代数号解决并发竞态。**这是全项目最需要拆分、也最不能轻率改动的文件。**

---

## 1. 公开状态字段

| 字段 | 类型 | 默认值 | 含义 |
|---|---|---|---|
| `currentSong` | `Song?` | `null` | 当前曲目 |
| `queue` | `List<Song>` | `const []` | 播放队列 |
| `lyrics` | `List<LyricLine>` | `const []` | 当前歌词行 |
| `playbackMode` | `PlaybackMode` | `playlistLoop` | 列表循环 / 随机 / 单曲循环 |
| `position` | `Duration` | `zero` | 播放位置 |
| `duration` | `Duration` | `zero` | 总时长 |
| `isPlaying` | `bool` | `false` | 是否正在播放 |
| `isBuffering` | `bool` | `false` | 缓冲中 |
| `isPreparing` | `bool` | `false` | 音源准备中 |
| `isLoadingLyrics` | `bool` | `false` | 歌词加载中（与音频准备解耦） |
| `audioQuality` | `AudioQuality` | `standard` | 当前音质 |
| `smartQualityEnabled` | `bool` | `false` | 播放失败自动降级 |
| `playbackSpeed` | `double` | `1.0` | 倍速 |
| `equalizerEnabled` | `bool` | `false` | 均衡器开关 |
| `equalizerLevels` | `List<int>` | 10 个 0 | 均衡器增益（10 段） |
| `equalizerPresetName` | `String` | `'平直'` | 预设名 |
| `bassBoostEnabled` | `bool` | `false` | 低音增强开关 |
| `bassBoostStrength` | `double` | `0.45` | 低音增强强度 |
| `audioInterruptionEnabled` | `bool` | `true` | 后台打断机制 |
| `autoResumeAfterInterruption` | `bool` | `false` | 被打断后自动恢复 |
| `autoPlayOnDeviceConnected` | `bool` | `true` | 连接音频设备自动播放 |
| `desktopLyricsEnabled` | `bool` | `false` | 桌面歌词 |
| `lyricDisplayMode` | `LyricDisplayMode` | `lyricsWithTranslation` | 歌词显示模式 |
| `desktopLyricsSettings` | `DesktopLyricsSettings` | 默认 | 桌面歌词样式 |
| `volumeNormalizationEnabled` | `bool` | `false` | 音量均衡 |
| `volumeNormalizationRefLufs` | `double` | `-14.0` | 参考响度 |
| `addListeningTimeEnabled` | `bool` | `true` | 听歌时长上报 |
| `resumePlaybackEnabled` | `bool` | `true` | 接续播放 |
| `gaplessPlaybackEnabled` | `bool` | `true` | 无缝播放 |
| `errorMessage` | `String?` | `null` | 最近一次播放错误 |
| `sleepTimerRemaining` | `Duration?` | `null` | 睡眠定时剩余 |

---

## 2. 订阅的 7 个音频流（构造函数内，`player_controller.dart:112-200`）

| 流 | 处理 |
|---|---|
| `positionStream` | 更新 `_positionBase`（非 seek 中）、检查播放完成、同步桌面歌词进度、触发无缝预载（剩余 ≤30s） |
| `durationStream` | 更新 `duration` + `notifyListeners()` |
| `playerStateStream` | 更新 `isPlaying`/`isBuffering`、启动响度窗口、同步听歌时长、恢复/暂停播放缓存、同步桌面歌词播放态 |
| `processingStateStream`（`.distinct()`） | `completed` → `_handleCompleted()` |
| `androidAudioSessionIdStream` | 更新 sessionId → 重新应用均衡器 / 低音增强 / 音量均衡 |
| `currentIndexStream` | `_onPlaylistIndexChanged()` |
| `errorStream` | 记录日志 → 若非准备中/非完成处理中，**自动重载当前曲恢复播放** |

> **性能约束**：位置高频更新走独立的 `positionListenable`，**不触发全局 `notifyListeners()`**（注释见 `player_controller.dart:134`）。修改时务必保持。

---

## 3. `playSong()` 完整流程（`player_controller.dart:536-687`）

| 步骤 | 行为 |
|---|---|
| 1 | `_cancelAutomaticResume()`、`_audioHandler.invalidatePendingPlay()` |
| 2 | `requestGeneration = ++_playRequestGeneration`，后续每步校验 `isCurrentRequest()` |
| 3 | **点播当前曲**：若同一首歌且 `processingState != idle` 且无错误 → 仅同步队列上下文、必要时 seek 到 0、`play()`，**保留进度** |
| 4 | 否则：取消待处理播放缓存、清空完成标记、`isPreparing = true`、`errorMessage = null` |
| 5 | `currentSong = song`；`_selectNormalizationSource(song, audioQuality, force: true)` |
| 6 | 处理队列参数（有则替换，无且当前队列空则 `[song]`） |
| 7 | `lyrics = const []`、`_lastDesktopLyricIndex = -1`、`notifyListeners()` |
| 8 | `unawaited(loadLyrics(song))` —— **歌词与音源解析并行** |
| 9 | 音源优先级：`downloadController.localSourceFor(song, quality)` → 本地文件；否则 `SongSource.local` 直接用 `song.id`；否则 `_loadNetworkSourceWithFallback()` |
| 10 | 本地文件加载失败且非本地曲目 → 删除该播放缓存 → 回退网络（`player_controller.dart:618-633`） |
| 11 | `isPreparing = false`、`_audioHandler.play()`（`catchError` 写入 `errorMessage`） |
| 12 | `_scheduleSessionPersist()`、`unawaited(_applyVolumeNormalization())` |
| 13 | `_historyService.record(song)`、`_statsService.recordPlay(song)`（后台） |
| 14 | 若走了网络：`_schedulePlaybackCache(...)`（30 秒稳定后缓存） |

> **竞态防护**：每个 `await` 之后都检查 `isCurrentRequest()`，过期请求直接 `return`。这是本文件最关键的并发纪律。

---

## 4. 音质降级策略

### 4.1 降级阶梯（`_nextLowerQuality`，`player_controller.dart:915-924`）

```
lossless(FLAC) → high(320K) → standard(128K) → null（停止）
```

### 4.2 触发条件

| 开关 | 行为 |
|---|---|
| `smartQualityEnabled = false` | 只尝试当前音质一次 |
| `smartQualityEnabled = true` | 逐级降级重试，每级失败 `audioPlayer.stop()`，全部失败抛 `lastError` 或「这首歌暂时没有可播放地址」 |

日志格式：`[KA Music][playback] {quality.badge} source failed for {hash}: {error}`（`player_controller.dart:900-903`）。

### 4.3 音质切换

`setAudioQuality(quality, {reloadCurrent})`（`player_controller.dart:1419-1438`）：更新状态 → 清空预载的下一曲 → 持久化 `settings.audio_quality` → 可选重载当前曲。

---

## 5. 无缝播放（`_prepareNextSourceIfNeeded`，`player_controller.dart:1179+`）

| 门槛 | 条件 |
|---|---|
| 未在准备 | `_preparedNext == null && !_preparingNextSource` |
| 无预载子源 | `!_hasPreloadedNextChild()` |
| 非单曲循环 | `playbackMode != singleLoop` |
| 正在播放且非准备中 | `isPlaying && !isPreparing` |
| 冷却期已过 | `DateTime.now() >= _prepareNextCooldownUntil`（失败后 15s） |
| 时间窗口 | 剩余 `3s ~ 30s` |

流程：取下一曲 → 更新元数据窗口 → 预取歌词（按 `generation:queueRevision:lyricKey:quality:volNorm` 去重）→ 若本地/缓存命中则跳过网络 → 否则取 URL → `appendPlaylistEntry()` 追加为预载子源（ExoPlayer 样本级无缝）。失败则设置 15s 冷却。

> 元数据窗口 `_retainMetadataWindow()` 只保留「上一曲 / 当前曲 / 下一曲」三首的歌词与响度缓存，防止内存无界增长。

---

## 6. 会话持久化（接续播放）

| 项 | 值 |
|---|---|
| 缓存 key | `cache_playback_session` |
| 持久化键 | `settings.resume_playback_enabled`（默认 `true`） |
| 保存内容 | `queue`（`Song.toCache`）、`currentIndex`、`playbackMode` |
| 保存时机 | 切歌 / 换队列 / 切模式时（脏标记 + 定时器防抖），**不保存播放进度** |
| 恢复时机 | `main.dart:108` `unawaited(restorePlaybackSession())` |
| 恢复行为 | 恢复队列与当前曲，`processingState` 保持 `idle`，**不自动播放** |
| 关闭开关 | 取消定时器 + 删除缓存文件 |

> ⚠️ 注释明确：「直接读偏好，避免与 `_restoreSettings` 的异步加载产生先后竞争」（`player_controller.dart:1350`）。这是刻意规避的竞态。

---

## 7. 设置项持久化键（本文件负责）

| 键 | 类型 | 默认 |
|---|---|---|
| `settings.audio_quality` | String（`apiValue`） | `standard` |
| `settings.smart_quality_enabled` | bool | `false` |
| `settings.equalizer_enabled` | bool | `false` |
| `settings.equalizer_levels` | String（JSON/CSV） | 10 个 0 |
| `settings.equalizer_preset` | String | `平直` |
| `settings.bass_boost_enabled` | bool | `false` |
| `settings.bass_boost_strength` | double | `0.45` |
| `settings.audio_interruption_enabled` | bool | `true` |
| `settings.auto_resume_after_interruption` | bool | `false` |
| `settings.auto_play_on_device_connected` | bool | `true` |
| `settings.playback_speed` | double | `1.0` |
| `settings.desktop_lyrics_enabled` | bool | `false` |
| `settings.desktop_lyrics_settings` | String（JSON） | 默认样式 |
| `settings.lyric_display_mode` | String（enum name） | `lyricsWithTranslation` |
| `settings.lyric_scale` | double | 见设置页 |
| `settings.manual_lyric_candidates` | String（JSON） | 空 |
| `settings.volume_normalization_enabled` | bool | `false` |
| `settings.volume_normalization_ref_lufs` | double | `-14.0` |
| `settings.add_listening_time_enabled` | bool | `true` |
| `settings.resume_playback_enabled` | bool | `true` |
| `settings.gapless_playback_enabled` | bool | `true` |

---

## 8. 其他关键机制

| 机制 | 说明 | 位置 |
|---|---|---|
| 音频焦点 | `AudioFocusGate` 串行化请求；`_wasPlayingOnInterruptionBegin` 区分「被系统打断」与「用户手动暂停」 | `_reclaimAudioFocus`、`_setupAudioSessionListeners` |
| 音量闪避 | 打断时 `_setDucked(true)` → 音量 × 0.5 | `_applyPlaybackVolume`，`player_controller.dart:240-241` |
| 队列操作 | `addToQueue`（插到当前曲之后、去重）、`replaceQueue`（去重、保留当前曲）、`registerQueueExpansion`（版本校验） | `player_controller.dart:926-1008` |
| 完成处理 | `_handleCompleted` + `_completionFallbackTimer` 兜底 | `player_controller.dart:1757+` |
| 播放缓存调度 | 30 秒稳定后缓存；暂停时挂起、恢复时继续 | `_schedulePlaybackCache`、`_pause/_resumePendingPlaybackCache` |
| 听歌时长 | 每 30 分钟上报一次，每分钟检查 | `_listenTimeReportInterval`、`_listenTimeCheckInterval` |
| 睡眠定时 | 支持「到时停止」与「播完当前曲停止」 | `setSleepTimer`、`setSleepTimerFinishSong` |
| 桌面歌词 | 可见性、进度、播放态三路同步 | `_syncDesktopLyrics`、`_syncDesktopKaraokeProgress` |

---

## 9. 约束与坑

1. **120+ 成员集中在一个类**：任何改动都可能引发播放回归，且无法单元测试（依赖 `just_audio` 与原生通道）。
2. **大量 `unawaited`**：异常易被吞掉，排障依赖 `debugPrint` 日志。
3. **音量均衡与用户音量耦合**：衰减路径直接 `audioPlayer.setVolume(gain × duck)`，用户调音量会被覆盖（`player_controller.dart:240-241`）。
4. **`_playerErrorSub` 自动重播当前曲**：若错误是持续性的，可能形成重播循环（有 `_isHandlingPlayerError` 守卫，但只防单次重入）。
5. **元数据缓存窗口**依赖 `_retainMetadataWindow` 的三曲窗口，超出即淘汰；快速连续切歌时可能反复丢失。
6. **无播放状态机**：`isPlaying/isBuffering/isPreparing/errorMessage` 是并列布尔，组合状态无法穷举，UI 需自行拼装。

---

## 10. 待办与关联

| 事项 | 编号 | 文档 |
|---|---|---|
| 拆分 PlayerController（播放/歌词/音效/会话四块） | T-M2-02 | `07-推进计划/任务分解-WBS.md` |
| 引入播放状态机 | T-M4-01 | 同上 |
| 音量与均衡的交互模型 | T-M4-04 | 同上 |
| 播放链路错误分类与恢复策略 | T-M4-02 | 同上 |
| 离线 LUFS 计算 | T-M4-05 | 同上 |
| 播放相关设置项全清单 | — | `04-数据与接口/本地存储与配置项清单.md` |
| 音频与焦点细节 | — | `03-模块详解/服务层-音频与后台播放.md` |
