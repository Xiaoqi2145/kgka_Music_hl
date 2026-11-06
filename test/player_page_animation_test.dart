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
  int get activeLyricIndex => -1;
  @override
  int get seekRevision => 0;
  @override
  LyricDisplayMode get lyricDisplayMode =>
      LyricDisplayMode.lyricsWithTranslation;

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
  testWidgets('queue popup keeps visible player animations enabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = _Player();
    final auth = _Auth();
    final theme = ThemeController();
    addTearDown(player.dispose);
    addTearDown(auth.dispose);
    addTearDown(theme.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: PlayerPage(player: player, auth: auth),
      ),
    );
    await tester.pump();

    // The portrait player always owns a background rotation controller,
    // including when artwork is absent. Inspect its actual ticker mode.
    final background = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_ArtworkBackground',
      skipOffstage: false,
    );
    expect(TickerMode.valuesOf(tester.element(background)).enabled, isTrue);
    await tester.tap(find.byTooltip('播放列表'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(TickerMode.valuesOf(tester.element(background)).enabled, isTrue);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(TickerMode.valuesOf(tester.element(background)).enabled, isTrue);

    // Fully covered routes still suspend their animations.
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Another page')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(TickerMode.valuesOf(tester.element(background)).enabled, isFalse);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(TickerMode.valuesOf(tester.element(background)).enabled, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(TickerMode.valuesOf(tester.element(background)).enabled, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(TickerMode.valuesOf(tester.element(background)).enabled, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
