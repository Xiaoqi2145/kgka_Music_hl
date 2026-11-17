import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

void main() {
  test('dailyBannerHeight leaves room for the row on a small phone', () {
    // 320x568 是最常见的最小逻辑尺寸之一，Banner 必须能完整站下。
    const screen = Size(320, 568);
    expect(dailyBannerHeight, lessThan(screen.height));
  });

  testWidgets('banner date label renders inside a constrained box', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: dailyBannerHeight,
              child: Text(
                dailyBannerDateLabel('每日推荐 2026-11-17'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
