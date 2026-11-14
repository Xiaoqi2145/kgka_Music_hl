import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kgka_music_hl/config/app_config.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/models/loudness_data.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';

const _quality = AudioQuality.high;
const _loudness = LoudnessData(lufs: -12.5, gain: -1, peak: 0.9);
const _audio = [0x49, 0x44, 0x33, 1, 2, 3];
Song _song(String hash, {bool cloud = false}) => Song(
  id: hash,
  title: hash,
  artist: 'artist',
  hash: hash,
  isCloudDrive: cloud,
);

class _Api implements MusicApi {
  int calls = 0;
  int cloudCalls = 0;
  Completer<PlayUrl>? pending;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    calls++;
    return pending?.future ??
        PlayUrl(
          url: 'https://example.invalid/audio',
          hash: song.hash,
          loudness: _loudness,
        );
  }

  @override
  Future<PlayUrl> cloudSongUrl(Song song) async {
    cloudCalls++;
    return PlayUrl(url: 'https://example.invalid/cloud', hash: song.hash);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DirectoryService extends DownloadService {
  _DirectoryService(this.root);
  final Directory root;
  Completer<void>? directoryGate;

  @override
  Future<Directory> downloadDir() async {
    await directoryGate?.future;
    return Directory('${root.path}/downloads')..createSync(recursive: true);
  }

  @override
  Future<Directory> playCacheDir() async =>
      Directory('${root.path}/cache')..createSync(recursive: true);

  @override
  Future<Directory> legacyDownloadDir() async =>
      Directory('${root.path}/legacy')..createSync(recursive: true);
}

class _NetworkCall {
  _NetworkCall(this.path, this.onProgress);
  final String path;
  final void Function(int, int) onProgress;
  final done = Completer<String>();
  void succeed() {
    File(path).writeAsBytesSync(_audio);
    done.complete(path);
  }
}

class _Service extends _DirectoryService {
  _Service(super.root);
  final requests = <_NetworkCall>[];
  final cancelled = <String>[];
  final cancelledCaches = <String>[];
  bool holdDownloads = false;
  bool failDownloads = false;
  int cacheCalls = 0;
  int copyCalls = 0;
  int? reportedSize;

  @override
  Future<int> fileSize(String path) async =>
      reportedSize ?? await super.fileSize(path);
  Completer<void>? cacheGate;
  Completer<void>? copyGate;
  Completer<void>? deleteGate;

  @override
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int, int) onProgress,
  }) async {
    if (failDownloads) throw StateError('network failed');
    final dir = await downloadDir();
    final call = _NetworkCall(
      '${dir.path}/${fileNameFor(song, quality)}',
      onProgress,
    );
    requests.add(call);
    if (!holdDownloads) call.succeed();
    return call.done.future;
  }

  @override
  Future<String> cacheForPlayback({
    required Song song,
    required AudioQuality quality,
    required String url,
  }) async {
    cacheCalls++;
    final dir = await playCacheDir();
    final file = File('${dir.path}/${fileNameFor(song, quality)}');
    file.writeAsBytesSync(_audio);
    await cacheGate?.future;
    return file.path;
  }

  @override
  Future<String> copyPlaybackCacheToDownload({
    required Song song,
    required AudioQuality quality,
    required String sourcePath,
  }) async {
    copyCalls++;
    await copyGate?.future;
    return super.copyPlaybackCacheToDownload(
      song: song,
      quality: quality,
      sourcePath: sourcePath,
    );
  }

  @override
  Future<void> cancel(String key) async {
    cancelled.add(key);
    await super.cancel(key);
  }

  @override
  Future<void> cancelPlayCache(String key) async {
    cancelledCaches.add(key);
    // Deliberately let fake IO finish late to exercise controller epoch guards.
    await super.cancelPlayCache(key);
  }

  @override
  Future<void> deleteFile(String path) async {
    await deleteGate?.future;
    await super.deleteFile(path);
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Service service;
  late _Api api;
  late DownloadController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('ka_storage_lifecycle_');
    service = _Service(root);
    api = _Api();
    controller = DownloadController(service, api);
    await controller.initialize();
  });

  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await _turn();
    service.dispose();
    await root.delete(recursive: true);
  });

  Future<PlayCacheEntry> seed(
    Song song, {
    AudioQuality quality = _quality,
  }) async {
    await controller.cacheForPlayback(
      song,
      quality,
      'https://example.invalid/cache',
      loudness: _loudness,
    );
    return controller.playCacheEntries.singleWhere(
      (e) => e.song.hash == song.hash,
    );
  }

  test(
    'same-quality cache is copied, retained and persisted with loudness',
    () async {
      final song = _song('cached');
      final cache = await seed(song);
      await controller.download(song, _quality);
      final entry = controller.entryFor(song)!;
      expect(entry.status, DownloadStatus.downloaded);
      expect(entry.filePath, isNot(cache.filePath));
      expect(await File(entry.filePath!).readAsBytes(), _audio);
      expect(await File(cache.filePath).readAsBytes(), _audio);
      expect(entry.loudness, same(_loudness));
      expect(api.calls, 0);
      expect(service.requests, isEmpty);
      expect(service.copyCalls, 1);

      final reloaded = DownloadController(service, api);
      await reloaded.initialize();
      expect(reloaded.entryFor(song)!.loudness!.toJson(), _loudness.toJson());
      expect(reloaded.localSourceFor(song, _quality)!.path, entry.filePath);
      await reloaded.flush();
      reloaded.dispose();
    },
  );

  test('different quality does not reuse cache', () async {
    final song = _song('quality');
    await seed(song, quality: AudioQuality.standard);
    await controller.download(song, _quality);
    expect(api.calls, 1);
    expect(service.copyCalls, 0);
    expect(controller.entryFor(song)!.quality, _quality);
    expect(controller.entryFor(song)!.loudness, same(_loudness));
  });

  test('missing indexed cache falls back to network', () async {
    final song = _song('missing');
    final cache = await seed(song);
    await File(cache.filePath).delete();
    await controller.download(song, _quality);
    expect(api.calls, 1);
    expect(service.copyCalls, 0);
    expect(controller.isDownloaded(song), isTrue);
  });

  test('cloud download resolves cloud URL, not catalog URL', () async {
    await controller.download(_song('cloud', cloud: true), _quality);
    expect(api.cloudCalls, 1);
    expect(api.calls, 0);
  });

  test(
    'single and bulk cleanup preserve active and armed-next cache',
    () async {
      final active = await seed(_song('active'));
      final next = await seed(_song('next'));
      final idle = await seed(_song('idle'));
      controller.setActivePlaybackPath(active.filePath);
      controller.setArmedNextPath(next.filePath);
      expect(controller.isPlayCacheProtected(active), isTrue);
      expect(controller.isPlayCacheProtected(next), isTrue);
      expect(controller.isPlayCacheProtected(idle), isFalse);
      await controller.deletePlayCache(active.song, active.quality);
      await controller.deletePlayCache(next.song, next.quality);
      await controller.clearPlayCache();
      expect(controller.playCacheEntries.map((e) => e.cacheKey).toSet(), {
        active.cacheKey,
        next.cacheKey,
      });
      expect(File(active.filePath).existsSync(), isTrue);
      expect(File(next.filePath).existsSync(), isTrue);
      expect(File(idle.filePath).existsSync(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      final index =
          jsonDecode(prefs.getString('ka_music_play_cache_index')!) as List;
      expect(index.length, 2);
      controller.setActivePlaybackPath(null);
      controller.setArmedNextPath(null);
      await controller.clearPlayCache();
      expect(controller.playCacheEntries, isEmpty);
    },
  );

  test('cache hit does not replace explicit active-path protection', () async {
    final active = await seed(_song('explicit-active'));
    final other = await seed(_song('other'));
    controller.setActivePlaybackPath(active.filePath);
    await controller.cacheForPlayback(other.song, other.quality, 'unused');
    expect(controller.isPlayCacheProtected(active), isTrue);
    expect(controller.isPlayCacheProtected(other), isFalse);
  });

  test('cleanup pins source while copying to persistent storage', () async {
    final song = _song('copy-pin');
    final cache = await seed(song);
    service.copyGate = Completer<void>();
    final saving = controller.download(song, _quality);
    await _turn();
    expect(controller.isPlayCacheProtected(cache), isTrue);
    await controller.clearPlayCache();
    expect(File(cache.filePath).existsSync(), isTrue);
    service.copyGate!.complete();
    await saving;
    expect(controller.isDownloaded(song), isTrue);
    expect(controller.isPlayCacheProtected(cache), isFalse);
  });

  test('controller LRU limit protects active and armed-next paths', () async {
    service.reportedSize = AppConfig.minPlayCacheMaxBytes;
    final active = await seed(_song('lru-active'));
    final next = await seed(_song('lru-next'));
    final idle = await seed(_song('lru-idle'));
    controller.setActivePlaybackPath(active.filePath);
    controller.setArmedNextPath(next.filePath);
    await controller.setPlayCacheMaxBytes(AppConfig.minPlayCacheMaxBytes);
    expect(controller.playCacheEntries.map((e) => e.cacheKey).toSet(), {
      active.cacheKey,
      next.cacheKey,
    });
    expect(File(idle.filePath).existsSync(), isFalse);
    expect(File(active.filePath).existsSync(), isTrue);
    expect(File(next.filePath).existsSync(), isTrue);
  });

  test(
    'cancel before URL resolves prevents enqueue and late failure',
    () async {
      final song = _song('cancel-url');
      api.pending = Completer<PlayUrl>();
      final downloading = controller.download(song, _quality);
      await controller.cancelDownload(song);
      api.pending!.completeError(StateError('late URL failure'));
      await downloading;
      expect(controller.entryFor(song), isNull);
      expect(service.requests, isEmpty);
    },
  );

  test('cancel before URL success never starts IO', () async {
    final song = _song('cancel-url-success');
    api.pending = Completer<PlayUrl>();
    final downloading = controller.download(song, _quality);
    await controller.cancelDownload(song);
    api.pending!.complete(PlayUrl(url: 'unused', hash: song.hash));
    await downloading;
    expect(controller.entryFor(song), isNull);
    expect(service.requests, isEmpty);
  });

  for (final fail in [false, true]) {
    test(
      'cancel ignores late network ${fail ? 'failure' : 'success'} and progress',
      () async {
        final song = _song('late-network');
        service.holdDownloads = true;
        final oldAttempt = controller.download(song, _quality);
        await _turn();
        final oldCall = service.requests.single;
        await controller.cancelDownload(song);
        final retry = controller.download(song, _quality);
        await _turn();
        final newCall = service.requests.last;
        oldCall.onProgress(99, 100);
        expect(controller.entryFor(song)!.progress, 0);
        if (fail) {
          oldCall.done.completeError(StateError('late network failure'));
        } else {
          oldCall.succeed();
        }
        await oldAttempt;
        expect(controller.entryFor(song)!.status, DownloadStatus.downloading);
        newCall.onProgress(50, 100);
        expect(controller.entryFor(song)!.progress, 0.5);
        newCall.succeed();
        await retry;
        expect(controller.isDownloaded(song), isTrue);
        expect(service.cancelled, [service.cacheKeyFor(song, _quality)]);
      },
    );
  }

  test(
    'clear downloads removes only completed snapshot, keeps running and failed',
    () async {
      final completed = _song('completed');
      final pending = _song('pending');
      final failed = _song('failed');
      await controller.download(completed, _quality);
      final completedPath = controller.entryFor(completed)!.filePath!;
      service.failDownloads = true;
      await controller.download(failed, _quality);
      service.failDownloads = false;
      service.holdDownloads = true;
      final downloading = controller.download(pending, _quality);
      await _turn();
      service.deleteGate = Completer<void>();
      final clearing = controller.clearAllDownloads();
      service.requests.last.succeed();
      await downloading;
      service.deleteGate!.complete();
      await clearing;
      expect(controller.entryFor(completed), isNull);
      expect(File(completedPath).existsSync(), isFalse);
      expect(controller.entryFor(failed)!.status, DownloadStatus.failed);
      expect(controller.isDownloaded(pending), isTrue);
      final prefs = await SharedPreferences.getInstance();
      final rows =
          jsonDecode(prefs.getString('ka_music_downloads_index')!) as List;
      expect(rows.single['song']['hash'], pending.hash);
    },
  );

  test('deleteDownload removes failed rows without deleting files', () async {
    final song = _song('remove-failed');
    service.failDownloads = true;
    await controller.download(song, _quality);
    expect(controller.entryFor(song)!.status, DownloadStatus.failed);
    await controller.deleteDownload(song);
    expect(controller.entryFor(song), isNull);
    expect(service.cancelled, isEmpty);
  });

  test('clear downloads leaves an unfinished download controllable', () async {
    final song = _song('still-pending');
    service.holdDownloads = true;
    final downloading = controller.download(song, _quality);
    await _turn();
    await controller.clearAllDownloads();
    expect(controller.entryFor(song)!.status, DownloadStatus.downloading);
    service.requests.single.onProgress(1, 2);
    expect(controller.entryFor(song)!.progress, 0.5);
    await controller.cancelDownload(song);
    service.requests.single.done.completeError(StateError('cancelled'));
    await downloading;
    expect(controller.entryFor(song), isNull);
  });

  test(
    'parallel cache calls share IO and clear waits without resurrection',
    () async {
      final song = _song('cache-pending');
      service.cacheGate = Completer<void>();
      final first = controller.cacheForPlayback(song, _quality, 'one');
      final second = controller.cacheForPlayback(song, _quality, 'two');
      expect(identical(first, second), isTrue);
      await _turn();
      expect(service.cacheCalls, 1);
      var cleared = false;
      final clearing = controller.clearPlayCache().then((_) => cleared = true);
      await _turn();
      expect(cleared, isFalse);
      await controller.cacheForPlayback(
        _song('during-clear'),
        _quality,
        'ignored',
      );
      expect(service.cacheCalls, 1);
      service.cacheGate!.complete();
      await Future.wait([first, second, clearing]);
      expect(controller.playCacheEntries, isEmpty);
      expect((await service.playCacheDir()).listSync(), isEmpty);
      expect(service.cancelledCaches, [service.cacheKeyFor(song, _quality)]);
    },
  );

  test('cancel playback cache ignores its late completion', () async {
    final song = _song('cancel-cache');
    service.cacheGate = Completer<void>();
    final caching = controller.cacheForPlayback(song, _quality, 'unused');
    await _turn();
    await controller.cancelPlaybackCache(song, _quality);
    service.cacheGate!.complete();
    await caching;
    expect(controller.playCacheEntries, isEmpty);
    expect((await service.playCacheDir()).listSync(), isEmpty);
  });

  test('dispose does not initialize or notify an unused controller', () async {
    final unused = DownloadController(service, api);
    var notifications = 0;
    unused.addListener(() => notifications++);
    unused.dispose();
    await _turn();
    expect(notifications, 0);
  });

  test('dispose during initialization suppresses late notifications', () async {
    final initializing = DownloadController(service, api);
    var notifications = 0;
    initializing.addListener(() => notifications++);
    final pending = initializing.initialize();
    initializing.dispose();
    await pending;
    expect(notifications, 0);
  });

  test(
    'cancelled copy and immediate same-key retry serialize publication',
    () async {
      final real = _DirectoryService(root)..directoryGate = Completer<void>();
      final song = _song('retry-copy');
      final source = File('${root.path}/retry-source.mp3')
        ..writeAsBytesSync(_audio);
      final first = real.copyPlaybackCacheToDownload(
        song: song,
        quality: _quality,
        sourcePath: source.path,
      );
      final cancelled = expectLater(first, throwsA(isA<DioException>()));
      await real.cancel(real.cacheKeyFor(song, _quality));
      final retry = real.copyPlaybackCacheToDownload(
        song: song,
        quality: _quality,
        sourcePath: source.path,
      );
      real.directoryGate!.complete();
      await cancelled;
      final path = await retry;
      expect(await File(path).readAsBytes(), _audio);
      expect(await source.readAsBytes(), _audio);
      expect((await real.downloadDir()).listSync().length, 1);
      real.dispose();
    },
  );

  for (final copying in [false, true]) {
    test(
      'service registers cancellation before directory await ($copying)',
      () async {
        final real = _DirectoryService(root)..directoryGate = Completer<void>();
        final song = _song('service-cancel');
        final source = File('${root.path}/source.mp3')
          ..writeAsBytesSync(_audio);
        final operation = copying
            ? real.copyPlaybackCacheToDownload(
                song: song,
                quality: _quality,
                sourcePath: source.path,
              )
            : real.download(
                song: song,
                quality: _quality,
                url: 'https://example.invalid/never-requested',
                onProgress: (_, _) => fail('cancelled IO reported progress'),
              );
        final expectation = expectLater(
          operation,
          throwsA(isA<DioException>()),
        );
        await real.cancel(real.cacheKeyFor(song, _quality));
        real.directoryGate!.complete();
        await expectation;
        expect((await real.downloadDir()).listSync(), isEmpty);
        expect(await source.readAsBytes(), _audio);
        real.dispose();
      },
    );
  }

  test('download file names carry artist, title and quality', () {
    final service = _DirectoryService(root);
    final name = service.downloadFileNameFor(
      const Song(id: 'n', hash: 'abc/def', title: '夜航', artist: '歌手乙'),
      _quality,
    );
    expect(name, '歌手乙 - 夜航 [320K] abc def.mp3');
    expect(name.contains('/'), isFalse);
    service.dispose();
  });

  test('legacy downloads move to the system downloads directory', () async {
    final legacy = await service.legacyDownloadDir();
    final song = _song('legacy-move');
    final oldFile = File('${legacy.path}/old.mp3')..writeAsBytesSync(_audio);
    SharedPreferences.setMockInitialValues({
      'ka_music_downloads_index': jsonEncode([
        {
          'song': song.toCache(),
          'quality': _quality.apiValue,
          'filePath': oldFile.path,
          'downloadedAt': DateTime(2026).toIso8601String(),
          'loudness': _loudness.toJson(),
        },
      ]),
    });
    final restored = DownloadController(service, api);
    addTearDown(restored.dispose);
    await restored.initialize();
    final entry = restored.entryFor(song);
    expect(entry?.status, DownloadStatus.downloaded);
    final expected = await service.downloadDir();
    final expectedPath =
        '${expected.path}/${service.downloadFileNameFor(song, _quality)}';
    expect(entry?.filePath, expectedPath);
    expect(File(expectedPath).existsSync(), isTrue);
    expect(oldFile.existsSync(), isFalse);
    expect(legacy.existsSync(), isFalse);
  });
}
