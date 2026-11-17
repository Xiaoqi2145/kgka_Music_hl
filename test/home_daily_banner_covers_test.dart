import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

Song _song(String title, String? cover) => Song(
  id: title,
  hash: title,
  title: title,
  artist: 'artist',
  coverUrl: cover,
);

void main() {
  test('banner uses the first two song covers', () {
    final daily = DailyRecommend(
      title: '每日推荐 2026-11-17',
      songs: [
        _song('a', 'https://x/a.jpg'),
        _song('b', 'https://x/b.jpg'),
        _song('c', 'https://x/c.jpg'),
      ],
    );
    expect(dailyBannerCovers(daily), ['https://x/a.jpg', 'https://x/b.jpg']);
  });

  test('banner falls back to the daily cover when songs lack artwork', () {
    final daily = DailyRecommend(
      title: '每日推荐 2026-11-17',
      coverUrl: 'https://x/daily.jpg',
      songs: [_song('a', null)],
    );
    expect(dailyBannerCovers(daily), ['https://x/daily.jpg']);
  });

  test('banner never repeats the same cover twice', () {
    final daily = DailyRecommend(
      title: '每日推荐 2026-11-17',
      songs: [
        _song('a', 'https://x/same.jpg'),
        _song('b', 'https://x/same.jpg'),
      ],
    );
    expect(dailyBannerCovers(daily), ['https://x/same.jpg']);
  });

  test('banner has no covers when nothing is available', () {
    final daily = DailyRecommend(
      title: '每日推荐',
      songs: [_song('a', null)],
    );
    expect(dailyBannerCovers(daily), isEmpty);
  });
}
