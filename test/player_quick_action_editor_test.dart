import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_page_layout_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/widgets/player_page_actions.dart';
import 'package:kgka_music_hl/ui/widgets/player_quick_action_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_quick_actions_test_support.dart';

void main() {
  setUp(() async {
    await prepareQuickActionTests(<String, Object>{});
  });

  testWidgets('从更多面板进入编辑态，勾选即时预览，取消不落盘', (tester) async {
    await pumpQuickActionPlayer(tester);
    expect(find.byType(PlayerQuickActionEditor), findsNothing);

    await openQuickActionEditor(tester);
    expect(find.byType(PlayerQuickActionEditor), findsOneWidget);
    final editorRect = tester.getRect(find.byType(PlayerQuickActionEditor));
    expect(editorRect.height, lessThan(tester.view.physicalSize.height * .65));
    expect(find.byTooltip('播放列表'), findsOneWidget);
    expect(find.byTooltip('上一首'), findsWidgets);
    final lyricsAction = tester.getRect(find.byTooltip('更换歌词'));
    expect(editorRect.bottom, lessThan(lyricsAction.top));
    expect(
      find.byKey(const Key('player-quick-action-edit-frame-lyricPicker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('player-quick-action-edit-frame-audioQuality')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('player-quick-action-edit-frame-audioEffects')),
      findsOneWidget,
    );
    expect(find.text('更多'), findsNothing);
    expect(find.byTooltip('倍速播放'), findsNothing);

    await tapQuickActionCandidate(tester, PlayerActionId.playbackSpeed);

    expect(find.byTooltip('倍速播放'), findsWidgets);
    expect(find.text('4/5'), findsOneWidget);
    expect(PlayerPageLayoutController.instance.hasCustomized, isFalse);

    await tester.tap(find.text('取消'));
    await pumpQuickActionFrames(tester);

    expect(find.byType(PlayerQuickActionEditor), findsNothing);
    expect(find.byTooltip('倍速播放'), findsNothing);
    expect(find.byTooltip('更换歌词'), findsWidgets);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(PlayerPageLayoutController.prefsKey), isFalse);
  });

  testWidgets('完成提交草稿并持久化，逐项互斥同步更新', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.audioQuality,
        PlayerActionId.sleepTimer,
      ]),
    );
    await pumpQuickActionPlayer(tester);
    await openQuickActionEditor(tester);

    await tester.tap(find.byTooltip('移除 音质'));
    await pumpQuickActionFrames(tester);
    await tapQuickActionCandidate(tester, PlayerActionId.playbackSpeed);
    expect(find.byTooltip('音质 · 128K'), findsNothing);
    expect(find.byTooltip('倍速播放'), findsWidgets);
    expect(PlayerPageLayoutController.instance.saved, [
      PlayerActionId.audioQuality,
      PlayerActionId.sleepTimer,
    ]);

    await tester.tap(find.text('完成'));
    await pumpQuickActionFrames(tester);

    expect(find.byType(PlayerQuickActionEditor), findsNothing);
    expect(PlayerPageLayoutController.instance.saved, [
      PlayerActionId.sleepTimer,
      PlayerActionId.playbackSpeed,
    ]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(PlayerPageLayoutController.prefsKey), [
      'sleepTimer',
      'playbackSpeed',
    ]);

    await openMoreSheet(tester);
    expect(find.text('音质：标准音质'), findsOneWidget);
    expect(find.text('倍速播放'), findsNothing);
    expect(find.text('定时播放'), findsNothing);
  });

  testWidgets('恢复默认提交后删除配置键并回到兼容模式', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([PlayerActionId.playbackSpeed]),
    );
    await pumpQuickActionPlayer(tester);
    expect(find.byTooltip('更换歌词'), findsNothing);

    await openQuickActionEditor(tester);
    await tester.tap(find.text('恢复默认'));
    await pumpQuickActionFrames(tester);
    expect(find.byTooltip('更换歌词'), findsWidgets);
    expect(PlayerPageLayoutController.instance.hasCustomized, isTrue);

    await tester.tap(find.text('完成'));
    await pumpQuickActionFrames(tester);

    expect(PlayerPageLayoutController.instance.hasCustomized, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(PlayerPageLayoutController.prefsKey), isFalse);
    expect(find.byTooltip('更换歌词'), findsWidgets);
    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('音效 · 关闭'), findsOneWidget);
    expect(find.byTooltip('倍速播放'), findsNothing);
  });

  testWidgets('条件动作灰显并注明原因，勾选后不占槽位', (tester) async {
    const localSong = Song(
      id: 'local',
      hash: 'local',
      title: 'Local song',
      artist: 'Local artist',
      source: SongSource.local,
    );
    await pumpQuickActionPlayer(tester, song: localSong);
    await openQuickActionEditor(tester);

    final addPlaylist = find.byKey(
      const Key('quick-action-candidate-addToPlaylist'),
    );
    await tester.scrollUntilVisible(
      addPlaylist,
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await pumpQuickActionFrames(tester);
    expect(
      tester
          .widget<Text>(
            find.descendant(of: addPlaylist, matching: find.byType(Text)).first,
          )
          .data,
      contains('仅酷狗歌曲'),
    );
    await tester.tap(addPlaylist);
    await pumpQuickActionFrames(tester);

    expect(find.byTooltip('添加到歌单'), findsNothing);
    expect(find.text('仅酷狗歌曲'), findsOneWidget);
  });

  test('编辑器状态之外的注册表保留 9 项候选与 5 项核心控件', () {
    expect(kEditableActionIds.length, 9);
    expect(PlayerActionId.values.length, 14);
    expect(kLegacyQuickActions, [
      PlayerActionId.lyricPicker,
      PlayerActionId.audioQuality,
      PlayerActionId.audioEffects,
    ]);
  });
}
