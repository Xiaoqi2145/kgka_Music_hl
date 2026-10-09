> 文档编号：KA-07-07
> 级别：L3 📋
> 状态：现行
> 关联代码：lib/services/music_audio_handler.dart（主，AudioPlayer 装配点）、lib/services/volume_normalization_service.dart、lib/controllers/player_controller.dart、lib/services/audio_effects_service.dart、lib/services/playback_loudness.dart、android/app/src/main/kotlin/com/hoilai/mm/music/MainActivity.kt
> 最近更新：2026-10-08
> 变更触发条件：just_audio / androidx.media3 版本升级、AudioPlayer 构造参数变化、响度均衡双路径（LoudnessEnhancer / setVolume）结构变化、均衡器/低音增强/倍速/无缝播放实现变化、或决定启用 offload 时

> **证据口径**：本文的原始证据文档保存在本机 `diagnostics/offload-research/`（`platform-layer.md`、`dependency-stack.md`、`value-analysis.md`、`verification.md`），
> 该目录**未纳入版本库**（`.gitignore:48` 忽略 `/diagnostics/`）。保留文件名只为定位本机原始记录；
> 结论以 **AOSP 源码、依赖包字节码、本项目 `lib/` 代码** 为准，不以诊断记录为准。

# offload 与响度归一化共存评估

## TL;DR

1. **能否共存：不能（提升路径）；能（衰减路径）。** 响度均衡的**提升路径**（`LoudnessEnhancer`）与 Android audio offload **互斥**——不是「效果被静默忽略」，而是效果一经启用，AudioFlinger 就把 offload 轨道**作废**（`invalidate` 不可复位闩锁 → `Track::start()` 返回 `PERMISSION_DENIED`），随后由 media3 靠可恢复写异常降级、**重建为 PCM 轨道**（有可听中断）。**衰减路径**（`setVolume`）与 offload **可以共存**：offload 下音量默认由 HAL/DSP 承担，`AudioTrack.setVolume` 有效。
2. **有没有意义：通用层面有意义，但对本项目现阶段意义有限，建议不做。** 省电收益真实存在（官方定性 + 厂商实测约 6%–13% 量级），但**只存在于「长时熄屏 × 压缩直通 × 无音效」的交集**；而本项目 FLAC 档在 media3 判定链下**任何 Android 版本都无法 offload**，且响度均衡、均衡器/低音增强、倍速、真·无缝播放都是**已交付功能**，与该交集直接冲突。
3. **本项目当前不存在该冲突**：`AudioPlayer` 构造未传 offload 参数（lib/services/music_audio_handler.dart:24-27），且 just_audio 0.10.5 已默认关闭 offload。**本文的结论是「保持现状」，不是「已存在缺陷」。**

---

## 1. 问题界定

用户原问题有两问：**① offload 能否和响度归一化共存？② 有没有意义？** 两问必须分开答，因为第一问的答案按**路径**分叉，第二问的答案按**收益来源**分叉。

先厘清三个容易混淆的概念（它们在本调研中反复被混为一谈）：

| 概念 | media3 常量 / 判定入口 | 含义 | 与本文关系 |
|---|---|---|---|
| **offload（压缩直通）** | `OUTPUT_MODE_OFFLOAD = 1`；`setOffloadMode()` + `shouldUseBypass()` | **绕过解码器**，把**压缩码流**直接交给 DSP/硬件解码器 | 本文主角 |
| **passthrough** | `OUTPUT_MODE_PASSTHROUGH = 2` | 压缩码流经 S/PDIF/HDMI 等**不经过混音**输出 | 不是 offload；offload 协商失败会落到它 |
| **tunneling** | `RendererConfiguration.tunneling`（独立布尔量） | 音频隧道，与 offload 判定入口不同 | 不是 offload，**不能**用来证明「PCM 也能 offload」 |

**关键事实：offload ≠ 「硬件解码」。** 本项目平时播放 MP3/FLAC 时，MediaCodec 已在用厂商硬件解码器；offload 额外省掉的是 **AP 上 PCM 解码后的混音/重采样与唤醒次数**。这个区分决定了收益量级（见 §4）。

---

## 2. 平台层事实（AOSP）

### 2.1 offload 线程不参与样本处理

offload 线程（`OffloadThread` : `DirectOutputThread`）没有 `mNormalSink`，`threadLoop_write()` 走「直接写 HAL」分支，仅做压缩数据转发。因此**效果链在 offload 上永不处理样本**：

```cpp
// services/audioflinger/Effects.cpp:2326-2330
void EffectChain::process_l() {
    // never process effects when:
    // - on an OFFLOAD thread
    bool doProcess = !mEffectCallback->isOffloadOrMmap();
```

**只写这一条会低估风险**——读者会以为「只是音效没生效」。

### 2.2 更严重：启用非 offloadable 效果会作废整条 offload 轨道

`LoudnessEnhancer`、`Equalizer`、`BassBoost` 的描述符**均不声明** `EFFECT_FLAG_OFFLOAD_SUPPORTED`，因此 `isOffloadable() == false`（Effects.h:70-71）。启用它们会触发：

```cpp
// services/audioflinger/Threads.cpp:1787-1801
void ThreadBase::onEffectEnable(const sp<IAfEffectModule>& effect) {
    if (isOffloadOrMmap()) { ... broadcast_l(); }
    if (!effect->isOffloadable()) {
        if (mType == ThreadBase::OFFLOAD) {
            PlaybackThread *t = (PlaybackThread *)this;
            t->invalidateTracks(AUDIO_STREAM_MUSIC);   // ← offload 轨道被作废
        }
```

`invalidate()` 是**不可复位闩锁**（`mIsInvalid` + `CBLK_INVALID`，TrackBase.h:74-79、Tracks.cpp:2058-2062）。此后若上层尝试 `play()`，第二道闸门直接拒绝：

```cpp
// services/audioflinger/Tracks.cpp:1382-1393
if (isOffloaded()) {
    ...
    if (nonOffloadableGlobalEffectEnabled ||
            (ec != 0 && ec->isNonOffloadableEnabled())) {
        invalidate();
        return PERMISSION_DENIED;
    }
}
```

该闸门自 **Android 8.0** 起就存在，8 → main 无版本豁免。

**重要：「平台不会把轨道挪回 mixer」。** 本调研**未找到** AudioPolicy 侧自动重路由的代码；相反，offload/direct 轨道的 `restoreTrack_l()` 明确不实现重建，直接返回 `DEAD_OBJECT`（注释「FIXME re-creation of offloaded and direct tracks is not yet implemented」）。准确表述是「**轨道被作废，须由上层销毁并重建**」。

### 2.3 应用最终仍会退回 PCM —— 靠 media3，不是平台

offload 轨道失效后写入返回 dead object（`-6`/`-32`），`DefaultAudioSink` 将其识别为**可恢复**：置 `maybeDisableOffload()`（`offloadDisabledUntilNextConfiguration = true`）并抛 `isRecoverable = true` 的 `WriteException`，经 ExoPlayer 的 `reselectTracksInternalAndSeek()` 重建轨道、退出 bypass、启用 MediaCodec，回到 PCM。

**因此用户可见表现是「可听中断后继续播放」，而不是「永久静默」。** 注意 `onTearDown()` **不做任何重建**（只调 `listener.onOffloadBufferEmptying()`，且仅 `playing==true` 时）——**恢复由写异常驱动，不是 tear-down 事件驱动**。

**代价放大（推断 · 高置信）**：`configure()` 会重置 `offloadDisabledUntilNextConfiguration`。所以只要设备仍报支持且用户开着音效，**每首歌都可能重新尝试一次 offload → 被作废 → 再降级回 PCM**。代价是**每首歌开头一次多余的 AudioTrack 创建 + seek + 可能可听间隙**，而非「一次降级后永久回 PCM」。

### 2.4 音量（衰减路径）语义与常见说法相反

「offload 下 `setVolume` 无效」是**错误**的说法。三层证据都不支持它：media3 的 `setVolumeInternal` 无 offload 分支；`AudioTrack.setVolume` 无 offload 限制；AOSP 中：

```cpp
// services/audioflinger/Effects.cpp:1433-1444
void EffectChain::setVolumeForOutput_l(uint32_t left, uint32_t right)
{
    // for offload or direct thread, if the effect chain has non-offloadable
    // effect and any effect module within the chain has volume control, then
    // volume control is delegated to effect, otherwise, set volume to hal.
    if (mEffectCallback->isOffloadOrDirect() &&
        !(isNonOffloadableEnabled_l() && hasVolumeControlEnabled_l())) {
        ...
        mEffectCallback->setVolumeForOutput(vol_l, vol_r);   // ← 下发 HAL/DSP
    }
}
```

| 条件 | 音量在哪生效 |
|---|---|
| 链内**没有**已启用的非 offloadable 效果 | **HAL/DSP**（`setVolume` 有效） |
| 有已启用的非 offloadable 效果，**且**某效果带 `EFFECT_FLAG_VOLUME_CTRL` 且启用 | 委派给 effect，不下发 HAL |
| 有已启用的非 offloadable 效果，但**无** `VOLUME_CTRL` | HAL/DSP |

⚠️ **命名陷阱**：`PlaybackThread::setVolumeForOutput_l`（无条件下发 HAL）与 `EffectChain::setVolumeForOutput_l`（有条件）**同名不同类**，极易读错。另注：该条件在 **Android 11** 才加入 `hasVolumeControlEnabled_l()`，Android 10 及更早只要链内有任一带音量控制的非 offloadable 启用效果就不下发 HAL。

**对本项目的意义**：衰减路径在 `volume_normalization_service.dart` 内会先 `_disableNativeEnhancer()`，即纯 offload 链情形 → **衰减经 HAL/DSP 正常工作**。但**精度/量化步进是否满足响度归一化需求，本调研无数据**。

### 2.5 「什么效果能在 offload 上工作」

只有声明 `EFFECT_FLAG_OFFLOAD_SUPPORTED` 的效果。**AOSP 自带效果无一声明该 flag**（LoudnessEnhancer、Bundle EQ/BassBoost/Virtualizer、DynamicsProcessing、HapticGenerator、Reverb、Visualizer 均已核对）。全 AOSP 中**唯一设置者**是 `libeffectproxy`，且是**动态**的——仅当存在带 `EFFECT_FLAG_HW_ACC_TUNNEL` 的硬件子效果时才置位，而 `libeffectproxy` 是 `vendor: true`。

→ **「能在 offload 上工作的效果」= 厂商 HW 效果，应用层用标准 API 拿不到。**

CDD 只要求设备 MUST 支持 `EFFECT_TYPE_EQUALIZER` 与 `EFFECT_TYPE_LOUDNESS_ENHANCER` 的**创建与控制**，**从不要求它在 offload 路径可用**，也从不提 offload——两者不矛盾。

---

## 3. 依赖栈事实（just_audio 0.10.5 + androidx.media3 1.4.1）

### 3.1 本项目当前 offload = DISABLED

| 项 | 事实 | 锚点 |
|---|---|---|
| just_audio 默认 | 0.10.5 CHANGELOG：「**Disable Android audio offload by default to prevent playback issues**」 | 依赖包 `CHANGELOG.md:1-5` |
| 本项目装配 | `AudioPlayer` 未传 `androidAudioOffloadPreferences` / `androidOffloadSchedulingEnabled`；全 `lib/` grep 零命中 | lib/services/music_audio_handler.dart:24-27 |
| 收敛结果 | `AUDIO_OFFLOAD_MODE_DISABLED`，且 `isGaplessSupportRequired` / `isSpeedChangeSupportRequired` 被显式置 `true`（比 media3 默认更严格） | 依赖包 `AudioPlayer.java:158-173` |

### 3.2 offload 的前置是「压缩格式直通」，PCM 不可能

`shouldUseBypass(Format)` 在 offload 偏好非 0 且 `AudioOffloadSupport.isFormatSupported` 时返回 true，此时**解码器被绕过**，`bypassRead` 令 `outputFormat := inputFormat`（**压缩** Format），AudioSink 收到的是 `audio/mpeg` 而非 `audio/raw`。

判定链上 PCM 被**两道闸门**锁死：

| 闸门 | 机制 | 结论 |
|---|---|---|
| 1 | `DefaultAudioOffloadSupportProvider` 取 `MimeTypes.getEncoding(sampleMimeType, codecs)`，`encoding == 0` 直接 `DEFAULT_UNSUPPORTED` | `audio/raw` 返回 `0` → 不支持 |
| 2 | `Util.getApiLevelThatAudioFormatIntroducedAudioEncoding(0)` 返回 `Integer.MAX_VALUE` | 即使绕过闸门 1，`SDK_INT` 也永不满足 |

**格式可达性**（`MimeTypes.getEncoding` 的 12 个映射中）：

| 格式 | encoding | 最低 Android API | 可否 offload |
|---|---|---|---|
| `audio/mpeg`（MP3） | 9 | **28** | **有机会** |
| `audio/flac`（无损档） | 无映射 → `0` | — | **不可能（任何版本）** |
| `audio/raw`（PCM） | 无映射 → `0` | — | **不可能** |

⚠️ **FLAC 的准确断点**：不是「平台缺编码常量」——平台**有** `ENCODING_IAMF_*_FLAC`(35/39/43) 与 native `AUDIO_FORMAT_FLAC`——而是 **media3 `MimeTypes.getEncoding` 未映射 `audio/flac`**。本项目无损档正是 FLAC（lib/models/music_models.dart:104）。

### 3.3 offload 下所有 AudioProcessor 被跳过

offload/passthrough 分支的 `AudioProcessingPipeline` 构造为**空**（媒体源码注释即「Audio processing is not supported in offload or passthrough mode」），`shouldApplyAudioProcessorPlaybackParameters()` 在 `outputMode != 0` 时返回 false。→ **SonicAudioProcessor（倍速）、SilenceSkippingAudioProcessor 全失效**，倍速改走硬件 `AudioTrack.setPlaybackParams`，设备依赖。

本项目有倍速（lib/controllers/player_controller.dart:2528、:3607），**无跳过静音**（grep 零命中）。

### 3.4 「开音效就关 offload」这个自适应开关做不了

just_audio 0.10.5 的 Android 侧**只在构造 ExoPlayer 时设置一次** offload 偏好（`AudioPlayer.java:786-800`，全包仅此一处），Dart 侧 `AndroidAudioOffloadPreferences` **无 setter**，而本项目 `AudioPlayer` 是应用级单例。→ 运行时切换必须**打补丁或重建播放器**（中断播放）。**「聪明地动态开关」这条路被依赖栈堵死。**

⚠️ 上游还明确警告：**厂商会误报 offload 支持**（`just_audio.dart:2376-2385`），建议只在已实测的机型/OS 组合上启用。

---

## 4. 有没有意义

### 4.1 收益真实，但只在特定交集里

**官方定性（已验证）**：Media3「Battery consumption」页原文——

> "For short audio playbacks or playbacks when the screen is on, audio does not have a significant impact on power. For long playbacks with the screen off, it's possible to save power by using ExoPlayer's audio offload mode."

> "Offload also limits the ability to apply audio effects, like speed changes and silence skipping."

**这两句是官方自己承认的边界**：① 亮屏/短时**收益可忽略**；② offload **限制音频效果**。

> **证据状态**：本轮调研次级验证曾报告该页抓取失败；**Lead 已直接抓取该页并逐字核对上述两句**（页面同处标注 `Last updated 2026-03-13 UTC`）。该页同段还写明 offload「allows audio processing to be offloaded from the CPU to a dedicated signal processor」且「Device and format support varies」——即**收益依赖设备**。

**官方定量（唯一可引用点，但不可外推）**：Android 4.4 页「Audio Tunneling to DSP」称 Nexus 5「up to 60 hours … an increase of over 50% over non-tunneled audio」——**2013 年单机型**，且同页写明「requires support in the device hardware」。

**厂商实测（量级参考）**：

| 来源 | 数字 | 证据强度 |
|---|---|---|
| Qualcomm × YouTube Music | 非卸载 59.79 mA → 52.63 mA（≈ **−12%**） | 厂商技术博客（原链 403，读到中文转载） |
| vivo × QQ 音乐 | 母带下调 **6%**、SQ 下调 **11%**（宣传称续航「最高近 9 小时」） | 厂商公关稿，未公开测量方法 |
| 本地 MP3 整机对比表 | 压缩卸载 25.32/24.60/27.80 mA | 同上；差值由调研员自算 |

→ **本调研采用「约 6%–13% 量级」，并明确标注这些数字来自厂商自有 DSP 与自有 App。**

### 4.2 对本项目：四项独立理由使意义有限

| # | 理由 | 性质 |
|---|---|---|
| 1 | **FLAC 档收益恒为 0**（§3.2），而无损档恰是长时熄屏听歌最可能选的档位 | 源码级事实 |
| 2 | **音效与 offload 是替换而非叠加，且替换有代价**：响度提升 / 均衡器 / 低音增强任一开启 → 轨道作废 → media3 降级重建（有可听中断），且**每首歌可能重复一次**（§2.2–2.3）。这三者都是**已交付功能** | 源码级事实 |
| 3 | **运行时切换不可行**（§3.4），自适应开关被依赖栈堵死 | 源码级事实 |
| 4 | **与刚交付的「真·无缝播放」冲突**：offload gapless 需 API 33+ 且设备报告支持，MP3 又常带非 0 `encoderDelay` → 大量设备上「要 offload 就没无缝」 | 源码级事实 |

外加两条风险/缺口：**收益无本项目数据**（无熄屏功耗基线，故**无法证明收益**）；**厂商误报 offload 会引入跨机型播放 bug 风险**。

### 4.3 替代方案对比

| 方案 | 判断 | 理由 |
|---|---|---|
| **a. 保持 offload 关闭（现状）** | ✅ **推荐** | 唯一确定代价是失去上述潜在省电；反向保住全部已交付功能，且与上游默认一致 |
| **b. pre-gain 烘焙（把增益写进缓存文件）** | ❌ 现阶段不推荐 | **不能解决 FLAC 不可 offload**；破坏现有缓存「原始副本」语义；MP3 重编码二次有损；且 LoudnessEnhancer 是带时间常数的压缩器，与线性 pre-gain **行为不等价** |
| **c. 自适应开关（有音效就关 offload）** | ⛔ **不可行** | just_audio 0.10.5 不支持运行时切换（§3.4） |
| **d. 其他降功耗手段替代** | ✅ 建议转向 | 熄屏时的位置刻度/UI/歌词刷新、封面解码、日志与磁盘 IO——**不牺牲任何已交付功能** |

### 4.4 结论

> **「能否共存」**：**提升路径不能**（`LoudnessEnhancer` 与 offload 互斥，真实机制是「轨道被作废 → media3 降级重建为 PCM 轨道，有可听中断」）；**衰减路径能**（`setVolume` 经 HAL/DSP 生效）。
>
> **「有没有意义」**：**有条件有意义**——条件 = 「压缩直通格式 × 设备支持 × 用户未开任何音效 × 未用倍速 × 长时熄屏」，五者交集。**对 KA Music 现阶段：意义有限，建议不做**，把投入转向无功能代价的熄屏功耗优化。

---

## 5. 约束与坑

| 编号 | 约束 / 坑 | 说明 |
|---|---|---|
| C-01 | **「offload 下音效只是没生效」是错的** | 真实语义是「被创建 + 永不处理样本 + **轨道作废**」。只写前者会严重低估风险。 |
| C-02 | **「offload 只是没效果/回落到 mixer」是错的** | 平台**无自动重路由**；轨道被作废（`PERMISSION_DENIED` / `DEAD_OBJECT`），退回 PCM 靠 **media3 的可恢复写异常降级**，**有可听中断**。 |
| C-03 | **「offload 下 setVolume 无效」是错的** | 默认由 HAL/DSP 承担；仅当「非 offloadable 启用效果」**且**「带 `VOLUME_CTRL` 的启用效果」时才委派给 effect，且该条件 **Android 11 才收紧**。 |
| C-04 | **同名不同类陷阱** | `PlaybackThread::setVolumeForOutput_l`（无条件）与 `EffectChain::setVolumeForOutput_l`（有条件）极易读错。 |
| C-05 | **「PCM 不能 offload」≠「开 offload 无收益」** | offload 生效时解码器被绕过，AudioSink 收到的是**压缩** Format。本项目收益有限的原因是 §4.2 的四条，不是 PCM 这一点。 |
| C-06 | **offload ≠ 硬件解码** | 平时播放已用厂商硬件解码器；offload 省的是 AP 侧 PCM 混音/重采样与唤醒次数。不要把它宣传成「硬件解码」。 |
| C-07 | **offload / passthrough / tunneling 是三个不同概念** | 判定入口不同，**不能**用 tunneling 证明「PCM 也能 offload」。 |
| C-08 | **FLAC 断点在 media3 而非平台** | 平台有 FLAC 编码常量；是 media3 `MimeTypes.getEncoding` 未映射 `audio/flac`。 |
| C-09 | **厂商变数未穷尽** | 「AOSP 自带效果无一声明 `OFFLOAD_SUPPORTED`」对 AOSP **默认实现**成立；OEM 若经 `libeffectproxy` 包装 HW 子效果，结论可能不同（**未验证**）。 |
| C-10 | **效果在降级后是否恢复生效未验证** | 「轨道重建为 PCM 后 `LoudnessEnhancer` 是否自动恢复」取决于效果链迁移行为，**本调研未做真机端到端验证**。 |
| C-11 | **衰减精度无数据** | HAL/DSP 侧音量通常定点量化；「衰减步进是否满足响度归一化需求」**无数据**。 |
| C-12 | **收益数字全部不可外推** | 官方定量仅 2013 年 Nexus 5 单机型；厂商数字来自其自有 DSP/App。**本项目自身收益无任何定量数据。** |
| C-13 | **上游 issue 正文未取到** | just_audio #1526/#1519/#522、androidx/media #2038 仅**标题**可信（存在性证据），不得据此断言具体症状。 |
| C-14 | **不要为「降功耗」引入 offload 而牺牲已交付功能** | 响度均衡、均衡器/低音增强、倍速、真无缝是用户可见价值，且都处于 offload 的对立面。 |

---

## 6. 待办与关联

| 关联文档 | 关系 |
|---|---|
| ../03-模块详解/服务层-音量均衡.md | 响度均衡双路径的现行实现（本文 §2.4 的衰减路径、提升路径依据） |
| ../03-模块详解/服务层-音频与后台播放.md | `AudioPlayer` 装配点、音效 MethodChannel、平台支持矩阵 |
| ../03-模块详解/控制器层-PlayerController.md | `_applyVolumeNormalization` 时序、倍速、无缝播放门禁 |
| ../07-推进计划/播放链路改进方案.md | Phase D（换源语义/无缝）与本文 §4.2 第 4 条冲突相关 |
| ../05-平台与原生/Android-原生集成.md | 原生音效（LoudnessEnhancer/EQ/BassBoost）实现位置 |
| ../06-质量保障/已知问题与技术债台账.md | 若决定启动 offload 评估，需先登记「无熄屏功耗基线」缺口 |

待办（**均为「若将来决定评估」的前置，当前不启动**）：

| 编号 | 事项 | 前置条件 |
|---|---|---|
| O-01 | 采集熄屏功耗基线：同机型、同曲目、同音量、熄屏 30 分钟，对比 offload 开/关的 mAh 差 | **没有这一步就不应开工**（当前无任何本项目数据） |
| O-02 | 仅当 O-01 证明收益显著（如 ≥5% 整机功耗）时，才做最小化原型：**只在 MP3 档 + 用户未开任何音效 + 未用倍速 + 未开真无缝**时启用 | O-01 结论 |
| O-03 | 向 just_audio 上游提 PR 暴露运行时 offload setter（若能解决，才轮得到「自适应开关」方案） | 可选 |
| O-04 | 真机验证「降级后音效是否恢复生效」「可听中断时长」「每首歌重复降级的触发率」 | 仅在做原型时才需要 |

**当前决策：保持 offload 关闭（与 §现状一致，不新增任何 offload 参数）。** 若要推进功耗优化，走 §4.3 方案 d（熄屏路径优化），该路径无功能代价。
