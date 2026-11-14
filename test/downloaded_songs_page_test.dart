import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/ui/pages/downloaded_songs_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const first = Song(id: 'one', hash: 'one', title: '晨光', artist: '歌手甲');
const second = Song(id: 'two', hash: 'two', title: '夜航', artist: '歌手乙');
const failedSong = Song(
  id: 'failed',
  hash: 'failed',
  title: '待重试歌曲',
  artist: '歌手丙',
);
const runningSong = Song(
  id: 'running',
  hash: 'running',
  title: '正在下载歌曲',
  artist: '歌手丁',
);

DownloadEntry entry(Song song, DownloadStatus status) => DownloadEntry(
  song: song,
  quality: AudioQuality.high,
  status: status,
  progress: status == DownloadStatus.downloading ? .42 : 1,
  error: status == DownloadStatus.failed ? '网络暂不可用' : null,
);

class _Downloads extends DownloadController {
  _Downloads(MusicApi api, this.entries) : super(DownloadService(), api);
  final List<DownloadEntry> entries;
  int retryCount = 0;
  int cancelCount = 0;
  @override
  Future<void> flush() async {}
  @override
  List<DownloadEntry> get downloadEntries => List.of(entries);
  @override
  DownloadEntry? entryFor(Song song) =>
      entries.where((e) => e.song.hash == song.hash).firstOrNull;
  @override
  Future<void> download(Song song, AudioQuality quality) async {
    retryCount++;
    entries.removeWhere((e) => e.song.hash == song.hash);
    entries.add(entry(song, DownloadStatus.downloaded));
    notifyListeners();
  }

  @override
  Future<void> cancelDownload(Song song) async {
    cancelCount++;
    entries.removeWhere((e) => e.song.hash == song.hash);
    notifyListeners();
  }

  @override
  Future<void> deleteDownload(Song song) async {
    entries.removeWhere((e) => e.song.hash == song.hash);
    notifyListeners();
  }

  @override
  Future<void> clearAllDownloads() async {
    entries.removeWhere((e) => e.status == DownloadStatus.downloaded);
    notifyListeners();
  }
}

class _Player extends ChangeNotifier implements PlayerController {
  Song? played;
  @override
  Song? get currentSong => played;
  @override
  CacheService? get cacheService => null;
  @override
  Future<void> playDownloadedSong(Song song) async {
    played = song;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(_Downloads, _Player)> pumpPage(
  WidgetTester tester,
  List<DownloadEntry> entries, {
  Size size = const Size(390, 844),
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = MusicApi(ApiClient());
  final downloads = _Downloads(api, entries);
  final player = _Player();
  final auth = _Auth();
  addTearDown(downloads.dispose);
  addTearDown(player.dispose);
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
      ),
      home: DownloadedSongsPage(
        api: api,
        auth: auth,
        player: player,
        downloads: downloads,
      ),
    ),
  );
  await tester.pump();
  return (downloads, player);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(1024, 768),
  ]) {
    testWidgets('下载页空状态适配 $size', (tester) async {
      await pumpPage(tester, [], size: size, dark: size.width == 1024);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('还没有下载的歌曲'), findsOneWidget);
      expect(find.byTooltip('缓存管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('搜索按歌名与歌手筛选，点击使用下载音质播放', (tester) async {
    final (_, player) = await pumpPage(tester, [
      entry(first, DownloadStatus.downloaded),
      entry(second, DownloadStatus.downloaded),
    ]);
    await tester.enterText(find.byType(TextField), '歌手乙');
    await tester.pump();
    expect(find.text('晨光'), findsNothing);
    expect(find.text('夜航'), findsOneWidget);
    await tester.tap(find.text('夜航'));
    await tester.pump();
    expect(player.played, second);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump();
    expect(find.text('没有找到匹配的歌曲'), findsOneWidget);
  });

  testWidgets('失败任务显示原因并可重试，进行中的任务可取消', (tester) async {
    final (downloads, _) = await pumpPage(tester, [
      entry(failedSong, DownloadStatus.failed),
      entry(runningSong, DownloadStatus.downloading),
    ]);
    expect(find.text('网络暂不可用'), findsOneWidget);
    await tester.tap(find.byTooltip('重试下载'));
    await tester.pump();
    expect(downloads.retryCount, 1);
    await tester.tap(find.byTooltip('取消下载'));
    await tester.pump();
    expect(downloads.cancelCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除下载需要确认，取消时保留条目', (tester) async {
    final (downloads, _) = await pumpPage(tester, [
      entry(first, DownloadStatus.downloaded),
    ]);
    await tester.tap(find.byTooltip('删除下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(downloads.entries, hasLength(1));
    await tester.tap(find.byTooltip('删除下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(downloads.entries, isEmpty);
    expect(find.text('已删除'), findsOneWidget);
  });

  testWidgets('清空下载只删除已下载条目并需要确认', (tester) async {
    final (downloads, _) = await pumpPage(tester, [
      entry(first, DownloadStatus.downloaded),
      entry(failedSong, DownloadStatus.failed),
    ]);
    await tester.tap(find.byTooltip('删除全部下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(downloads.entries, hasLength(2));
    await tester.tap(find.byTooltip('删除全部下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(downloads.entries, hasLength(1));
    expect(downloads.entries.single.song, failedSong);
  });
}
