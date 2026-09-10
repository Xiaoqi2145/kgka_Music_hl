import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/loudness_data.dart';
import '../models/music_models.dart';
import '../services/download_service.dart';
import '../services/music_api.dart';

/// 下载状态枚举。
enum DownloadStatus { notDownloaded, downloading, downloaded, failed }

/// 下载条目。
class DownloadEntry {
  const DownloadEntry({
    required this.song,
    required this.quality,
    required this.status,
    this.progress = 0,
    this.filePath,
    this.error,
    this.downloadedAt,
    this.loudness,
  });

  final Song song;
  final AudioQuality quality;
  final DownloadStatus status;
  final double progress;
  final String? filePath;
  final String? error;
  final DateTime? downloadedAt;
  final LoudnessData? loudness;

  DownloadEntry copyWith({
    DownloadStatus? status,
    double? progress,
    String? filePath,
    bool clearFilePath = false,
    String? error,
    DateTime? downloadedAt,
    LoudnessData? loudness,
  }) {
    return DownloadEntry(
      song: song,
      quality: quality,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      filePath: clearFilePath ? null : (filePath ?? this.filePath),
      error: error,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      loudness: loudness ?? this.loudness,
    );
  }
}

/// 播放缓存条目。
class PlayCacheEntry {
  const PlayCacheEntry({
    required this.cacheKey,
    required this.song,
    required this.quality,
    required this.filePath,
    required this.size,
    required this.cachedAt,
    this.loudness,
  });

  final String cacheKey;
  final Song song;
  final AudioQuality quality;
  final String filePath;
  final int size;
  final DateTime cachedAt;
  final LoudnessData? loudness;
}

/// 下载与播放缓存控制器。
///
/// 管理用户主动下载（持久目录）和播放缓存（临时目录）。
/// 下载状态通过 [DownloadStatus] + [entryFor] 查询，UI 用 AnimatedBuilder 监听。
class DownloadController extends ChangeNotifier {
  DownloadController(this._service, this._api);

  final DownloadService _service;
  final MusicApi _api;

  static const _downloadsIndexKey = 'ka_music_downloads_index';
  static const _playCacheIndexKey = 'ka_music_play_cache_index';
  static const _playCacheMaxBytesKey = 'settings.play_cache_max_bytes';

  final Map<String, DownloadEntry> _downloads = {}; // key = hash
  final Map<String, PlayCacheEntry> _playCache = {}; // key = hash_quality
  bool _initialized = false;
  Timer? _playCachePersistTimer;
  Future<void>? _playCachePersistFuture;
  int playCacheMaxBytes = AppConfig.defaultPlayCacheMaxBytes;

  /// 启动时加载索引并校验文件存在性。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _loadPlayCacheSettings();
    await _loadDownloads();
    await _loadPlayCache();
    // 启动时 LRU 清理播放缓存
    await _prunePlayCache(excludePaths: const {});
  }

  Future<void> _loadPlayCacheSettings() async {
    final prefs = await SharedPreferences.getInstance();
    playCacheMaxBytes = _normalizePlayCacheMaxBytes(
      prefs.getInt(_playCacheMaxBytesKey) ?? playCacheMaxBytes,
    );
  }

  int _normalizePlayCacheMaxBytes(int value) {
    return value.clamp(
      AppConfig.minPlayCacheMaxBytes,
      AppConfig.maxPlayCacheMaxBytes,
    );
  }

  Future<void> _loadDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_downloadsIndexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        // 校验文件存在性
        if (!await _service.fileSize(filePath).then((s) => s > 0)) continue;
        final downloadedAtStr = item['downloadedAt'] as String?;
        final loudnessJson = item['loudness'];
        _downloads[song.hash] = DownloadEntry(
          song: song,
          quality: quality,
          status: DownloadStatus.downloaded,
          filePath: filePath,
          downloadedAt: downloadedAtStr != null
              ? DateTime.tryParse(downloadedAtStr)
              : null,
          loudness: loudnessJson is Map
              ? LoudnessData.fromJson(loudnessJson.cast<String, dynamic>())
              : null,
        );
      }
    } catch (_) {}
  }

  Future<void> _loadPlayCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playCacheIndexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final cacheKey = item['cacheKey'] as String? ?? '';
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        // 校验文件存在性
        final size = await _service.fileSize(filePath);
        if (size == 0) continue;
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final cachedAtStr = item['cachedAt'] as String?;
        final loudnessJson = item['loudness'];
        _playCache[cacheKey] = PlayCacheEntry(
          cacheKey: cacheKey,
          song: song,
          quality: quality,
          filePath: filePath,
          size: size,
          cachedAt: cachedAtStr != null
              ? DateTime.tryParse(cachedAtStr) ?? DateTime.now()
              : DateTime.now(),
          loudness: loudnessJson is Map
              ? LoudnessData.fromJson(loudnessJson.cast<String, dynamic>())
              : null,
        );
      }
    } catch (_) {}
  }

  Future<void> _persistDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _downloads.values
        .where((e) => e.status == DownloadStatus.downloaded)
        .map(
          (e) => {
            'song': e.song.toCache(),
            'quality': e.quality.apiValue,
            'filePath': e.filePath,
            'downloadedAt': e.downloadedAt?.toIso8601String(),
            if (e.loudness != null) 'loudness': e.loudness!.toJson(),
          },
        )
        .toList();
    await prefs.setString(_downloadsIndexKey, jsonEncode(list));
  }

  Future<void> _persistPlayCache() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _playCache.values
        .map(
          (e) => {
            'cacheKey': e.cacheKey,
            'song': e.song.toCache(),
            'quality': e.quality.apiValue,
            'filePath': e.filePath,
            'size': e.size,
            'cachedAt': e.cachedAt.toIso8601String(),
            if (e.loudness != null) 'loudness': e.loudness!.toJson(),
          },
        )
        .toList();
    await prefs.setString(_playCacheIndexKey, jsonEncode(list));
  }

  void _schedulePlayCachePersist() {
    _playCachePersistTimer?.cancel();
    _playCachePersistTimer = Timer(
      const Duration(seconds: 5),
      () => unawaited(flush()),
    );
  }

  Future<void> flush() async {
    _playCachePersistTimer?.cancel();
    _playCachePersistTimer = null;
    final pending = _playCachePersistFuture;
    if (pending != null) return pending;
    final future = _persistPlayCache();
    _playCachePersistFuture = future;
    try {
      await future;
    } finally {
      if (identical(_playCachePersistFuture, future)) {
        _playCachePersistFuture = null;
      }
    }
  }

  // ===== 查询 =====

  /// 返回本地文件路径：优先已下载 > 播放缓存（按当前音质）。无则 null。
  String? localPathFor(Song song, AudioQuality quality) {
    return localSourceFor(song, quality)?.path;
  }

  /// 返回本地音频及其持久化响度元数据，优先级与 [localPathFor] 一致。
  ({String path, LoudnessData? loudness})? localSourceFor(
    Song song,
    AudioQuality quality,
  ) {
    final key = _service.cacheKeyFor(song, quality);
    // 优先已下载（同音质）
    final download = _downloads[song.hash];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null &&
        _service.cacheKeyFor(download!.song, download.quality) == key) {
      return (path: download.filePath!, loudness: download.loudness);
    }
    // 其次播放缓存
    final cache = _playCache[key];
    if (cache != null) {
      return (path: cache.filePath, loudness: cache.loudness);
    }
    return null;
  }

  bool isDownloaded(Song song) =>
      _downloads[song.hash]?.status == DownloadStatus.downloaded;

  DownloadEntry? entryFor(Song song) => _downloads[song.hash];

  List<Song> get downloadedSongs => _downloads.values
      .where((e) => e.status == DownloadStatus.downloaded)
      .map((e) => e.song)
      .toList();

  List<DownloadEntry> get downloadEntries => _downloads.values.toList();

  List<PlayCacheEntry> get playCacheEntries => _playCache.values.toList();

  /// 获取下载目录大小（字节）。
  Future<int> getDownloadDirSize() => _service.getDownloadDirSize();

  /// 获取播放缓存目录大小（字节）。
  Future<int> getPlayCacheDirSize() => _service.getPlayCacheDirSize();

  /// 设置播放缓存上限（字节），并立即按新上限清理。
  Future<void> setPlayCacheMaxBytes(int bytes) async {
    final normalized = _normalizePlayCacheMaxBytes(bytes);
    if (playCacheMaxBytes == normalized) return;
    playCacheMaxBytes = normalized;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_playCacheMaxBytesKey, normalized);
    await _prunePlayCache();
  }

  // ===== 下载操作 =====

  /// 用户主动下载歌曲。
  Future<void> download(Song song, AudioQuality quality) async {
    final hash = song.hash;
    final existing = _downloads[hash];
    if (existing?.status == DownloadStatus.downloading) return;
    if (existing?.status == DownloadStatus.downloaded) return;

    _downloads[hash] = DownloadEntry(
      song: song,
      quality: quality,
      status: DownloadStatus.downloading,
      progress: 0,
    );
    notifyListeners();

    try {
      final playUrl = await _api.songUrl(song, quality: quality);
      if (playUrl.url.isEmpty) {
        throw Exception('这首歌暂时没有可播放地址');
      }
      final path = await _service.download(
        song: song,
        quality: quality,
        url: playUrl.url,
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : 0.0;
          final entry = _downloads[hash];
          if (entry?.status == DownloadStatus.downloading) {
            _downloads[hash] = entry!.copyWith(progress: progress);
            notifyListeners();
          }
        },
      );
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.downloaded,
        progress: 1,
        filePath: path,
        downloadedAt: DateTime.now(),
        loudness: playUrl.loudness,
      );
      notifyListeners();
      await _persistDownloads();
    } catch (error) {
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.failed,
        error: error.toString(),
      );
      notifyListeners();
    }
  }

  /// 取消下载。
  Future<void> cancelDownload(Song song) async {
    final hash = song.hash;
    final entry = _downloads[hash];
    if (entry?.status != DownloadStatus.downloading) return;
    final key = _service.cacheKeyFor(song, entry!.quality);
    await _service.cancel(key);
    _downloads.remove(hash);
    notifyListeners();
  }

  /// 删除单个已下载歌曲。
  Future<void> deleteDownload(Song song) async {
    final hash = song.hash;
    final entry = _downloads[hash];
    if (entry?.filePath != null) {
      await _service.deleteFile(entry!.filePath!);
    }
    _downloads.remove(hash);
    notifyListeners();
    await _persistDownloads();
  }

  /// 清空所有已下载歌曲。
  Future<void> clearAllDownloads() async {
    for (final entry in _downloads.values) {
      if (entry.filePath != null) {
        await _service.deleteFile(entry.filePath!);
      }
    }
    _downloads.clear();
    notifyListeners();
    await _persistDownloads();
  }

  // ===== 播放缓存 =====

  /// 后台缓存当前播放歌曲（首播后调用）。url 来自 songUrl 结果。
  Future<void> cacheForPlayback(
    Song song,
    AudioQuality quality,
    String url, {
    LoudnessData? loudness,
  }) async {
    final key = _service.cacheKeyFor(song, quality);
    // 已有缓存或已在下载则跳过
    final existing = _playCache[key];
    if (existing != null) {
      if (existing.loudness == null && loudness?.canNormalize == true) {
        _playCache[key] = PlayCacheEntry(
          cacheKey: existing.cacheKey,
          song: existing.song,
          quality: existing.quality,
          filePath: existing.filePath,
          size: existing.size,
          cachedAt: existing.cachedAt,
          loudness: loudness,
        );
        _schedulePlayCachePersist();
      }
      return;
    }
    if (_downloads[song.hash]?.status == DownloadStatus.downloading) return;

    try {
      final path = await _service.cacheForPlayback(
        song: song,
        quality: quality,
        url: url,
      );
      final size = await _service.fileSize(path);
      _playCache[key] = PlayCacheEntry(
        cacheKey: key,
        song: song,
        quality: quality,
        filePath: path,
        size: size,
        cachedAt: DateTime.now(),
        loudness: loudness,
      );
      notifyListeners();
      _schedulePlayCachePersist();
      // LRU 清理
      await _prunePlayCache(excludePaths: {path});
    } catch (_) {
      // 播放缓存失败静默忽略
    }
  }

  /// 为旧版索引中的本地音频补写响度元数据。
  Future<void> updateLocalLoudness(
    Song song,
    AudioQuality quality,
    LoudnessData loudness,
  ) async {
    if (!loudness.canNormalize) return;
    final key = _service.cacheKeyFor(song, quality);
    final download = _downloads[song.hash];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null &&
        _service.cacheKeyFor(download!.song, download.quality) == key) {
      _downloads[song.hash] = download.copyWith(loudness: loudness);
      await _persistDownloads();
      return;
    }

    final cache = _playCache[key];
    if (cache == null) return;
    _playCache[key] = PlayCacheEntry(
      cacheKey: cache.cacheKey,
      song: cache.song,
      quality: cache.quality,
      filePath: cache.filePath,
      size: cache.size,
      cachedAt: cache.cachedAt,
      loudness: loudness,
    );
    _schedulePlayCachePersist();
  }

  Future<void> cancelPlaybackCache(Song song, AudioQuality quality) async {
    final key = _service.cacheKeyFor(song, quality);
    await _service.cancelPlayCache(key);
  }

  /// 清空所有播放缓存。
  Future<void> clearPlayCache() async {
    await _service.clearPlayCacheDir();
    _playCache.clear();
    notifyListeners();
    await flush();
  }

  Future<bool> invalidateLocalSource(Song song, AudioQuality quality) async {
    final key = _service.cacheKeyFor(song, quality);
    final cache = _playCache.remove(key);
    if (cache != null) await _service.deleteFile(cache.filePath);
    final download = _downloads[song.hash];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null &&
        _service.cacheKeyFor(download!.song, download.quality) == key) {
      await _service.deleteFile(download.filePath!);
      _downloads[song.hash] = download.copyWith(
        status: DownloadStatus.failed,
        clearFilePath: true,
        error: '本地文件损坏，请重新下载',
      );
      notifyListeners();
      await _persistDownloads();
      return true;
    }
    if (cache != null) {
      notifyListeners();
      _schedulePlayCachePersist();
      return true;
    }
    return false;
  }

  /// 删除单首播放缓存。
  Future<void> deletePlayCache(Song song, AudioQuality quality) async {
    final key = _service.cacheKeyFor(song, quality);
    final entry = _playCache[key];
    if (entry != null) {
      await _service.deleteFile(entry.filePath);
      _playCache.remove(key);
      notifyListeners();
      _schedulePlayCachePersist();
    }
  }

  Future<void> _prunePlayCache({Set<String> excludePaths = const {}}) async {
    final entries =
        _playCache.values
            .map(
              (e) => (
                cacheKey: e.cacheKey,
                filePath: e.filePath,
                size: e.size,
                cachedAt: e.cachedAt,
              ),
            )
            .toList()
          ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));

    final removed = await _service.prunePlayCache(
      entries,
      excludePaths: excludePaths,
      maxBytes: playCacheMaxBytes,
    );

    if (removed.isNotEmpty) {
      for (final key in removed) {
        _playCache.remove(key);
      }
      notifyListeners();
      _schedulePlayCachePersist();
    }
  }

  @override
  void dispose() {
    unawaited(flush());
    super.dispose();
  }
}
