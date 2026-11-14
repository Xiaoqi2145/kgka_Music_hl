import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/music_models.dart';
import 'android_download_store.dart';

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
    this.sourcePath,
  });

  final DownloadTaskKind kind;
  final Song song;
  final AudioQuality quality;
  final String url;
  final String? sourcePath;
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
  final AndroidDownloadStore _store = const AndroidDownloadStore();

  /// 下载暂存目录。
  ///
  /// Android 的 getDownloadsDirectory 落在应用专属外部目录，系统「下载」中
  /// 不可见，因此先写入应用外部目录，完成后再发布到公共下载目录。其它平台
  /// 直接使用系统下载目录，文件立即可见。
  Future<Directory> downloadDir() async {
    final Directory? base;
    if (AndroidDownloadStore.isSupported) {
      base =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } else {
      base = await getDownloadsDirectory();
    }
    if (base == null) {
      throw StateError('当前平台没有可用的下载目录');
    }
    final dir = Directory('${base.path}/${AppConfig.downloadDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 完成下载后发布到用户可见的下载目录。
  ///
  /// Android 通过 MediaStore 写入「下载/KA Music」并返回 content URI；
  /// 其它平台文件本身就在系统下载目录，直接返回路径。
  Future<String> _publishDownload({
    required String path,
    required Song song,
    required AudioQuality quality,
  }) async {
    if (!AndroidDownloadStore.isSupported) return path;
    final locator = await _store.publish(
      sourcePath: path,
      displayName: downloadFileNameFor(song, quality),
      mimeType: quality == AudioQuality.lossless ? 'audio/flac' : 'audio/mpeg',
    );
    await deleteFile(path);
    return locator;
  }

  /// 旧版本下载目录，仅用于把已有文件迁移到系统下载目录。
  Future<Directory> legacyDownloadDir() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}/${AppConfig.legacyDownloadDirName}');
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

  /// 下载文件名：{artist} - {title} [{quality}] {identity}.{ext}
  String downloadFileNameFor(Song song, AudioQuality quality) {
    final ext = quality == AudioQuality.lossless ? 'flac' : 'mp3';
    final title = _safeFilePart(song.title, '未知歌曲');
    final artist = _safeFilePart(song.artist, '未知艺人');
    final identity = _safeFilePart(song.hash, 'track');
    return '$artist - $title [${quality.badge}] $identity.$ext';
  }

  String _safeFilePart(String value, String fallback) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return fallback;
    return cleaned.length > 60 ? cleaned.substring(0, 60).trim() : cleaned;
  }

  /// 判断索引中的定位符是否已经位于用户可见的下载目录。
  Future<bool> isPublished(String locator) async {
    if (AndroidDownloadStore.isLocator(locator)) return true;
    final visible = await downloadDir();
    return File(locator).parent.path == visible.path;
  }

  /// 把旧版本遗留的下载文件移动到用户可见的下载目录。
  Future<String> relocateDownload({
    required Song song,
    required AudioQuality quality,
    required String sourcePath,
  }) async {
    if (AndroidDownloadStore.isSupported) {
      final locator = await _publishDownload(
        path: sourcePath,
        song: song,
        quality: quality,
      );
      return locator;
    }
    final dir = await downloadDir();
    final target = '${dir.path}/${downloadFileNameFor(song, quality)}';
    await File(sourcePath).copy(target);
    await File(sourcePath).delete();
    return target;
  }

  /// 删除迁移后为空的旧下载目录。
  Future<void> removeLegacyDownloadDirIfEmpty() async {
    final dir = await legacyDownloadDir();
    if (!dir.existsSync()) return;
    final empty = await dir.list().isEmpty;
    if (empty) await dir.delete();
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

  /// 将同音质播放缓存复制到持久目录，保留源文件；与下载共享队列和取消机制。
  Future<String> copyPlaybackCacheToDownload({
    required Song song,
    required AudioQuality quality,
    required String sourcePath,
  }) {
    final completer = Completer<String>();
    _enqueue(
      _PendingTask(
        kind: DownloadTaskKind.download,
        song: song,
        quality: quality,
        url: '',
        sourcePath: sourcePath,
        completer: completer,
      ),
    );
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

    // 取消后立即重试也不能并发写同一个 .part 文件。
    final index = _queue.indexWhere(
      (task) => !_runningTasks.containsKey(
        '${task.kind.name}:${cacheKeyFor(task.song, task.quality)}',
      ),
    );
    if (index < 0) return;
    final task = _queue.removeAt(index);
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
    final taskKey = '${task.kind.name}:$key';
    final fileName = task.kind == DownloadTaskKind.download
        ? downloadFileNameFor(task.song, task.quality)
        : fileNameFor(task.song, task.quality);
    final cancelToken = CancelToken();
    void checkCancelled() {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    }

    _cancelTokens[taskKey] = cancelToken;
    _runningTasks[taskKey] = task;
    File? partFile;
    String? publishedPath;

    try {
      final dir = task.kind == DownloadTaskKind.download
          ? await downloadDir()
          : await playCacheDir();
      checkCancelled();
      final targetPath = '${dir.path}/$fileName';
      final partPath = '$targetPath.part';
      partFile = File(partPath);
      if (task.sourcePath != null) {
        if (await fileSize(task.sourcePath!) <= 0) {
          throw StateError('播放缓存文件不存在或为空');
        }
        checkCancelled();
        await File(task.sourcePath!).copy(partPath);
        checkCancelled();
        await partFile.rename(targetPath);
        publishedPath = targetPath;
        checkCancelled();
        return await _publishDownload(
          path: targetPath,
          song: task.song,
          quality: task.quality,
        );
      }
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

      // 下载完成前最后检查取消，防止已取消任务发布最终文件。
      checkCancelled();
      if (partFile.existsSync()) {
        await partFile.rename(targetPath);
        publishedPath = targetPath;
      }
      checkCancelled();
      return await _publishDownload(
        path: targetPath,
        song: task.song,
        quality: task.quality,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        if (publishedPath != null) await deleteFile(publishedPath);
        if (task.kind == DownloadTaskKind.playCache ||
            task.sourcePath != null) {
          if (partFile != null && partFile.existsSync()) {
            await partFile.delete();
          }
        }
      }
      rethrow;
    } finally {
      _cancelTokens.remove(taskKey);
      _runningTasks.remove(taskKey);
    }
  }

  /// 取消下载/缓存任务。
  Future<void> cancel(String cacheKey) async {
    final queued = _queue
        .where(
          (task) =>
              task.kind == DownloadTaskKind.download &&
              cacheKeyFor(task.song, task.quality) == cacheKey,
        )
        .toList();
    _queue.removeWhere(
      (task) =>
          task.kind == DownloadTaskKind.download &&
          cacheKeyFor(task.song, task.quality) == cacheKey,
    );
    for (final task in queued) {
      if (!task.completer.isCompleted) {
        task.completer.completeError(StateError('download cancelled'));
      }
    }
    final token = _cancelTokens['download:$cacheKey'];
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
    final taskKey = 'playCache:$cacheKey';
    if (_runningTasks[taskKey]?.kind == DownloadTaskKind.playCache) {
      final token = _cancelTokens[taskKey];
      if (token != null && !token.isCancelled) token.cancel();
    }
  }

  /// 删除文件或已发布的系统下载条目（若存在）。
  Future<void> deleteFile(String locator) async {
    if (AndroidDownloadStore.isLocator(locator)) {
      await _store.delete(locator);
      return;
    }
    final file = File(locator);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// 获取文件大小（字节），不存在返回 0。
  Future<int> fileSize(String locator) async {
    if (AndroidDownloadStore.isLocator(locator)) {
      return _store.sizeOf(locator);
    }
    final file = File(locator);
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

  /// 删除启动后不在索引中的音频文件和上次崩溃遗留的分片。
  Future<void> cleanPlayCacheOrphans(Set<String> indexedPaths) async {
    final dir = await playCacheDir();
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final path = entity.path;
      final stalePart =
          path.endsWith('.part') &&
          DateTime.now().difference(await entity.lastModified()) >
              const Duration(days: 1);
      if (stalePart ||
          ((path.endsWith('.mp3') || path.endsWith('.flac')) &&
              !indexedPaths.contains(path))) {
        try {
          await entity.delete();
        } catch (_) {
          // A file may still be held by the platform; leave it for a later pass.
        }
      }
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
  /// [entries] 为当前缓存索引（按最近访问时间升序排列）。
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

    // 按最近访问时间升序删除最久未使用条目
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
