import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/artwork_cache_service.dart';

void main() {
  ArtworkCacheEntry entry(String path, int size, int minutesAgo) {
    return ArtworkCacheEntry(
      path: path,
      size: size,
      accessedAt: DateTime(2026).subtract(Duration(minutes: minutesAgo)),
    );
  }

  group('ArtworkCacheService.selectLruEvictions', () {
    test('总量未超过上限时不淘汰任何条目', () {
      final entries = [entry('a', 100, 1), entry('b', 100, 2)];
      expect(ArtworkCacheService.selectLruEvictions(entries, 1000), isEmpty);
    });

    test('总量恰好等于上限时不淘汰', () {
      final entries = [entry('a', 100, 1), entry('b', 100, 2)];
      expect(ArtworkCacheService.selectLruEvictions(entries, 200), isEmpty);
    });

    test('超出上限时淘汰最久未访问的条目', () {
      final entries = [
        entry('new', 100, 1),
        entry('old', 100, 10),
        entry('mid', 100, 5),
      ];
      final evicted = ArtworkCacheService.selectLruEvictions(entries, 200);
      expect(evicted.map((e) => e.path).toList(), ['old']);
    });

    test('需要淘汰多条时按访问时间升序返回', () {
      final entries = [
        entry('new', 100, 1),
        entry('old', 100, 10),
        entry('mid', 100, 5),
      ];
      final evicted = ArtworkCacheService.selectLruEvictions(entries, 100);
      expect(evicted.map((e) => e.path).toList(), ['old', 'mid']);
    });

    test('单个条目超过上限时同样被淘汰', () {
      final entries = [entry('huge', 500, 1)];
      final evicted = ArtworkCacheService.selectLruEvictions(entries, 100);
      expect(evicted.map((e) => e.path).toList(), ['huge']);
    });

    test('访问时间相同时按路径稳定排序', () {
      final entries = [entry('b', 100, 3), entry('a', 100, 3)];
      final evicted = ArtworkCacheService.selectLruEvictions(entries, 100);
      expect(evicted.map((e) => e.path).toList(), ['a']);
    });

    test('空列表不抛异常', () {
      expect(ArtworkCacheService.selectLruEvictions(const [], 0), isEmpty);
    });
  });
}
