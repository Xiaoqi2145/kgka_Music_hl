import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/artwork_cache_service.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/ui/pages/cached_songs_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDownloads extends DownloadController {
  _FakeDownloads() : super(DownloadService(), _UnusedApi());

  final entries = <PlayCacheEntry>[
    PlayCacheEntry(
      cacheKey: 'song_flac',
      song: const Song(
        id: '1',
        title: '缓存歌曲',
        artist: '测试歌手',
        hash: 'hash',
      ),
      quality: AudioQuality.lossless,
      filePath: '/cache/song.flac',
      size: 1024 * 1024,
      cachedAt: DateTime(2026),
      lastAccessedAt: DateTime(2026),
    ),
  ];
  @override
  Future<void> flush() async {}

  DownloadEntry? result;
  Song? savedSong;
  AudioQuality? savedQuality;
  bool failSave = false;
  bool protected = false;
  int deleteCalls = 0;
  Completer<void>? pendingSave;

  @override
  List<PlayCacheEntry> get playCacheEntries => entries.toList();

  @override
  bool isPlayCacheProtected(PlayCacheEntry entry) => protected;

  @override
  DownloadEntry? entryFor(Song song) => result;

  @override
  Future<void> download(Song song, AudioQuality quality) async {
    savedSong = song;
    savedQuality = quality;
    result = DownloadEntry(
      song: song,
      quality: quality,
      status: DownloadStatus.downloading,
    );
    notifyListeners();
    await pendingSave?.future;
    result = DownloadEntry(
      song: song,
      quality: quality,
      status: failSave ? DownloadStatus.failed : DownloadStatus.downloaded,
      error: failSave ? '磁盘空间不足' : null,
    );
    notifyListeners();
  }

  @override
  Future<void> deletePlayCache(Song song, AudioQuality quality) async {
    deleteCalls++;
    entries.removeWhere(
      (entry) => entry.song.hash == song.hash && entry.quality == quality,
    );
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _FakeDownloads downloads;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('cached_songs_widget');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    SharedPreferences.setMockInitialValues({});
    await ArtworkCacheService.instance.initialize();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  setUp(() => downloads = _FakeDownloads());
  tearDown(() => downloads.dispose());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        home: CachedSongsPage(downloads: downloads),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEntryMenu(WidgetTester tester) async {
    final menu = find.byKey(const ValueKey('cache-entry-menu'));
    for (var i = 0; i < 12 && menu.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -220));
      await tester.pumpAndSettle();
    }
    await tester.tap(menu.first);
    await tester.pumpAndSettle();
  }

  testWidgets('列出缓存歌曲并汇总数量与体积', (tester) async {
    await open(tester);
    // 标题栏与页面正文各一处。
    expect(find.text('缓存歌曲'), findsWidgets);
    expect(find.text('1 首 · 共 1.0 MB'), findsOneWidget);
    expect(find.text('测试歌手 · 无损音质 · 1.0 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('cache-entry-menu')), findsOneWidget);
  });

  testWidgets('保存到下载沿用缓存音质并显示下载状态', (tester) async {
    await open(tester);
    await openEntryMenu(tester);
    await tester.tap(find.text('保存到下载'));
    await tester.pumpAndSettle();
    expect(downloads.savedSong?.hash, 'hash');
    expect(downloads.savedQuality, AudioQuality.lossless);
    expect(find.text('已保存到下载'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await openEntryMenu(tester);
    expect(find.text('已下载'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuItem<Object?>>(
            find.byKey(const ValueKey('save-download-entry')),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets('保存失败会显示错误并允许重试', (tester) async {
    downloads.failSave = true;
    await open(tester);
    await openEntryMenu(tester);
    await tester.tap(find.text('保存到下载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('磁盘空间不足'), findsOneWidget);
    expect(find.text('已保存到下载'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await openEntryMenu(tester);
    expect(find.text('重试下载'), findsOneWidget);
  });

  testWidgets('保存进行中会禁用该行的更多操作', (tester) async {
    downloads.pendingSave = Completer<void>();
    await open(tester);
    await openEntryMenu(tester);
    await tester.tap(find.text('保存到下载'));
    await tester.pump();
    expect(
      tester
          .widget<PopupMenuButton<Object?>>(
            find.byKey(const ValueKey('cache-entry-menu')),
          )
          .enabled,
      isFalse,
    );
    downloads.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(downloads.deleteCalls, 0);
  });

  testWidgets('正在播放的缓存不能删除但可以保存', (tester) async {
    downloads.protected = true;
    await open(tester);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    await openEntryMenu(tester);
    expect(find.text('正在播放，无法清理'), findsOneWidget);
    expect(
      tester
          .widget<PopupMenuItem<Object?>>(
            find.byKey(const ValueKey('delete-cache-entry')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<PopupMenuItem<Object?>>(
            find.byKey(const ValueKey('save-download-entry')),
          )
          .enabled,
      isTrue,
    );
  });

  testWidgets('删除单首缓存需要确认并更新列表', (tester) async {
    await open(tester);
    await openEntryMenu(tester);
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(downloads.deleteCalls, 0);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(downloads.deleteCalls, 1);
    expect(downloads.entries, isEmpty);
    expect(find.text('已删除'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('暂无缓存歌曲'), findsOneWidget);
  });

  testWidgets('空列表给出说明', (tester) async {
    downloads.entries.clear();
    await open(tester);
    expect(find.text('暂无缓存歌曲'), findsOneWidget);
    expect(find.text('播放过的歌曲会自动缓存到这里。'), findsOneWidget);
  });
}
