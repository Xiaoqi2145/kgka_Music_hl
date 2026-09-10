import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/music_models.dart';

/// 下载任务类型。
enum DownloadTaskKind { download, playCache }

/// 内部待执行任务。
class _PendingTask {
  _PendingTask({
    required this.kind,
    required this.song,
    required this.quality,
    required this.url,
    required this.completer,
    this.onProgress,
  });

  final DownloadTaskKind kind;
  final Song song;
  final AudioQuality quality;
  final String url;
  final Completer<String> completer;
  final void Function(int received, int total)? onProgress;
}

/// 歌曲下载服务（IO 层 + dio 下载 + 并发管理）。
///
/// 下载到持久目录（用户主动下载），播放缓存到临时目录（系统可清理）。
/// 两者共享并发上限，用户主动下载优先。
class DownloadService {
  DownloadService();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
    ),
  );
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, _PendingTask> _runningTasks = {};
  final int _maxConcurrent = AppConfig.maxConcurrentDownloads;
  int _running = 0;
  final List<_PendingTask> _queue = [];

  /// 持久下载目录。
  Future<Directory> downloadDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/${AppConfig.downloadDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 临时播放缓存目录。
  Future<Directory> playCacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/${AppConfig.playCacheDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 文件命名：{hash}_{quality.apiValue}.{ext}
  String fileNameFor(Song song, AudioQuality quality) {
    final ext = quality == AudioQuality.lossless ? 'flac' : 'mp3';
    final safeHash = song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '${safeHash}_${quality.apiValue}.$ext';
  }

  /// 缓存 key：{hash}_{quality.apiValue}
  String cacheKeyFor(Song song, AudioQuality quality) {
    final safeHash = song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '${safeHash}_${quality.apiValue}';
  }

  /// 下载到持久目录（用户下载）。支持断点续传。
  ///
  /// [onProgress] 回调 (received, total)。返回最终文件路径。
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.download,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
      onProgress: onProgress,
    );
    _enqueue(task);
    return completer.future;
  }

  /// 下载到临时缓存目录（播放缓存）。无进度上报（静默）。
  Future<String> cacheForPlayback({
    required Song song,
    required AudioQuality quality,
    required String url,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.playCache,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
    );
    _enqueue(task);
    return completer.future;
  }

  void _enqueue(_PendingTask task) {
    // 用户下载优先：插入队列头部之后（在其它下载任务之后、播放缓存之前）
    if (task.kind == DownloadTaskKind.download) {
      // 插入到第一个 playCache 任务之前
      final firstPlayCache = _queue.indexWhere(
        (t) => t.kind == DownloadTaskKind.playCache,
      );
      if (firstPlayCache >= 0) {
        _queue.insert(firstPlayCache, task);
      } else {
        _queue.add(task);
      }
    } else {
      _queue.add(task);
    }
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_running >= _maxConcurrent) return;
    if (_queue.isEmpty) return;

    final task = _queue.removeAt(0);
    _running++;

    try {
      final path = await _executeTask(task);
      task.completer.complete(path);
    } catch (error) {
      task.completer.completeError(error);
    } finally {
      _running--;
      _processQueue();
    }
  }

  Future<String> _executeTask(_PendingTask task) async {
    final key = cacheKeyFor(task.song, task.quality);
    final fileName = fileNameFor(task.song, task.quality);
    final dir = task.kind == DownloadTaskKind.download
        ? await downloadDir()
        : await playCacheDir();
    final targetPath = '${dir.path}/$fileName';
    final partPath = '$targetPath.part';
    final partFile = File(partPath);
    final cancelToken = CancelToken();
    _cancelTokens[key] = cancelToken;
    _runningTasks[key] = task;

    try {
      // 断点续传：检查已有 .part 文件大小
      int startOffset = 0;
      if (partFile.existsSync()) {
        startOffset = await partFile.length();
      }

      final headers = <String, dynamic>{};
      if (startOffset > 0) {
        headers[HttpHeaders.rangeHeader] = 'bytes=$startOffset-';
      }

      var response = await _dio.download(
        task.url,
        partPath,
        onReceiveProgress: (received, total) {
          final actualTotal = startOffset + total;
          final actualReceived = startOffset + received;
          task.onProgress?.call(actualReceived, actualTotal);
        },
        options: Options(headers: headers),
        cancelToken: cancelToken,
        deleteOnError: false,
        fileAccessMode: startOffset > 0
            ? FileAccessMode.append
            : FileAccessMode.write,
      );

      // 服务端忽略 Range 时，丢弃旧分片并从头下载，避免文件拼接损坏。
      if (startOffset > 0 && response.statusCode != 206) {
        await partFile.delete();
        startOffset = 0;
        response = await _dio.download(
          task.url,
          partPath,
          onReceiveProgress: (received, total) {
            task.onProgress?.call(received, total);
          },
          cancelToken: cancelToken,
          deleteOnError: false,
        );
      }

      if (startOffset > 0) {
        final contentRange = response.headers.value(
          HttpHeaders.contentRangeHeader,
        );
        final rangeStart = contentRange == null
            ? null
            : int.tryParse(
                RegExp(r'^bytes (\d+)-').firstMatch(contentRange)?.group(1) ??
                    '',
              );
        if (response.statusCode != 206 || rangeStart != startOffset) {
          throw StateError('服务器返回了不匹配的断点范围');
        }
      }
      if (!partFile.existsSync() || await partFile.length() == 0) {
        throw StateError('下载结果为空');
      }
      final actualLength = await partFile.length();
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      final match = range == null
          ? null
          : RegExp(r'/([0-9]+)$').firstMatch(range);
      final expected = match == null ? null : int.tryParse(match.group(1)!);
      if (expected != null && actualLength != expected) {
        await partFile.delete();
        throw StateError('下载不完整：$actualLength/$expected');
      }
      final bytes = await partFile
          .openRead(0, 4)
          .fold<List<int>>([], (a, b) => [...a, ...b]);
      final valid = task.quality == AudioQuality.lossless
          ? bytes.length >= 4 && String.fromCharCodes(bytes) == 'fLaC'
          : bytes.length >= 2 &&
                ((bytes[0] == 0x49 && bytes[1] == 0x44) ||
                    (bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0));
      if (!valid) {
        await partFile.delete();
        throw StateError('下载文件不是有效音频');
      }

      // 下载完成，重命名 .part 为最终文件
      if (partFile.existsSync()) {
        await partFile.rename(targetPath);
      }

      return targetPath;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) &&
          task.kind == DownloadTaskKind.playCache) {
        if (partFile.existsSync()) await partFile.delete();
      }
      rethrow;
    } finally {
      _cancelTokens.remove(key);
      _runningTasks.remove(key);
    }
  }

  /// 取消下载/缓存任务。
  Future<void> cancel(String cacheKey) async {
    final queued = _queue
        .where((task) => cacheKeyFor(task.song, task.quality) == cacheKey)
        .toList();
    _queue.removeWhere(
      (task) => cacheKeyFor(task.song, task.quality) == cacheKey,
    );
    for (final task in queued) {
      if (!task.completer.isCompleted) {
        task.completer.completeError(StateError('download cancelled'));
      }
    }
    final token = _cancelTokens[cacheKey];
    if (token != null && !token.isCancelled) {
      token.cancel();
    }
  }

  Future<void> cancelPlayCache(String cacheKey) async {
    final queued = _queue
        .where(
          (task) =>
              task.kind == DownloadTaskKind.playCache &&
              cacheKeyFor(task.song, task.quality) == cacheKey,
        )
        .toList();
    _queue.removeWhere(
      (task) =>
          task.kind == DownloadTaskKind.playCache &&
          cacheKeyFor(task.song, task.quality) == cacheKey,
    );
    for (final task in queued) {
      if (!task.completer.isCompleted) {
        task.completer.completeError(StateError('play cache cancelled'));
      }
      final directory = await playCacheDir();
      final part = File(
        '${directory.path}/${fileNameFor(task.song, task.quality)}.part',
      );
      if (part.existsSync()) await part.delete();
    }
    if (_runningTasks[cacheKey]?.kind == DownloadTaskKind.playCache) {
      final token = _cancelTokens[cacheKey];
      if (token != null && !token.isCancelled) token.cancel();
    }
  }

  /// 删除文件（若存在）。
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// 获取文件大小（字节），不存在返回 0。
  Future<int> fileSize(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      return await file.length();
    }
    return 0;
  }

  /// 获取下载目录的总大小（字节）。
  Future<int> getDownloadDirSize() async {
    try {
      final dir = await downloadDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 获取播放缓存目录的总大小（字节）。
  Future<int> getPlayCacheDirSize() async {
    try {
      final dir = await playCacheDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空整个播放缓存目录。
  Future<void> clearPlayCacheDir() async {
    final dir = await playCacheDir();
    if (dir.existsSync()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }
    }
  }

  /// LRU 清理播放缓存至 [maxBytes] 以下。
  ///
  /// [entries] 为当前缓存索引（按 cachedAt 升序排列）。
  /// [excludePaths] 中的文件跳过清理（如正在播放的文件）。
  Future<Set<String>> prunePlayCache(
    List<({String cacheKey, String filePath, int size, DateTime cachedAt})>
    entries, {
    Set<String> excludePaths = const {},
    int maxBytes = AppConfig.defaultPlayCacheMaxBytes,
  }) async {
    var totalSize = entries.fold<int>(0, (total, entry) => total + entry.size);
    final removed = <String>{};

    if (totalSize <= maxBytes) return removed;

    // 按 cachedAt 升序删除最旧条目
    final sorted = List.of(entries)
      ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));

    for (final entry in sorted) {
      if (totalSize <= maxBytes) break;
      if (excludePaths.contains(entry.filePath)) continue;
      await deleteFile(entry.filePath);
      totalSize -= entry.size;
      removed.add(entry.cacheKey);
    }
    return removed;
  }

  /// 关闭 Dio（应用退出时调用）。
  void dispose() {
    _dio.close();
  }
}
