import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/playback_stats_page.dart';

void main() {
  testWidgets('cloud summary card handles long Chinese level names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [
              SizedBox(
                width: 320,
                child: CloudStatsPreview(
                  summary: CloudStatsPreviewSummary(
                    level: 123,
                    levelName: '一段非常长的酷狗听歌等级称号',
                    totalSeconds: 7325,
                    nextLevelSeconds: 86400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.textContaining('一段非常长的'), findsOneWidget);
    expect(find.text('2小时2分钟'), findsOneWidget);
    expect(find.text('24小时0分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('formats cloud durations at meaningful boundaries', () {
    expect(formatCloudListenTime(const Duration(seconds: 12)), '12秒');
    expect(formatCloudListenTime(const Duration(seconds: 125)), '2分钟5秒');
    expect(formatCloudListenTime(const Duration(seconds: 7325)), '2小时2分钟');
  });
}
