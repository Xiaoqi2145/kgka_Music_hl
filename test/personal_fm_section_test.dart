import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/models/personal_fm_models.dart';
import 'package:kgka_music_hl/services/personal_fm_session.dart';
import 'package:kgka_music_hl/ui/widgets/personal_fm_section.dart';

import 'player_quick_actions_test_support.dart';

class _RadioPlayer extends FakePlayer {
  _RadioPlayer({this.tracked = true});

  final bool tracked;
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

  @override
  PersonalFmTrack? get personalFmCurrentTrack =>
      tracked ? PersonalFmTrack(song: songs[index]) : null;

  @override
  PersonalFmSession? get personalFmSession => null;

  @override
  bool get personalFmCurrentDisliked => disliked;

  @override
  Iterable<Song> get upcomingPersonalFmSongs => songs.skip(index + 1);

  @override
  String? get errorMessage => null;

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

Future<void> _pump(WidgetTester tester, _RadioPlayer player) {
  return tester.pumpWidget(
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
  testWidgets('电台下方展示五首待播歌曲并随切歌更新', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);

    await _pump(tester, player);

    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('电台曲目 1'), findsOneWidget);
    expect(find.text('电台曲目 6'), findsNothing);

    await tester.tap(find.byTooltip('下一首'));
    await tester.pump();

    expect(find.text('电台曲目 0'), findsNothing);
    expect(find.text('电台曲目 6'), findsOneWidget);
  });

  testWidgets('未开播时展示入口卡片，不显示接下来', (tester) async {
    final player = _RadioPlayer(tracked: false);
    addTearDown(player.dispose);

    await _pump(tester, player);

    expect(find.text('按你的口味推荐歌曲'), findsOneWidget);
    expect(find.text('开始播放'), findsOneWidget);
    expect(find.text('接下来'), findsNothing);
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
    expect(find.text('电台曲目 0'), findsNothing);
    expect(find.text('电台曲目 1'), findsOneWidget);
  });

  testWidgets('候选耗尽时给出重新获取入口', (tester) async {
    final player = _RadioPlayer();
    addTearDown(player.dispose);
    player.index = 6;

    await _pump(tester, player);

    expect(find.text('暂时没有接下来的推荐'), findsOneWidget);
    expect(find.text('重新获取'), findsOneWidget);
  });

  test('卡片底色：未启用背景图时不透明，启用后半透明', () {
    const light = ColorScheme.light();
    expect(
      personalFmCardColor(light, frosted: false),
      light.surfaceContainer,
    );
    final frosted = personalFmCardColor(light, frosted: true);
    expect(frosted.a, lessThan(1));
    expect(frosted.r, light.surfaceContainer.r);
  });
}
