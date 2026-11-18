import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

void main() {
  test('phone width stays single column', () {
    final m = dailyBannerMetrics(354);
    expect(m.columns, 1);
    expect(m.height, greaterThanOrEqualTo(148));
    expect(m.height, lessThanOrEqualTo(188));
  });

  test('tablet portrait splits into two columns', () {
    final m = dailyBannerMetrics(764);
    expect(m.columns, 2);
  });

  test('tablet landscape splits into two columns without growing unbounded', () {
    final m = dailyBannerMetrics(1114);
    expect(m.columns, 2);
    // 高度必须夹在区间内：旧实现是写死 168 直接铺到 6.6:1。
    expect(m.height, lessThanOrEqualTo(188));
  });

  test('banner height never exceeds the cap across widths', () {
    for (final width in [280.0, 354.0, 480.0, 640.0, 800.0, 1114.0, 1600.0]) {
      final m = dailyBannerMetrics(width);
      expect(m.height, inInclusiveRange(148, 188), reason: 'width=$width');
    }
  });

  test('degenerate widths fall back to a sane default', () {
    for (final width in [0.0, -10.0, double.nan, double.infinity]) {
      final m = dailyBannerMetrics(width);
      expect(m.height, 168, reason: 'width=$width');
      expect(m.columns, 1, reason: 'width=$width');
    }
  });

  test('two-column layout uses compact typography', () {
    expect(dailyBannerMetrics(1114).compact, isTrue);
    expect(dailyBannerMetrics(354).compact, isFalse);
  });

  test('meta label omits the count when there are no songs', () {
    expect(dailyBannerMetaLabel('11月17日', 30), '11月17日   30首');
    expect(dailyBannerMetaLabel('11月17日', 0), '11月17日');
  });
}
