import 'dart:typed_data';

import 'package:flutter_taglib/flutter_taglib.dart';

import '../models/music_models.dart';
import 'artwork_cache_service.dart';

/// 把歌曲信息写入下载文件：标题、歌手、专辑与内嵌封面。
///
/// 使用 TagLib 直接改写暂存文件，FLAC 写入 Vorbis Comment 与 PICTURE 块，
/// MP3 写入 ID3v2 标签，播放器与文件管理器都能显示。
class DownloadTagWriter {
  const DownloadTagWriter();

  Future<void> apply({required String path, required Song song}) async {
    return applyWithCover(
      path: path,
      song: song,
      coverBytes: await _coverBytes(song.coverUrl),
    );
  }

  Future<void> applyWithCover({
    required String path,
    required Song song,
    Uint8List? coverBytes,
  }) async {
    if (!TagLibFile.isSupported) {
      throw UnsupportedError('当前平台不支持写入音频标签');
    }
    final cover = coverBytes;
    final file = TagLibFile.open(path);
    if (file == null) {
      throw StateError('无法打开下载文件以写入标签');
    }
    try {
      file.title = song.title;
      file.artist = song.artist;
      final album = song.albumName;
      if (album != null && album.trim().isNotEmpty) {
        file.album = album.trim();
      }
      if (cover != null) {
        file.setCover(data: cover, mimeType: _mimeTypeOf(cover));
      }
      if (!file.save()) {
        throw StateError(TagLibFile.lastError ?? '写入音频标签失败');
      }
    } finally {
      file.close();
    }
  }

  Future<Uint8List?> _coverBytes(String? url) async {
    if (url == null || url.isEmpty) return null;
    final file = await ArtworkCacheService.instance.load(url);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  }

  String _mimeTypeOf(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      return 'image/jpeg';
    }
    return 'image/png';
  }
}
