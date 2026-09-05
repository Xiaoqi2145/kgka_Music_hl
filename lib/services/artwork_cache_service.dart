import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Small disk cache for remote artwork.
///
/// Artwork is kept separately from JSON data so an offline session can still
/// render covers that were shown before. In-flight downloads are shared to
/// avoid waking the network once per list tile.
class ArtworkCacheService {
  ArtworkCacheService._();

  static final ArtworkCacheService instance = ArtworkCacheService._();
  final Map<String, Future<File?>> _pending = <String, Future<File?>>{};
  Directory? _directory;

  Future<Directory> _getDirectory() async {
    final current = _directory;
    if (current != null) return current;
    // 缩略图是离线可复用数据，不应放在系统可随时清理的临时目录。
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/ka_music_artwork');
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }

  Future<File> _fileFor(String url) async {
    final directory = await _getDirectory();
    final key = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    return File('${directory.path}/$key.img');
  }

  Future<File?> load(String url) {
    final existing = _pending[url];
    if (existing != null) return existing;
    final future = _load(url);
    _pending[url] = future;
    unawaited(future.whenComplete(() => _pending.remove(url)));
    return future;
  }

  /// 获取已缓存的缩略图总大小。
  Future<int> getCacheSize() async {
    final directory = await _getDirectory();
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.img')) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// 获取已缓存的缩略图条目数量。
  Future<int> getCacheCount() async {
    final directory = await _getDirectory();
    var count = 0;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.img')) count++;
    }
    return count;
  }

  /// 清理全部缩略图缓存。
  Future<void> clearCache() async {
    final directory = await _getDirectory();
    await for (final entity in directory.list()) {
      if (entity is File &&
          (entity.path.endsWith('.img') || entity.path.endsWith('.part'))) {
        await entity.delete();
      }
    }
  }

  Future<File?> _load(String url) async {
    final file = await _fileFor(url);
    if (await file.exists() && await file.length() > 0) return file;

    final temporary = File('${file.path}.part');
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.followRedirects = true;
        request.maxRedirects = 3;
        final response = await request.close().timeout(
          const Duration(seconds: 12),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (await temporary.exists()) await temporary.delete();
          return null;
        }
        await response.pipe(temporary.openWrite());
        if (!await temporary.exists() || await temporary.length() == 0) {
          if (await temporary.exists()) await temporary.delete();
          return null;
        }
        if (await file.exists()) await file.delete();
        return await temporary.rename(file.path);
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      return null;
    }
  }
}
