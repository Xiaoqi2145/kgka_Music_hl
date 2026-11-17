import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

void main() {
  test('daily banner keeps a fixed height across screen widths', () {
    expect(dailyBannerHeight, 168);
  });

  test('banner date label strips the year from the daily title', () {
    expect(dailyBannerDateLabel('每日推荐 2026-11-17'), '11月17日');
    expect(dailyBannerDateLabel('每日推荐 2026/1/5'), '1月5日');
  });

  test('banner date label falls back to today when no date is present', () {
    final now = DateTime(2026, 3, 9);
    expect(dailyBannerDateLabel('每日推荐', now: now), '3月9日');
  });
}
