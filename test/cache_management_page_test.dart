import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/artwork_cache_service.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/ui/pages/cache_management_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache extends CacheService {
  @override
  Future<int> getCacheSize() async => 512 * 1024;
}

class _FakeDownloads extends DownloadController {
  _FakeDownloads() : super(DownloadService(), _UnusedApi());

  final entries = <PlayCacheEntry>[
    PlayCacheEntry(
      cacheKey: 'song_flac',
      song: const Song(id: '1', title: '缓存歌曲', artist: '测试歌手', hash: 'hash'),
      quality: AudioQuality.lossless,
      filePath: '/cache/song.flac',
      size: 1024 * 1024,
      cachedAt: DateTime(2026),
      lastAccessedAt: DateTime(2026),
    ),
  ];
  @override
  Future<void> flush() async {}

  void evictExternally() {
    entries.clear();
    notifyListeners();
  }

  DownloadEntry? result;
  Song? savedSong;
  AudioQuality? savedQuality;
  bool failSave = false;
  bool failClear = false;
  bool protected = false;
  bool failRead = false;
  int clearCalls = 0;
  int deleteCalls = 0;
  int limitCalls = 0;
  Completer<void>? pendingSave;

  @override
  List<PlayCacheEntry> get playCacheEntries => entries.toList();

  @override
  bool isPlayCacheProtected(PlayCacheEntry entry) => protected;

  @override
  DownloadEntry? entryFor(Song song) => result;

  @override
  Future<int> getPlayCacheDirSize() async {
    if (failRead) throw StateError('读取失败');
    return entries.fold<int>(0, (sum, entry) => sum + entry.size);
  }

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
  Future<void> clearPlayCache() async {
    clearCalls++;
    if (failClear) throw StateError('清理失败');
    if (!protected) entries.clear();
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

  @override
  Future<void> setPlayCacheMaxBytes(int bytes) async {
    limitCalls++;
    playCacheMaxBytes = bytes;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _FakeDownloads downloads;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'cache_management_widget',
    );
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

  Future<void> open(
    WidgetTester tester, {
    VoidCallback? onOpenDownloads,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: CacheManagementPage(
          cache: _FakeCache(),
          downloads: downloads,
          onOpenDownloads: onOpenDownloads,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('缓存页显示三类缓存并可从工具栏进入下载', (tester) async {
    var opened = 0;
    await open(tester, onOpenDownloads: () => opened++);
    expect(find.text('缓存管理'), findsOneWidget);
    expect(find.text('播放缓存'), findsOneWidget);
    expect(find.text('1.0 MB'), findsWidgets);
    await reveal(tester, find.text('数据缓存'));
    expect(find.text('封面缓存'), findsOneWidget);
    expect(find.text('数据缓存'), findsOneWidget);
    await tester.tap(find.byTooltip('下载'));
    expect(opened, 1);
  });

  testWidgets('窄屏与大字体下可编辑上限并滚动到歌曲列表', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, textScale: 1.5);
    final input = find.byKey(const ValueKey('播放缓存上限'));
    await reveal(tester, input);
    await tester.enterText(input, '1');
    await tester.tap(find.byTooltip('保存播放缓存上限'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 100–10240 MB'), findsOneWidget);
    expect(downloads.limitCalls, 0);
    await tester.enterText(input, '200');
    await tester.tap(find.byTooltip('保存播放缓存上限'));
    await tester.pumpAndSettle();
    expect(downloads.playCacheMaxBytes, 200 * 1024 * 1024);
    await reveal(tester, find.text('缓存歌曲'));
    expect(find.text('测试歌手 · 无损音质 · 1.0 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存到下载沿用缓存音质并显示下载状态', (tester) async {
    await open(tester);
    await reveal(tester, find.text('保存到下载'));
    await tester.tap(find.text('保存到下载'));
    await tester.pumpAndSettle();
    expect(downloads.savedSong?.hash, 'hash');
    expect(downloads.savedQuality, AudioQuality.lossless);
    expect(find.text('已保存到下载'), findsOneWidget);
    expect(find.text('已下载'), findsOneWidget);
  });

  testWidgets('保存失败会显示错误并允许重试', (tester) async {
    downloads.failSave = true;
    await open(tester);
    await reveal(tester, find.text('保存到下载'));
    await tester.tap(find.text('保存到下载'));
    await tester.pumpAndSettle();
    expect(find.textContaining('磁盘空间不足'), findsOneWidget);
    expect(find.text('已保存到下载'), findsNothing);
    expect(find.text('重试下载'), findsOneWidget);
  });

  testWidgets('保存进行中会禁用删除、清理与刷新', (tester) async {
    downloads.pendingSave = Completer<void>();
    await open(tester);
    await reveal(tester, find.text('保存到下载'));
    await tester.tap(find.text('保存到下载'));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '刷新',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('save-download-entry')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('delete-cache-entry')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('save-download-entry')))
          .onPressed,
      isNull,
    );
    downloads.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(downloads.clearCalls, 0);
    expect(downloads.deleteCalls, 0);
  });

  testWidgets('清理播放缓存需要确认并暴露失败信息', (tester) async {
    await open(tester);
    final clear = find.byKey(const ValueKey('clear-播放缓存'));
    await reveal(tester, clear);
    await tester.tap(clear);
    await tester.pump(const Duration(milliseconds: 300));
    expect(downloads.clearCalls, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(downloads.clearCalls, 0);
    downloads.failClear = true;
    await tester.tap(clear);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(downloads.clearCalls, 1);
    expect(find.textContaining('操作失败'), findsOneWidget);
    expect(tester.widget<TextButton>(clear).onPressed, isNotNull);
  });

  testWidgets('正在播放的缓存不能删除但可以保存', (tester) async {
    downloads.protected = true;
    await open(tester);
    await reveal(tester, find.text('删除'));
    expect(find.text('正在播放，无法清理'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, '删除')).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存到下载'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('删除单首缓存需要确认并更新列表', (tester) async {
    await open(tester);
    await reveal(tester, find.text('删除'));
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(downloads.deleteCalls, 0);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(downloads.deleteCalls, 1);
    expect(downloads.entries, isEmpty);
    expect(find.text('已删除'), findsOneWidget);
  });

  testWidgets('后台淘汰缓存后用量立即刷新', (tester) async {
    await open(tester);
    expect(find.text('1.0 MB'), findsOneWidget);
    downloads.evictExternally();
    await tester.pumpAndSettle();
    await reveal(tester, find.text('暂无缓存歌曲'));
    expect(find.text('暂无缓存歌曲'), findsOneWidget);
  });

  testWidgets('下载入口关闭缓存页且不叠加路由', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('下载')),
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (cacheContext) => CacheManagementPage(
                    downloads: downloads,
                    onOpenDownloads: () => Navigator.pop(cacheContext),
                  ),
                ),
              ),
              child: const Text('打开缓存'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开缓存'));
    await tester.pumpAndSettle();
    expect(find.byType(CacheManagementPage), findsOneWidget);
    await tester.tap(find.byTooltip('下载'));
    await tester.pumpAndSettle();
    expect(find.byType(CacheManagementPage), findsNothing);
    expect(find.text('下载'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('读取用量失败时显示错误并可通过刷新恢复', (tester) async {
    downloads.failRead = true;
    await open(tester);
    expect(find.text('播放缓存读取失败，请重试'), findsOneWidget);
    downloads.failRead = false;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('播放缓存读取失败，请重试'), findsNothing);
    expect(find.text('1.0 MB'), findsOneWidget);
  });
}
