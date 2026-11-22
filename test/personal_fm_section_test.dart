import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/models/personal_fm_models.dart';
import 'package:kgka_music_hl/services/personal_fm_session.dart';
import 'package:kgka_music_hl/ui/widgets/artwork.dart';
import 'package:kgka_music_hl/ui/widgets/personal_fm_section.dart';

import 'player_quick_actions_test_support.dart';

class _RadioPlayer extends FakePlayer {
  _RadioPlayer({this.tracked = true, this.preparing = false});

  final bool tracked;
  bool preparing;
  final songs = List.generate(
    7,
    (index) => Song(
      id: '$index',
      title: '电台曲目 $index',
      artist: '电台艺人',
      hash: 'hash-$index',
    ),
  );
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
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
    // 第 5 首只出现在「接下来」列表里（横向封面栏只放前 4 首），
    // 用它验证待播列表本身也是可点选的入口。
    await tester.tap(find.text('电台曲目 5'));
    await tester.pump();

    expect(player.played!.title, '电台曲目 5');
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
