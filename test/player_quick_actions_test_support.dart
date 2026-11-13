import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/player_page_layout_controller.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/pages/player_page.dart';
import 'package:kgka_music_hl/ui/widgets/player_page_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size kTabletLandscape = Size(1024, 768);
const Size kPhoneLandscape = Size(800, 400);
const Size kPhonePortrait = Size(400, 800);

class FakePlayer extends ChangeNotifier implements PlayerController {
  FakePlayer({
    this.song = const Song(
      id: 'test',
      hash: 'test',
      title: 'Test song',
      artist: 'Test artist',
      source: SongSource.kugou,
    ),
  });

  @override
  Song get currentSong => song;
  final Song song;
  @override
  List<Song> get queue => [currentSong];
  @override
  bool isPlaying = true;
  @override
  bool get isPreparing => false;
  @override
  bool get isScrubbing => false;
  @override
  bool get isLoadingLyrics => false;
  @override
  List<LyricLine> get lyrics => const [];
  @override
  Duration get smoothPosition => Duration.zero;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  final positionListenable = ValueNotifier(Duration.zero);
  @override
  PlaybackMode get playbackMode => PlaybackMode.playlistLoop;
  @override
  String get playbackModeLabel => '列表循环';
  @override
  String get audioEffectsLabel => '关闭';
  @override
  int get activeLyricIndex => -1;
  @override
  int get seekRevision => 0;
  @override
  LyricDisplayMode get lyricDisplayMode =>
      LyricDisplayMode.lyricsWithTranslation;
  @override
  AudioQuality get audioQuality => AudioQuality.standard;
  @override
  String get playbackSpeedLabel => '1.0x';
  String get audioQualityLabel => '标准';
  @override
  bool get isDesktopLyricsSupported => false;
  @override
  bool get desktopLyricsEnabled => false;
  @override
  final ValueNotifier<SleepTimerUiState> sleepTimerUiListenable = ValueNotifier(
    const SleepTimerUiState(),
  );

  @override
  void dispose() {
    positionListenable.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuth extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> prepareQuickActionTests(Map<String, Object> initialValues) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(initialValues);
  await PlayerPageLayoutController.instance.load();
}

Future<void> pumpQuickActionPlayer(
  WidgetTester tester, {
  Size size = kTabletLandscape,
  Song? song,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final player = FakePlayer(
    song:
        song ??
        const Song(
          id: 'test',
          hash: 'test',
          title: 'Test song',
          artist: 'Test artist',
          source: SongSource.kugou,
        ),
  );
  final auth = FakeAuth();
  final theme = ThemeController();
  addTearDown(player.dispose);
  addTearDown(auth.dispose);
  addTearDown(theme.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(player: player, auth: auth),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> pumpQuickActionFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> openMoreSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await pumpQuickActionFrames(tester);
}

Future<void> openQuickActionEditor(WidgetTester tester) async {
  await openMoreSheet(tester);
  final entry = find.text('编辑播放页');
  await tester.tap(entry);
  await tester.pump(const Duration(milliseconds: 150));
  await pumpQuickActionFrames(tester);
}

Future<void> tapQuickActionCandidate(
  WidgetTester tester,
  PlayerActionId id,
) async {
  final finder = find.byKey(Key('quick-action-candidate-${id.name}'));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await pumpQuickActionFrames(tester);
}

Map<String, Object> quickActionPrefs(List<PlayerActionId> ids) =>
    <String, Object>{
      PlayerPageLayoutController.prefsKey: ids.map((id) => id.name).toList(),
    };
