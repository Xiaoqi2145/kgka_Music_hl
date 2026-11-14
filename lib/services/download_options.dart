import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';

/// 下载文件名构成方式。
enum DownloadNamingStyle {
  /// 歌名 - 歌手
  titleArtist,

  /// 歌手 - 歌名
  artistTitle,

  /// 仅歌名
  titleOnly,
}

extension DownloadNamingStyleLabel on DownloadNamingStyle {
  String get label => switch (this) {
    DownloadNamingStyle.titleArtist => '歌名 - 歌手',
    DownloadNamingStyle.artistTitle => '歌手 - 歌名',
    DownloadNamingStyle.titleOnly => '仅歌名',
  };
}

/// 下载选项：文件命名方式与下载音质，两者都可以选择跟随默认值。
class DownloadOptions {
  const DownloadOptions({
    this.namingStyle = DownloadNamingStyle.titleArtist,
    this.quality,
    this.writeTags = true,
  });

  static const namingStyleKey = 'settings.download_naming_style';
  static const qualityKey = 'settings.download_quality';
  static const writeTagsKey = 'settings.download_write_tags';

  final DownloadNamingStyle namingStyle;

  /// 显式指定的下载音质；为空时跟随当前播放音质。
  final AudioQuality? quality;

  /// 是否把歌曲信息与封面写入下载文件。
  final bool writeTags;

  String get qualityLabel => quality?.label ?? '跟随播放音质';

  DownloadOptions copyWith({
    DownloadNamingStyle? namingStyle,
    AudioQuality? quality,
    bool clearQuality = false,
    bool? writeTags,
  }) {
    return DownloadOptions(
      namingStyle: namingStyle ?? this.namingStyle,
      quality: clearQuality ? null : (quality ?? this.quality),
      writeTags: writeTags ?? this.writeTags,
    );
  }

  static Future<DownloadOptions> load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedStyle = prefs.getString(namingStyleKey);
    final storedQuality = prefs.getString(qualityKey);
    return DownloadOptions(
      namingStyle: DownloadNamingStyle.values.firstWhere(
        (style) => style.name == storedStyle,
        orElse: () => DownloadNamingStyle.titleArtist,
      ),
      quality: storedQuality == null
          ? null
          : AudioQuality.fromApiValue(storedQuality),
      writeTags: prefs.getBool(writeTagsKey) ?? true,
    );
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(namingStyleKey, namingStyle.name);
    final selected = quality;
    if (selected == null) {
      await prefs.remove(qualityKey);
    } else {
      await prefs.setString(qualityKey, selected.apiValue);
    }
    await prefs.setBool(writeTagsKey, writeTags);
  }

  /// 解析本次下载实际使用的音质。
  AudioQuality resolveQuality(AudioQuality playbackQuality) =>
      quality ?? playbackQuality;

  /// 按命名方式生成不含扩展名的文件基础名。
  String baseNameFor(Song song) {
    final title = song.title.trim().isEmpty ? '未知歌曲' : song.title.trim();
    final artist = song.artist.trim().isEmpty ? '未知艺人' : song.artist.trim();
    return switch (namingStyle) {
      DownloadNamingStyle.titleArtist => '$title - $artist',
      DownloadNamingStyle.artistTitle => '$artist - $title',
      DownloadNamingStyle.titleOnly => title,
    };
  }
}
