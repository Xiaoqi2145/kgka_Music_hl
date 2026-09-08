import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 缓存读取结果。
class CacheResult<T> {
  const CacheResult({required this.data, required this.isStale});

  final T data;

  /// 是否已超过 TTL（过期）。
  final bool isStale;
}

/// 统一数据缓存服务。
///
/// 缓存载体为 SharedPreferences + JSON（决策1）。每条缓存存储为：
/// `{ "savedAt": <毫秒时间戳>, "payload": <任意 JSON> }`
///
/// 核心方法 [swr] 封装 stale-while-revalidate 模式：先返回缓存立即显示，
/// 后台静默刷新，失败时降级到缓存。该模式推广自 AuthController 已有的
/// 「先缓存后刷新 + 失败降级」逻辑。
class CacheService {
  CacheService();

  static const _savedAtKey = 'savedAt';
  static const _payloadKey = 'payload';
  static const _cacheDirectoryName = 'data_cache';

  Future<Directory> _cacheDirectory() async {
    final base = await getTemporaryDirectory();
    final directory = Directory('${base.path}/$_cacheDirectoryName');
    if (!directory.existsSync()) await directory.create(recursive: true);
    return directory;
  }

  Future<File> _cacheFile(String key) async {
    final directory = await _cacheDirectory();
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return File('${directory.path}/$name.json');
  }

  // ===== key 命名规范 =====
  // 首页（匿名可访问，登出不清理）：cache_home
  // 歌单详情：cache_playlist_{playlistId}
  // 专辑详情：cache_album_{albumId}
  // 歌手详情：cache_artist_{artistId}
  // 用户信息：cache_user_{userId}
  // 用户歌单列表：cache_user_playlists_{userId}

  /// 用户相关缓存 key 前缀，登出时按前缀清理。
  static const _userCachePrefixes = <String>[
    'cache_user_',
    'cache_playlist_',
    'cache_album_',
    'cache_artist_',
  ];

  /// 读取缓存。无缓存返回 null。
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration? ttl = const Duration(hours: 24),
  }) async {
    final file = await _cacheFile(key);
    String? raw;
    if (file.existsSync()) {
      raw = await file.readAsString();
    } else {
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(key);
      if (raw != null) {
        await _writeRaw(file, raw);
        await prefs.remove(key);
      }
    }
    if (raw == null) return null;
    try {
      final decoded = await compute(_decodeJson, raw);
      if (decoded is! Map<String, dynamic>) return null;
      final payload = decoded[_payloadKey];
      if (payload is! Map<String, dynamic>) return null;
      final savedAt = decoded[_savedAtKey];
      // ttl 为 null 表示持久缓存：只要内容可读就永不过期。
      final isStale =
          ttl != null &&
          (savedAt is! num ||
              DateTime.now().millisecondsSinceEpoch - savedAt.toInt() >
                  ttl.inMilliseconds);
      return CacheResult<T>(data: decode(payload), isStale: isStale);
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存（记录 savedAt = 当前时间）。
  Future<void> write(String key, Map<String, dynamic> payload) async {
    final wrapper = await compute(_encodeJson, {
      _savedAtKey: DateTime.now().millisecondsSinceEpoch,
      _payloadKey: payload,
    });
    await _writeRaw(await _cacheFile(key), wrapper);
  }

  Future<void> _writeRaw(File file, String raw) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(raw, flush: false);
    if (file.existsSync()) await file.delete();
    await temporary.rename(file.path);
  }

  /// 移除单条缓存。
  Future<void> remove(String key) async {
    final file = await _cacheFile(key);
    if (file.existsSync()) await file.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// 登出清理：清除用户相关缓存，保留匿名可访问内容（首页 cache_home）。
  Future<void> clearUserCache(String? userId) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    for (final key in keys) {
      for (final prefix in _userCachePrefixes) {
        if (key.startsWith(prefix)) {
          await prefs.remove(key);
          break;
        }
      }
    }
    final directory = await _cacheDirectory();
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final fileName = entity.uri.pathSegments.last.replaceFirst('.json', '');
        final padding = '=' * ((4 - fileName.length % 4) % 4);
        final cacheKey = utf8.decode(base64Url.decode('$fileName$padding'));
        if (_userCachePrefixes.any(cacheKey.startsWith)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  /// 获取所有数据缓存的总大小（字节）。
  ///
  /// 遍历 SharedPreferences 中的所有 key，计算以 `cache_` 开头或
  /// 歌单缓存相关 key 的字符串大小（UTF-16 每字符约 2 字节）。
  Future<int> getCacheSize() async {
    final directory = await _cacheDirectory();
    final prefs = await SharedPreferences.getInstance();
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is File) total += await entity.length();
    }
    for (final key in prefs.getKeys()) {
      if (key.startsWith('cache_') ||
          key.startsWith('ka_music_cached_playlists')) {
        final value = prefs.getString(key);
        if (value != null) {
          total += value.length * 2; // UTF-16 每字符约 2 字节
        }
      }
    }
    return total;
  }

  /// 获取缓存条目数量。
  Future<int> getCacheCount() async {
    final directory = await _cacheDirectory();
    var count = 0;
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) count++;
    }
    final prefs = await SharedPreferences.getInstance();
    return count +
        prefs.getKeys().where((key) => key.startsWith('cache_')).length;
  }

  /// 清除所有数据缓存（保留用户歌单索引等必要数据）。
  Future<void> clearAllCache() async {
    final directory = await _cacheDirectory();
    if (directory.existsSync()) await directory.delete(recursive: true);
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    for (final key in keys) {
      if (key.startsWith('cache_')) {
        await prefs.remove(key);
      }
    }
  }

  /// stale-while-revalidate 封装。
  ///
  /// 流程：
  /// 1. 读取缓存 → 若命中，立即 [onData](cached)（首屏优先显示，无感）。
  /// 2. 后台执行 [fetch]：
  ///    - 成功 → [write] 缓存 → [onData](fresh)（静默刷新界面）。
  ///    - 失败 → 若缓存存在（哪怕过期）则保持不报错（降级）；
  ///      若完全无缓存则调用 [onError]。
  /// 3. [forceRefresh] = true（下拉刷新）时跳过第 1 步的立即返回，
  ///    优先走 fetch，失败再回退缓存。
  Future<void> swr<T>({
    required String key,
    required Duration ttl,
    required Future<T> Function() fetch,
    required T Function(Map<String, dynamic> json) decode,
    required Map<String, dynamic> Function(T data) encode,
    required void Function(T data) onData,
    void Function(Object error)? onError,
    bool forceRefresh = false,
  }) async {
    // 1. 先读缓存（非强制刷新时立即返回显示）
    CacheResult<T>? cached;
    if (!forceRefresh) {
      cached = await read<T>(key, decode: decode, ttl: ttl);
      if (cached != null) {
        onData(cached.data);
      }
    } else {
      // 强制刷新也先读缓存作为降级兜底，但不立即显示
      cached = await read<T>(key, decode: decode, ttl: ttl);
    }

    // 2. 后台静默刷新
    try {
      final fresh = await fetch();
      await write(key, encode(fresh));
      onData(fresh);
    } catch (error) {
      if (cached != null) {
        // 有缓存（哪怕过期）则降级，不报错
        if (forceRefresh) {
          // 强制刷新模式下前面没有立即显示，这里补显示缓存
          onData(cached.data);
        }
      } else {
        // 完全无缓存，回调错误
        onError?.call(error);
      }
    }
  }
}

dynamic _decodeJson(String raw) => jsonDecode(raw);

String _encodeJson(Map<String, dynamic> value) => jsonEncode(value);
