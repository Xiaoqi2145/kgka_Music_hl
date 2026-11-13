import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_page_layout_controller.dart';
import 'package:kgka_music_hl/ui/widgets/player_page_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_quick_actions_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPlayer(WidgetTester tester, {required Size size}) async {
    await pumpQuickActionPlayer(tester, size: size);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await PlayerPageLayoutController.instance.load();
  });

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

  testWidgets('custom config renders only the selected quick actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(
      quickActionPrefs([
        PlayerActionId.audioQuality,
        PlayerActionId.playbackSpeed,
      ]),
    );
    await PlayerPageLayoutController.instance.load();
    await pumpPlayer(tester, size: const Size(1024, 768));

    expect(find.byTooltip('音质 · 128K'), findsOneWidget);
    expect(find.byTooltip('倍速播放'), findsOneWidget);
    expect(find.byTooltip('更换歌词'), findsNothing);
    expect(find.byTooltip('音效 · 关闭'), findsNothing);
  });
}
