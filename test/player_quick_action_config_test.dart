import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_page_layout_controller.dart';
import 'package:kgka_music_hl/ui/widgets/player_page_actions.dart';
import 'package:kgka_music_hl/ui/widgets/player_quick_action_bar.dart';
import 'package:kgka_music_hl/ui/widgets/player_quick_action_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_quick_actions_test_support.dart';

void main() {
  setUp(() async {
    await prepareQuickActionTests(<String, Object>{});
  });

  testWidgets('自定义配置只渲染选中的两项，并逐项从更多面板移除', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.audioQuality,
        PlayerActionId.playbackSpeed,
      ]),
    );
    await pumpQuickActionPlayer(tester);

    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('倍速播放'), findsOneWidget);
    expect(find.byTooltip('更换歌词'), findsNothing);
    expect(find.byTooltip('音效 · 关闭'), findsNothing);
    expect(find.byType(PlayerQuickActionBar), findsWidgets);

    await openMoreSheet(tester);
    expect(find.text('音质：标准音质'), findsNothing);
    expect(find.text('倍速播放'), findsNothing);
    expect(find.text('音效'), findsOneWidget);
    expect(find.text('更换歌词'), findsOneWidget);
    expect(find.text('编辑播放页'), findsOneWidget);
  });

  testWidgets('竖屏自定义配置不渲染宿主，更多面板保持完整', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.audioQuality,
        PlayerActionId.audioEffects,
        PlayerActionId.lyricPicker,
      ]),
    );
    await pumpQuickActionPlayer(tester, size: kPhonePortrait);

    for (final bar in tester.widgetList<PlayerQuickActionBar>(
      find.byType(PlayerQuickActionBar),
    )) {
      expect(bar.resolution.actions, isEmpty);
    }
    expect(find.byTooltip('音质 · 128K'), findsNothing);

    await openMoreSheet(tester);
    expect(find.text('音质'), findsOneWidget);
    expect(find.text('音效'), findsOneWidget);
    expect(find.text('倍速'), findsOneWidget);
    expect(find.text('编辑播放页'), findsOneWidget);
  });

  testWidgets('手机横屏自定义配置按 3 个容量截断', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.playbackSpeed,
        PlayerActionId.audioQuality,
        PlayerActionId.audioEffects,
        PlayerActionId.sleepTimer,
      ]),
    );
    await pumpQuickActionPlayer(tester, size: kPhoneLandscape);

    expect(find.byTooltip('倍速播放'), findsOneWidget);
    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('音效 · 关闭'), findsOneWidget);
    expect(find.byTooltip('定时播放'), findsNothing);

    await openMoreSheet(tester);
    expect(find.text('定时播放'), findsOneWidget);
  });

  testWidgets('手机横屏兼容模式显示原有三个快捷动作', (tester) async {
    await pumpQuickActionPlayer(tester, size: kPhoneLandscape);

    expect(find.byTooltip('更换歌词'), findsOneWidget);
    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('音效 · 关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机横屏控制行与快捷动作同排且不溢出', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.lyricPicker,
        PlayerActionId.audioQuality,
        PlayerActionId.audioEffects,
      ]),
    );
    await pumpQuickActionPlayer(tester, size: kPhoneLandscape);

    final queue = tester.getRect(find.byTooltip('播放列表'));
    final lyrics = tester.getRect(find.byTooltip('更换歌词'));
    expect((lyrics.center.dy - queue.center.dy).abs(), lessThan(1));
    expect((lyrics.width - queue.width).abs(), lessThan(.1));
    expect((lyrics.height - queue.height).abs(), lessThan(.1));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('音效 · 关闭'), findsOneWidget);
  });

  testWidgets('720x360 横屏使用 3 个槽位且控制行不溢出', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.lyricPicker,
        PlayerActionId.audioQuality,
        PlayerActionId.audioEffects,
        PlayerActionId.playbackSpeed,
      ]),
    );
    await pumpQuickActionPlayer(tester, size: const Size(720, 360));

    expect(find.byTooltip('更换歌词'), findsOneWidget);
    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('音效 · 关闭'), findsOneWidget);
    expect(find.byTooltip('倍速播放'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机横屏编辑面板不覆盖控制行', (tester) async {
    await pumpQuickActionPlayer(tester, size: const Size(720, 360));
    await openQuickActionEditor(tester);

    final editor = tester.getRect(find.byType(PlayerQuickActionEditor));
    final queue = tester.getRect(find.byTooltip('播放列表'));
    expect(editor.top, greaterThan(0));
    expect(editor.height, lessThan(360 * .75));
    expect(queue.top, greaterThan(editor.bottom));
    expect(
      find.byKey(const Key('quick-action-candidate-playbackSpeed')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('条件不可用项不占槽且仍留在更多面板', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.desktopLyrics,
        PlayerActionId.playbackSpeed,
      ]),
    );
    await pumpQuickActionPlayer(tester);

    expect(find.byTooltip('倍速播放'), findsOneWidget);
    expect(find.byTooltip('桌面歌词'), findsNothing);
    expect(
      PlayerPageLayoutController.instance.saved,
      contains(PlayerActionId.desktopLyrics),
    );
  });

  testWidgets('快捷动作与控制行同排，尺寸与播放列表一致', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([
        PlayerActionId.lyricPicker,
        PlayerActionId.audioQuality,
        PlayerActionId.audioEffects,
      ]),
    );
    await pumpQuickActionPlayer(tester);

    final queue = tester.getRect(find.byTooltip('播放列表'));
    final lyrics = tester.getRect(find.byTooltip('更换歌词'));
    final quality = tester.getRect(find.byTooltip('音质 · 128K'));
    final effects = tester.getRect(find.byTooltip('音效 · 关闭'));
    final controls = tester.getRect(
      find
          .ancestor(
            of: find.byTooltip('播放列表'),
            matching: find.byType(FittedBox),
          )
          .first,
    );

    expect((lyrics.center.dy - queue.center.dy).abs(), lessThan(1));
    expect((quality.center.dy - queue.center.dy).abs(), lessThan(1));
    expect((effects.center.dy - queue.center.dy).abs(), lessThan(1));
    expect(lyrics.size, queue.size);
    expect(quality.size, queue.size);
    expect(effects.size, queue.size);
    expect(controls.left, lessThan(lyrics.left));
    expect(controls.right, greaterThan(effects.right));
  });

  testWidgets('veryTight 横屏隐藏整行快捷区', (tester) async {
    await prepareQuickActionTests(
      quickActionPrefs([PlayerActionId.playbackSpeed]),
    );
    await pumpQuickActionPlayer(tester, size: const Size(1024, 240));

    expect(find.byTooltip('倍速播放'), findsNothing);
    for (final bar in tester.widgetList<PlayerQuickActionBar>(
      find.byType(PlayerQuickActionBar),
    )) {
      expect(bar.resolution.actions, isEmpty);
      expect(bar.resolution.excludeIds, isEmpty);
    }
  });

  test('持久化读取忽略未知 ID、保留空列表语义', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PlayerPageLayoutController.prefsKey: <String>[
        'audioQuality',
        'unknown_action',
        'audioQuality',
        'playPause',
      ],
    });
    final controller = PlayerPageLayoutController.instance;
    await controller.load();
    expect(controller.hasCustomized, isTrue);
    expect(controller.saved, <PlayerActionId>[PlayerActionId.audioQuality]);

    await controller.resetToDefault(
      preferences: await SharedPreferences.getInstance(),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(PlayerPageLayoutController.prefsKey), isFalse);
    expect(controller.hasCustomized, isFalse);

    SharedPreferences.setMockInitialValues(<String, Object>{
      PlayerPageLayoutController.prefsKey: <String>[],
    });
    await controller.load();
    expect(controller.hasCustomized, isTrue);
    expect(controller.saved, isEmpty);
  });
}
