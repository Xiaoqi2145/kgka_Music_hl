import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';

Song _song(String title, String? cover) => Song(
  id: title,
  hash: title,
  title: title,
  artist: 'artist-$title',
  coverUrl: cover,
);

void main() {
  test('banner items pair each song with its own cover and artist', () {
    final daily = DailyRecommend(
      title: '每日推荐 2026-11-17',
      songs: [
        _song('a', 'https://x/a.jpg'),
        _song('b', 'https://x/b.jpg'),
        _song('c', 'https://x/c.jpg'),
      ],
    );
    final items = dailyBannerItems(daily);
    expect(items.length, 2);
    expect(items[0].title, 'a');
    expect(items[0].artist, 'artist-a');
    expect(items[0].coverUrl, 'https://x/a.jpg');
    expect(items[1].title, 'b');
  });

  test('songs without artwork are skipped rather than shown as blank cards', () {
    final daily = DailyRecommend(
      title: '每日推荐',
      songs: [_song('a', null), _song('b', 'https://x/b.jpg')],
    );
    final items = dailyBannerItems(daily);
    expect(items.length, 1);
    expect(items.single.title, 'b');
  });

  test('banner never repeats the same cover twice', () {
    final daily = DailyRecommend(
      title: '每日推荐',
      songs: [
        _song('a', 'https://x/same.jpg'),
        _song('b', 'https://x/same.jpg'),
      ],
    );
    expect(dailyBannerItems(daily).length, 1);
  });

  test('falls back to the daily cover when no song has artwork', () {
    final daily = DailyRecommend(
      title: '每日推荐',
      coverUrl: 'https://x/daily.jpg',
      songs: [_song('a', null)],
    );
    final items = dailyBannerItems(daily);
    expect(items.length, 1);
    expect(items.single.coverUrl, 'https://x/daily.jpg');
    expect(items.single.title, 'a');
  });

  test('no items when nothing is available', () {
    final daily = DailyRecommend(title: '每日推荐', songs: [_song('a', null)]);
    expect(dailyBannerItems(daily), isEmpty);
  });
}
