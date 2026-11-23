import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/models/personal_fm_models.dart';
import 'package:kgka_music_hl/services/personal_fm_session.dart';
import 'package:kgka_music_hl/ui/widgets/artwork.dart';
import 'package:kgka_music_hl/ui/widgets/cached_artwork_image.dart';
import 'package:kgka_music_hl/ui/widgets/personal_fm_section.dart';

import 'player_quick_actions_test_support.dart';

class _RadioPlayer extends FakePlayer {
  _RadioPlayer({
    this.tracked = true,
    this.preparing = false,
    bool withCovers = false,
  }) : songs = List.generate(
         7,
         (index) => Song(
           id: '$index',
           title: '电台曲目 $index',
           artist: '电台艺人',
           hash: 'hash-$index',
           coverUrl: withCovers
               ? 'https://example.test/cover-$index.png'
               : null,
         ),
       );

  bool tracked;
  bool preparing;
  final List<Song> songs;
  var index = 0;
  var disliked = false;
  var stopped = false;
  var prepared = false;
  var playCalls = 0;
  Song? played;
  String? error;

  @override
  bool get isPreparing => preparing;

  @override
  bool isPreparingSong(Song song) => preparing;

  @override
  PersonalFmTrack? get personalFmCurrentTrack =>
      tracked ? PersonalFmTrack(song: songs[index]) : null;

  @override
  PersonalFmSession? get personalFmSession => null;

  @override
  bool get personalFmCurrentDisliked => disliked;

  @override
  String? get errorMessage => error;

  @override
  Iterable<Song> get upcomingPersonalFmSongs => songs.skip(index + 1);

  @override
  Iterable<PersonalFmUpcomingItem> get upcomingPersonalFmEntries sync* {
    final rest = songs.skip(index + 1).toList();
    for (var i = 0; i < rest.length; i++) {
      // 第 1 项模拟回听暂存，第 2 项模拟手动插播，其余是普通候选。
      yield PersonalFmUpcomingItem(
        song: rest[i],
        isFromHistory: i == 0,
        isManual: i == 1,
      );
    }
  }

  @override
  Future<PersonalFmStartOutcome> preparePersonalFm({
    required String ownerKey,
    bool retry = false,
  }) async {
    prepared = true;
    return PersonalFmStartOutcome.empty;
  }

  @override
  Future<void> playPersonalFmSong(Song song) async {
    playCalls++;
    played = song;
    index = songs.indexOf(song);
    notifyListeners();
  }

  @override
  Future<void> next() async {
    index++;
    notifyListeners();
  }

  @override
  Future<void> dislikePersonalFmCurrent() async {
    disliked = true;
    index++;
    notifyListeners();
  }

  @override
  Future<void> stopPersonalFm() async {
    stopped = true;
  }

  @override
  Future<void> togglePlay() async {
    isPlaying = !isPlaying;
    notifyListeners();
  }
}

Future<void> _pump(
  WidgetTester tester,
  _RadioPlayer player, {
  Size size = const Size(400, 800),
  ThemeMode themeMode = ThemeMode.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      themeMode: themeMode,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: PersonalFmSection(
            auth: FakeAuth(),
            player: player,
            visible: true,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('电台页进入时准备候选，但不会自动开播', (tester) async {
    final player = _RadioPlayer(tracked: false);
    addTearDown(player.dispose);

    await _pump(tester, player);
    await tester.pump();

    expect(player.prepared, isTrue);
    expect(player.playCalls, 0);
  });

  testWidgets('未开播页面的布局与播放中一致：入口卡片在上，接下来在下', (tester) async {
    final idle = _RadioPlayer(tracked: false);
    final playing = _RadioPlayer();
    addTearDown(idle.dispose);
    addTearDown(playing.dispose);

    await _pump(tester, idle);
    final idleCard = tester.getTopLeft(find.byType(FilledButton)).dy;
    final idleList = tester.getTopLeft(find.text('接下来')).dy;
    expect(idleCard, lessThan(idleList));

    await _pump(tester, playing);
    final playingCard = tester.getTopLeft(find.byTooltip('下一首')).dy;
    final playingList = tester.getTopLeft(find.text('接下来')).dy;
    expect(playingCard, lessThan(playingList));
  });

  testWidgets('待播列表随切歌更新', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);

    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('电台曲目 1'), findsOneWidget);
    expect(find.text('电台曲目 6'), findsNothing);

    await tester.tap(find.byTooltip('下一首'));
    await tester.pump();

    expect(find.text('电台曲目 6'), findsOneWidget);
  });

  testWidgets('点选候选立即播放那一首', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);
    await tester.tap(find.text('电台曲目 2'));
    await tester.pump();

    expect(player.playCalls, 1);
    expect(player.played!.title, '电台曲目 2');
  });

  testWidgets('播放加载中禁用重复点选', (tester) async {
    final player = _RadioPlayer(preparing: true);
    addTearDown(player.dispose);

    await _pump(tester, player);
    await tester.tap(find.text('电台曲目 2'), warnIfMissed: false);
    await tester.pump();

    expect(player.playCalls, 0);
  });

  testWidgets('点击当前曲目不会重复加载', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);
    // 当前曲目卡片上的标题不是点播入口。
    await tester.tap(find.text('电台曲目 0'));
    await tester.pump();

    expect(player.playCalls, 0);
  });

  testWidgets('播放按钮随播放状态切换图标', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);

    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(find.byTooltip('播放'), findsOneWidget);
  });

  testWidgets('不喜欢后按钮禁用并切到下一首', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);

    await tester.tap(find.byTooltip('不喜欢'));
    await tester.pump();

    expect(player.disliked, isTrue);
    expect(find.text('电台曲目 1'), findsOneWidget);
  });

  testWidgets('待播列表区分回听与插播来源', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);

    expect(find.text('回听'), findsOneWidget);
    expect(find.text('插播'), findsOneWidget);
  });

  testWidgets('待播列表每一项都有封面', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);

    // 5 行待播 + 1 张当前曲目封面。
    expect(find.byType(Artwork), findsNWidgets(6));
  });

  testWidgets('候选耗尽时给出重新获取入口', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);
    player.index = 6;

    await _pump(tester, player);

    expect(find.text('暂时没有接下来的推荐'), findsOneWidget);
    expect(find.text('重新获取'), findsOneWidget);
  });

  testWidgets('横屏仍可直接点选待播条目', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(1000, 600));
    expect(find.text('电台曲目 1'), findsOneWidget);
    expect(find.text('电台曲目 4'), findsNothing);
    await tester.tap(find.text('电台曲目 2'));
    await tester.pump();

    expect(player.played!.title, '电台曲目 2');
    expect(player.playCalls, 1);
  });

  testWidgets('横屏播放中首张方形封面高亮当前曲目', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(1000, 600));

    expect(
      find.byKey(const ValueKey('personal-fm-record-current')),
      findsOneWidget,
    );
    expect(find.text('正在播放'), findsOneWidget);
    expect(find.text('电台曲目 1'), findsOneWidget);
    expect(find.text('电台曲目 4'), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

    await tester.tap(find.byKey(const ValueKey('personal-fm-record-current')));
    await tester.pump();
    expect(player.playCalls, 0);
  });

  testWidgets('横屏未开播时在封面带内点选推荐', (tester) async {
    final player = _RadioPlayer(tracked: false);
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(1000, 600));

    expect(find.text('开始播放'), findsOneWidget);
    expect(find.text('为你推荐'), findsOneWidget);
    expect(find.text('接下来'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('personal-fm-wide-stage')),
        matching: find.byTooltip('播放'),
      ),
      findsNothing,
    );
    expect(tester.getSize(find.text('为你推荐')).width, isPositive);

    await tester.tap(find.text('电台曲目 1'));
    await tester.pump();

    expect(player.played!.title, '电台曲目 1');
  });

  testWidgets('横屏控制卡随暂停切换状态文案', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(1000, 600));
    expect(find.text('正在播放'), findsOneWidget);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();

    expect(find.text('已暂停'), findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget);
  });

  testWidgets('横屏控制卡顶边对齐且在开播和暂停时尺寸不变', (tester) async {
    final player = _RadioPlayer(tracked: false)..isPlaying = false;
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(1000, 600));

    final stage = find.byKey(const ValueKey('personal-fm-wide-stage'));
    final control = find.byKey(
      const ValueKey('personal-fm-wide-control-panel'),
    );
    final details = find.byKey(
      const ValueKey('personal-fm-wide-track-details'),
    );
    final idleRect = tester.getRect(control);
    expect(idleRect.top, tester.getTopLeft(find.text('为你推荐')).dy);
    expect(idleRect.top, tester.getTopLeft(stage).dy);
    expect(idleRect.bottom, closeTo(tester.getBottomLeft(stage).dy, 4));
    expect(details, findsNothing);
    expect(
      find.byKey(const ValueKey('personal-fm-wide-control-artwork')),
      findsNothing,
    );

    player.tracked = true;
    player.isPlaying = true;
    player.notifyListeners();
    await tester.pump();
    expect(find.text('正在播放'), findsOneWidget);
    expect(details, findsOneWidget);
    expect(tester.getRect(control), idleRect);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(find.text('已暂停'), findsOneWidget);
    expect(tester.getRect(control), idleRect);
  });

  testWidgets('横屏当前曲目详情独立显示在播放控制下方', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(1000, 600));

    final stage = find.byKey(const ValueKey('personal-fm-wide-stage'));
    final details = find.byKey(
      const ValueKey('personal-fm-wide-track-details'),
    );
    final cover = find.byKey(const ValueKey('personal-fm-wide-current-cover'));
    final title = find.byKey(const ValueKey('personal-fm-wide-current-title'));
    final pause = find.byTooltip('暂停');
    expect(find.descendant(of: details, matching: title), findsOneWidget);
    expect(
      tester.getTopLeft(details).dy,
      greaterThan(tester.getBottomLeft(stage).dy),
    );
    expect(
      tester.getTopLeft(cover).dy,
      greaterThan(tester.getBottomLeft(pause).dy),
    );
    final size = tester.getSize(cover);
    expect(size.width, closeTo(size.height, .01));
  });

  testWidgets('横屏右侧方形封面互相重叠，点露出的封面可切歌', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(1000, 600));

    final stage = find.byKey(const ValueKey('personal-fm-wide-stage'));
    final rects =
        tester
            .widgetList<Artwork>(
              find.descendant(of: stage, matching: find.byType(Artwork)),
            )
            .map((widget) => tester.getRect(find.byWidget(widget)))
            .toList()
          ..sort((a, b) => a.left.compareTo(b.left));
    expect(rects, hasLength(4));
    expect(rects[0].width, closeTo(rects[0].height, .01));
    expect(rects[0].overlaps(rects[1]), isTrue);
    expect(rects[1].left, greaterThan(rects[0].left));

    await tester.tapAt(rects[0].intersect(rects[1]).center);
    await tester.pump();
    expect(player.playCalls, 0);

    final coverTwo = rects[1];
    final exposed = Offset(coverTwo.right - 20, coverTwo.center.dy);
    expect(rects[0].contains(exposed), isFalse);
    await tester.tapAt(exposed);
    await tester.pump();

    expect(player.played!.title, '电台曲目 1');
  });

  testWidgets('横屏随栏宽减少封面重叠并铺到右边缘', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);
    await _pump(tester, player, size: const Size(900, 600));

    final stage = find.byKey(const ValueKey('personal-fm-wide-stage'));
    final covers = find.descendant(of: stage, matching: find.byType(Artwork));
    double overlapRatio() {
      final rects =
          covers
              .evaluate()
              .map((element) => tester.getRect(find.byWidget(element.widget)))
              .toList()
            ..sort((a, b) => a.left.compareTo(b.left));
      expect(rects, hasLength(4));
      expect(tester.getRect(stage).right - rects.last.right, closeTo(5, 1));
      expect(rects.first.width, closeTo(rects.first.height, .01));
      return (rects[0].right - rects[1].left) / rects[0].width;
    }

    final narrowOverlap = overlapRatio();
    tester.view.physicalSize = const Size(1280, 720);
    await tester.pump();
    final wideOverlap = overlapRatio();
    expect(wideOverlap, greaterThan(0));
    expect(wideOverlap, lessThan(narrowOverlap));
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏控制卡使用当前曲目的封面并随切歌更新', (tester) async {
    final player = _RadioPlayer(withCovers: true);
    addTearDown(player.dispose);
    await _pump(tester, player, size: const Size(1000, 600));

    final background = find.byKey(
      const ValueKey('personal-fm-wide-control-artwork'),
    );
    final cover = find.descendant(of: background, matching: find.byType(Image));
    expect(tester.getRect(cover), tester.getRect(background));
    expect(
      (tester.widget<Image>(cover).image as ResizeImage).imageProvider,
      CachedArtworkImage(player.songs[0].coverUrl!),
    );

    await tester.tap(find.byTooltip('下一首'));
    await tester.pump();

    expect(
      (tester.widget<Image>(cover).image as ResizeImage).imageProvider,
      CachedArtworkImage(player.songs[1].coverUrl!),
    );
    expect(find.text('电台曲目 1'), findsOneWidget);
  });

  testWidgets('横屏最窄宽屏下不溢出', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(900, 520));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏大字体设置下仍保持完整操作区', (tester) async {
    final player = _RadioPlayer(tracked: false);
    addTearDown(player.dispose);

    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1000, 600),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: PersonalFmSection(
                auth: FakeAuth(),
                player: player,
                visible: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('开始播放'), findsOneWidget);
  });

  testWidgets('窄屏下候选列表不横向溢出', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player, size: const Size(320, 640));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  test('卡片底色：未启用背景图时不透明，启用后半透明', () {
    const light = ColorScheme.light();
    expect(personalFmCardColor(light, frosted: false), light.surfaceContainer);
    final frosted = personalFmCardColor(light, frosted: true);
    expect(frosted.a, lessThan(1));
    expect(frosted.r, light.surfaceContainer.r);
  });
}
