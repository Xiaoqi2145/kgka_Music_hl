import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/controllers/local_music_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/ui/pages/library_page.dart';

class _Auth extends AuthController {
  _Auth(super.api, super.cache);

  @override
  List<PlaylistSummary> get createdPlaylists => const [
    PlaylistSummary(id: 'created-1', title: '创建歌单', listId: 'created-1'),
  ];

  @override
  List<PlaylistSummary> get collectedPlaylists => const [
    PlaylistSummary(id: 'collected-1', title: '收藏歌单', listId: 'collected-1'),
  ];

  @override
  List<PlaylistSummary> get collectedAlbums => const [
    PlaylistSummary(
      id: 'album-1',
      title: '收藏专辑',
      musiclibId: 'album-1',
      sourceGlobalId: null,
    ),
  ];
}

class _Player extends ChangeNotifier implements PlayerController {
  @override
  CacheService? cacheService;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends DownloadController {
  _Downloads(MusicApi api) : super(DownloadService(), api);

  @override
  List<Song> get downloadedSongs => const [];
}

class _LocalMusic extends LocalMusicController {
  @override
  List<Song> get songs => const [];
}

void main() {
  for (final testCase in const [
    (name: '手机列表', size: Size(390, 844)),
    (name: '平板网格', size: Size(1024, 768)),
  ]) {
    testWidgets('${testCase.name}切页从点击当帧开始淡入且动画层保持稳定', (tester) async {
      tester.view.physicalSize = testCase.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = MusicApi(ApiClient());
      final cache = CacheService();
      final auth = _Auth(api, cache);
      final player = _Player();
      final downloads = _Downloads(api);
      final theme = ThemeController();
      final localMusic = _LocalMusic();
      addTearDown(auth.dispose);
      addTearDown(player.dispose);
      addTearDown(downloads.dispose);
      addTearDown(localMusic.dispose);
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(
              api: api,
              auth: auth,
              player: player,
              cache: cache,
              downloads: downloads,
              theme: theme,
              localMusic: localMusic,
            ),
          ),
        ),
      );
      await tester.pump();
      final fadeFinder = find.byType(SliverFadeTransition);
      final fadeElement = tester.element(fadeFinder);

      await tester.tap(find.textContaining('收藏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(find.text('收藏歌单'), findsOneWidget);
      expect(find.text('创建歌单'), findsNothing);
      expect(fadeFinder, findsOneWidget);
      expect(
        tester.widget<SliverFadeTransition>(fadeFinder).opacity.value,
        lessThan(1),
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.element(fadeFinder), same(fadeElement));
      expect(
        tester.widget<SliverFadeTransition>(fadeFinder).opacity.value,
        closeTo(1, 0.001),
      );
    });
  }
}
