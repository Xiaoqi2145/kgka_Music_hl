/// 曲目响度元数据（来自酷狗 API 的 volume 字段）。
///
/// 用于基于 LUFS 的音量均衡（音量归一化）：
/// 根据歌曲的集成响度自动调整增益，使不同歌曲的播放响度保持一致。
class LoudnessData {
  /// 集成响度（LUFS），如 -14.5。null 表示不可用。
  final double? lufs;

  /// 服务端建议的增益补偿（dB），如 0.0、-2.5。null 表示不可用。
  final double? gain;

  /// 采样峰值（0.0 ~ 1.0）。null 表示不可用。
  final double? peak;

  const LoudnessData({this.lufs, this.gain, this.peak});

  factory LoudnessData.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const LoudnessData();
    return LoudnessData(
      lufs: _asDouble(json['volume']),
      gain: _asDouble(json['volume_gain'] ?? json['volumeGain']),
      peak: _asDouble(json['volume_peak'] ?? json['volumePeak']),
    );
  }

  Map<String, dynamic> toJson() => {
    if (lufs != null) 'volume': lufs,
    if (gain != null) 'volume_gain': gain,
    if (peak != null) 'volume_peak': peak,
  };

  /// 是否有有效的 LUFS 数据。
  bool get isValid =>
      lufs != null && lufs!.isFinite && lufs! > -70.0 && lufs! < 0.0;

  /// 是否可以用于音量归一化。
  bool get canNormalize => isValid;

  static double? _asDouble(Object? value) {
    return switch (value) {
      num value => value.toDouble(),
      String value => double.tryParse(value.trim()),
      _ => null,
    };
  }
}
