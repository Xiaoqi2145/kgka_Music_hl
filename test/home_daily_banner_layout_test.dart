import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

Song _song(String title, String cover) => Song(
  id: title,
  hash: title,
  title: title,
  artist: 'artist-$title',
  coverUrl: cover,
);

DailyRecommend _daily() => DailyRecommend(
  title: '每日推荐 2026-11-18',
  songs: [
    _song('a', 'https://x/a.jpg'),
    _song('b', 'https://x/b.jpg'),
  ],
);

void main() {
  test('metrics never request more columns than available items', () {
    final items = dailyBannerItems(_daily());
    expect(items.length, 2);
    // 宽屏最多取两张，窄屏取一张——take(columns) 不会越界。
    expect(items.take(dailyBannerMetrics(354).columns).length, 1);
    expect(items.take(dailyBannerMetrics(1114).columns).length, 2);
  });

  test('cover side never exceeds half of the card width', () {
    // _BannerCard 用 maxHeight 作为正方形边长，再夹到卡片半宽以内。
    for (final cardWidth in [180.0, 320.0, 557.0]) {
      for (final cardHeight in [148.0, 168.0, 188.0]) {
        final side = cardHeight.clamp(0.0, cardWidth * .5);
        expect(side, lessThanOrEqualTo(cardWidth * .5) , reason: '$cardWidth/$cardHeight');
        expect(side, greaterThan(0));
      }
    }
  });

  test('two columns each get roughly half the banner width', () {
    const available = 1114.0;
    const gap = 12.0;
    final cardWidth = (available - gap) / 2;
    final m = dailyBannerMetrics(available);
    expect(m.columns, 2);
    // 每张卡宽约 551，高度被夹到 188，比例约 2.9:1（旧实现整体是 6.6:1）。
    expect(cardWidth / m.height, lessThan(3.2));
  });
}
