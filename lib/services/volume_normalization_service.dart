import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/loudness_data.dart';

/// 音量均衡服务：基于曲目 LUFS 响度数据自动调整增益，
/// 使不同歌曲的播放音量保持一致。
///
/// ## 控制工程视角（钱学森《工程控制论》）
///
/// 这是一个纯前馈控制系统（Feedforward Control System）：
/// - **被控变量**：感知播放响度
/// - **测量输入**：从 API 获取的曲目 LUFS 值
/// - **参考输入**：用户配置的目标 LUFS（-16 ~ -6 dB，默认 -11）
/// - **控制器**：增益计算 `gain = 10^((refLUFS - trackLUFS)/20)`
/// - **执行器**：Android LoudnessEnhancer（提升）或 just_audio.setVolume（衰减）
/// - **扰动抑制**：峰值限制器防削波
/// - **饱和限幅**：增益钳位至 [0.1, 3.0]
/// - **稳定性**：无反馈回路，固有稳定
class VolumeNormalizationService {
  static const _channel = MethodChannel('kgka_music_hl/audio_effects');

  /// 目标参考响度（LUFS），用户可配置 -16 ~ -6。
  double referenceLufs;

  /// 是否启用音量均衡。
  bool enabled;

  /// 当前生效的线性增益（1.0 = 无增益变化）。
  double currentGain = 1.0;

  /// LUFS 缓存（keyed by 歌曲 hash）。
  final Map<String, LoudnessData> _loudnessCache = {};

  VolumeNormalizationService({this.enabled = false, double? referenceLufs})
    : referenceLufs = referenceLufs?.clamp(-16.0, -6.0) ?? -11.0;

  // ── LUFS 缓存 ──

  /// 缓存曲目的响度数据。
  void cacheLoudness(String hash, LoudnessData? data) {
    if (data != null && data.canNormalize) {
      _loudnessCache[hash] = data;
      debugPrint(
        '[VolumeNorm] Cached loudness for $hash: '
        'lufs=${data.lufs}, gain=${data.gain}, peak=${data.peak}',
      );
    }
  }

  /// 获取缓存的响度数据。
  LoudnessData? getCachedLoudness(String hash) => _loudnessCache[hash];

  // ── 增益计算 ──

  /// 计算线性增益（与 EchoMusic 算法一致）。
  ///
  /// 返回 `null` 表示数据不可用，应旁路（gain=1.0）。
  double? computeGainLinear(LoudnessData? data) {
    if (data == null || !data.isValid) return null;

    // 基础增益：参考响度与曲目响度的差值
    double gain = math
        .pow(10.0, (referenceLufs - data.lufs!) / 20.0)
        .toDouble();

    // 叠加服务端建议增益
    if (data.gain != null && data.gain!.isFinite && data.gain != 0.0) {
      gain *= math.pow(10.0, data.gain! / 20.0).toDouble();
    }

    // 峰值限制防削波
    if (data.peak != null &&
        data.peak!.isFinite &&
        data.peak! > 0 &&
        data.peak! <= 4.0) {
      gain = math.min(gain, 0.95 / data.peak!);
    }

    return gain.clamp(0.1, 3.0);
  }

  /// 计算增益并转换为分贝值。
  double? computeGainDb(LoudnessData? data) {
    final linear = computeGainLinear(data);
    if (linear == null) return null;
    return 20.0 * math.log(linear) / math.ln10;
  }

  // ── 增益应用 ──

  /// 应用增益到 Android 音频管道。
  ///
  /// 双路径策略：
  /// - **提升**（gainDb > 0.5dB）：通过 Android LoudnessEnhancer 提升
  /// - **衰减**（gainDb < -0.5dB）：通过 just_audio.setVolume 降低
  /// - **旁路**（其余情况）：增益接近 0dB，不做处理
  ///
  /// 返回实际应用的线性增益值。
  Future<double> applyForTrack({
    required int? audioSessionId,
    required LoudnessData? loudness,
    double userVolume = 1.0,
  }) async {
    if (!enabled) {
      await _disableNativeEnhancer();
      currentGain = 1.0;
      return 1.0;
    }

    final gainLinear = computeGainLinear(loudness);
    if (gainLinear == null) {
      // LUFS 数据不可用，静默旁路
      await _disableNativeEnhancer();
      currentGain = 1.0;
      return 1.0;
    }

    final gainDb = 20.0 * math.log(gainLinear) / math.ln10;

    if (gainDb > 0.5) {
      // ── 提升路径：LoudnessEnhancer ──
      if (audioSessionId != null && audioSessionId > 0) {
        final millibels = (gainDb * 100).round().clamp(0, 3000);
        try {
          await _channel.invokeMethod('enableLoudnessEnhancer', {
            'audioSessionId': audioSessionId,
            'gainMillibels': millibels,
          });
        } catch (e) {
          debugPrint('[VolumeNorm] Failed to enable LoudnessEnhancer: $e');
        }
      } else {
        await _disableNativeEnhancer();
      }
      currentGain = gainLinear;
    } else if (gainDb < -0.5) {
      // ── 衰减路径：通过音量级联 ──
      await _disableNativeEnhancer();
      currentGain = gainLinear;
    } else {
      // ── 旁路 ──
      await _disableNativeEnhancer();
      currentGain = 1.0;
    }

    debugPrint(
      '[VolumeNorm] Applied: lufs=${loudness?.lufs}, '
      'gainLinear=${gainLinear.toStringAsFixed(3)}, '
      'gainDb=${gainDb.toStringAsFixed(1)} dB, '
      'path=${gainDb > 0.5
          ? "boost"
          : gainDb < -0.5
          ? "attenuate"
          : "bypass"}',
    );

    return gainLinear;
  }

  /// 禁用 Native LoudnessEnhancer。
  Future<void> _disableNativeEnhancer() async {
    try {
      await _channel.invokeMethod('disableLoudnessEnhancer');
    } catch (_) {
      // 忽略（通道可能尚未初始化）
    }
  }

  /// 关闭时清理。
  Future<void> dispose() async {
    await _disableNativeEnhancer();
    _loudnessCache.clear();
  }

  /// 更新参考响度并重新计算当前增益。
  Future<double> updateReferenceLufs(
    double value, {
    required int? audioSessionId,
    required LoudnessData? currentLoudness,
  }) async {
    referenceLufs = value.clamp(-16.0, -6.0);
    if (enabled && currentLoudness != null) {
      return applyForTrack(
        audioSessionId: audioSessionId,
        loudness: currentLoudness,
      );
    }
    return 1.0;
  }
}
