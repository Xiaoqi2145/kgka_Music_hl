import 'dart:convert';
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
import 'package:kgka_music_hl/ui/pages/cached_songs_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/screenshot_harness.dart';

/// 预览截图（README 引用的 screenshots/）。
///
/// 只负责把当前 UI 渲染成 PNG，不做功能校验：
///
/// ```
/// flutter test test/screenshots_test.dart --update-goldens
/// ```
///
/// 改版后重跑一次，预览图即与代码同步，不会再出现「截图早已过期」的情况。

class _UnusedApi implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCache extends CacheService {
  @override
  Future<int> getCacheSize() async => 268435456;
}

class _ScreenshotDownloads extends DownloadController {
  _ScreenshotDownloads() : super(DownloadService(), _UnusedApi());

  @override
  Future<void> flush() async {}

  @override
  List<PlayCacheEntry> get playCacheEntries => _entries;

  @override
  bool isPlayCacheProtected(PlayCacheEntry entry) =>
      entry.cacheKey == _entries.first.cacheKey;

  @override
  DownloadEntry? entryFor(Song song) => song.hash == 'hash1'
      ? DownloadEntry(
          song: song,
          quality: AudioQuality.high,
          status: DownloadStatus.downloaded,
        )
      : null;

  @override
  Future<int> getPlayCacheDirSize() async =>
      _entries.fold<int>(0, (sum, entry) => sum + entry.size);
}

const _coverUrls = <String>[
  'https://example.com/cover0.jpg',
  'https://example.com/cover1.jpg',
  'https://example.com/cover2.jpg',
  'https://example.com/cover3.jpg',
  'https://example.com/cover4.jpg',
  'https://example.com/cover5.jpg',
];

const _titles = <String>[
  'カノン (卡农)',
  '雨伞',
  '借过一下 (Live)',
  'Bloom of Youth',
  'Game Start',
  '飞行雪绒的练习时间',
];

const _artists = <String>[
  'DJ OKAWARI',
  '徐怀钰',
  '陈小春',
  'Key Sounds Label',
  '鸣潮先约电台',
  '飞行雪绒',
];

final _entries = <PlayCacheEntry>[
  for (var i = 0; i < _titles.length; i++)
    PlayCacheEntry(
      cacheKey: 'hash${i + 1}_flac',
      song: Song(
        id: '${i + 1}',
        title: _titles[i],
        artist: _artists[i],
        hash: 'hash${i + 1}',
        coverUrl: _coverUrls[i],
      ),
      quality: i.isEven ? AudioQuality.lossless : AudioQuality.high,
      filePath: '/cache/${i + 1}.flac',
      size: (18 + i * 7) * 1024 * 1024,
      cachedAt: DateTime(2026, 11, 20, 10, 30),
      lastAccessedAt: DateTime(2026, 11, 22, 21, 40 - i * 6),
    ),
];

void main() {
  late Directory supportDirectory;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await ScreenshotHarness.loadFonts();

    supportDirectory = await Directory.systemTemp.createTemp('ka_screenshot');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => supportDirectory.path,
        );
    SharedPreferences.setMockInitialValues({});
    await ArtworkCacheService.instance.initialize();

    // 预置封面进缓存目录，让 Artwork 走真实的缓存命中路径。
    final cacheDirectory = Directory('${supportDirectory.path}/ka_music_artwork')
      ..createSync(recursive: true);
    final source = Directory('test/fixtures/covers');
    for (var i = 0; i < _coverUrls.length; i++) {
      final file = File('${source.path}/k$i.png');
      if (!file.existsSync()) continue;
      final key = base64Url.encode(utf8.encode(_coverUrls[i])).replaceAll('=', '');
      file.copySync('${cacheDirectory.path}/$key.idx'.replaceAll('.idx', '.img'));
    }
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await supportDirectory.delete(recursive: true);
  });

  Widget managementPage() => CacheManagementPage(
    cache: _FakeCache(),
    downloads: _ScreenshotDownloads(),
  );

  testWidgets('缓存管理 · 浅色', (tester) async {
    await ScreenshotHarness.capture(
      tester,
      path: 'cache-management-light.png',
      child: managementPage(),
    );
  });

  testWidgets('缓存管理 · 深色', (tester) async {
    await ScreenshotHarness.capture(
      tester,
      path: 'cache-management-dark.png',
      dark: true,
      child: managementPage(),
    );
  });

  testWidgets('缓存歌曲 · 列表', (tester) async {
    await ScreenshotHarness.capture(
      tester,
      path: 'cached-songs-light.png',
      pushedRoute: true,
      child: CachedSongsPage(downloads: _ScreenshotDownloads()),
    );
  });

  testWidgets('缓存歌曲 · 深色', (tester) async {
    await ScreenshotHarness.capture(
      tester,
      path: 'cached-songs-dark.png',
      dark: true,
      pushedRoute: true,
      child: CachedSongsPage(downloads: _ScreenshotDownloads()),
    );
  });
}
