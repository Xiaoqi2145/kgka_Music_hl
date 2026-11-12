import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/pages/player_page.dart';

class _Player extends ChangeNotifier implements PlayerController {
  @override
  final Song currentSong = const Song(
    id: 'test',
    hash: 'test',
    title: 'Test song',
    artist: 'Test artist',
  );
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
  void dispose() {
    positionListenable.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth extends ChangeNotifier implements AuthController {
  @override
  bool isLiked(Song song) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> pumpPlayer(WidgetTester tester, {required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = _Player();
    final auth = _Auth();
    final theme = ThemeController();
    addTearDown(player.dispose);
    addTearDown(auth.dispose);
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(player: player, auth: auth),
      ),
    );
    await tester.pump();
  }

  testWidgets('tablet landscape shows the three quick actions', (tester) async {
    await pumpPlayer(tester, size: const Size(1024, 768));

    expect(find.byTooltip('更换歌词'), findsOneWidget);
    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('音效 · 关闭'), findsOneWidget);
    expect(find.text('更换歌词'), findsNothing);
  });

  testWidgets('phone landscape keeps quick actions in the more sheet', (
    tester,
  ) async {
    await pumpPlayer(tester, size: const Size(800, 400));

    expect(find.byTooltip('更换歌词'), findsNothing);
    expect(find.byTooltip('音质 · 128K'), findsNothing);
    expect(find.byTooltip('音效 · 关闭'), findsNothing);
  });
}
