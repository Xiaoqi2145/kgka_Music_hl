import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// 缩略图缓存中的单个条目，用于 LRU 淘汰决策。
class ArtworkCacheEntry {
  const ArtworkCacheEntry({
    required this.path,
    required this.size,
    required this.accessedAt,
  });

  final String path;
  final int size;

  /// 最后访问时间（读取命中时刷新），LRU 依据。
  final DateTime accessedAt;
}

/// Small disk cache for remote artwork.
///
/// Artwork is kept separately from JSON data so an offline session can still
/// render covers that were shown before. In-flight downloads are shared to
/// avoid waking the network once per list tile.
///
/// 缓存总量受 [maxCacheBytes] 约束（默认 512MB，可在设置中调整），
/// 超出后按最后访问时间淘汰最旧的文件。
class ArtworkCacheService {
  ArtworkCacheService._();

  static final ArtworkCacheService instance = ArtworkCacheService._();

  static const _maxBytesKey = 'settings.artwork_cache_max_bytes';

  final Map<String, Future<File?>> _pending = <String, Future<File?>>{};
  Directory? _directory;
  Future<void>? _loading;
  Future<void>? _pruning;
  bool _loaded = false;
  int _totalBytes = 0;
  int _entryCount = 0;

  /// 缩略图缓存上限，超过后按 LRU 淘汰。
  int maxCacheBytes = AppConfig.defaultArtworkCacheMaxBytes;

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

  /// 加载上限设置并扫描一次缓存目录。
  ///
  /// 之后 [getCacheSize] / [getCacheCount] 直接读内存计数，不再遍历目录。
  Future<void> initialize() => _ensureLoaded();

  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    final pending = _loading;
    if (pending != null) return pending;
    final future = _loadState();
    _loading = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_loading, future)) _loading = null;
      }),
    );
    return future;
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    maxCacheBytes = _normalizeMaxBytes(
      prefs.getInt(_maxBytesKey) ?? maxCacheBytes,
    );
    final directory = await _getDirectory();
    var total = 0;
    var count = 0;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.img')) continue;
      total += await entity.length();
      count++;
    }
    _totalBytes = total;
    _entryCount = count;
    _loaded = true;
    await _enforceLimit();
  }

  int _normalizeMaxBytes(int value) => value.clamp(
    AppConfig.minArtworkCacheMaxBytes,
    AppConfig.maxArtworkCacheMaxBytes,
  );

  Future<File?> load(String url) {
    final existing = _pending[url];
    if (existing != null) return existing;
    final future = _loadTracked(url);
    _pending[url] = future;
    unawaited(future.whenComplete(() => _pending.remove(url)));
    return future;
  }

  Future<File?> _loadTracked(String url) async {
    try {
      await _ensureLoaded();
      final file = await _fileFor(url);
      if (await file.exists() && await file.length() > 0) {
        // 命中缓存：刷新访问时间作为 LRU 依据。
        unawaited(_touch(file));
        return file;
      }
      final downloaded = await _download(file, url);
      if (downloaded == null) return null;
      _totalBytes += await downloaded.length();
      _entryCount++;
      await _enforceLimit();
      return downloaded;
    } catch (_) {
      // 缓存读写异常不应影响界面渲染，降级为占位图。
      return null;
    }
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // 访问时间刷新失败不影响读取。
    }
  }

  /// 获取已缓存的缩略图总大小（字节）。
  Future<int> getCacheSize() async {
    await _ensureLoaded();
    return _totalBytes;
  }

  /// 获取已缓存的缩略图条目数量。
  Future<int> getCacheCount() async {
    await _ensureLoaded();
    return _entryCount;
  }

  /// 调整缩略图缓存上限并立即按 LRU 淘汰超额部分。
  Future<void> setMaxCacheBytes(int bytes) async {
    final normalized = _normalizeMaxBytes(bytes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_maxBytesKey, normalized);
    await _ensureLoaded();
    maxCacheBytes = normalized;
    await _enforceLimit();
  }

  /// 清理全部缩略图缓存。
  Future<void> clearCache() async {
    await _ensureLoaded();
    final directory = await _getDirectory();
    var removedCount = 0;
    var removedBytes = 0;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final isImage = entity.path.endsWith('.img');
      final isPartial = entity.path.endsWith('.part');
      if (!isImage && !isPartial) continue;
      final size = isImage ? await entity.length() : 0;
      await entity.delete();
      if (isImage) {
        removedCount++;
        removedBytes += size;
      }
    }
    _totalBytes = _totalBytes > removedBytes ? _totalBytes - removedBytes : 0;
    _entryCount = _entryCount > removedCount ? _entryCount - removedCount : 0;
  }

  Future<void> _enforceLimit() async {
    if (_totalBytes <= maxCacheBytes) return;
    final pending = _pruning;
    if (pending != null) return pending;
    final future = _pruneToLimit();
    _pruning = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_pruning, future)) _pruning = null;
      }),
    );
    return future;
  }

  Future<void> _pruneToLimit() async {
    // 淘汰期间可能有新文件写入，循环直到降到上限以内。
    while (_totalBytes > maxCacheBytes) {
      final before = _totalBytes;
      await _prune();
      if (_totalBytes >= before) break; // 已无法继续删除，避免死循环。
    }
  }

  Future<void> _prune() async {
    final directory = await _getDirectory();
    final entries = <ArtworkCacheEntry>[];
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.img')) continue;
      try {
        final size = await entity.length();
        entries.add(
          ArtworkCacheEntry(
            path: entity.path,
            size: size,
            accessedAt: await entity.lastModified(),
          ),
        );
        total += size;
      } catch (_) {
        // 文件在扫描期间被删除，忽略。
      }
    }

    final evictions = selectLruEvictions(entries, maxCacheBytes);
    var removedCount = 0;
    var removedBytes = 0;
    for (final entry in evictions) {
      try {
        await File(entry.path).delete();
        removedCount++;
        removedBytes += entry.size;
      } catch (_) {
        // 已被删除或占用，跳过。
      }
    }
    // 以本次扫描结果为准修正计数，避免与并发写入产生漂移。
    _totalBytes = total - removedBytes;
    _entryCount = entries.length - removedCount;
  }

  /// 按最后访问时间升序挑选需要淘汰的条目，直到剩余总量不超过 [maxBytes]。
  ///
  /// 纯函数，便于单元测试。
  static List<ArtworkCacheEntry> selectLruEvictions(
    List<ArtworkCacheEntry> entries,
    int maxBytes,
  ) {
    var total = 0;
    for (final entry in entries) {
      total += entry.size;
    }
    if (total <= maxBytes) return const <ArtworkCacheEntry>[];

    final ordered = List<ArtworkCacheEntry>.of(entries)
      ..sort((a, b) {
        final byTime = a.accessedAt.compareTo(b.accessedAt);
        return byTime != 0 ? byTime : a.path.compareTo(b.path);
      });

    final evictions = <ArtworkCacheEntry>[];
    for (final entry in ordered) {
      if (total <= maxBytes) break;
      evictions.add(entry);
      total -= entry.size;
    }
    return evictions;
  }

  Future<File?> _download(File file, String url) async {
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
