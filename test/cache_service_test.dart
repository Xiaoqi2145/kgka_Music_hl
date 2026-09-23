import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late CacheService cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    directory = await Directory.systemTemp.createTemp('ka_data_cache_test');
    cache = CacheService(directory: directory);
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('reports TTL expiry without discarding stale payload', () async {
    await cache.write('cache_ttl_test', <String, dynamic>{'value': 7});

    final result = await cache.read<Map<String, dynamic>>(
      'cache_ttl_test',
      decode: (json) => json,
      ttl: Duration.zero,
    );

    expect(result?.data['value'], 7);
    expect(result?.isStale, isTrue);
  });

  test('serializes concurrent writes to the same key', () async {
    await Future.wait([
      cache.write('cache_race_test', <String, dynamic>{'value': 1}),
      cache.write('cache_race_test', <String, dynamic>{'value': 2}),
    ]);

    final result = await cache.read<Map<String, dynamic>>(
      'cache_race_test',
      decode: (json) => json,
    );
    expect(result, isNotNull);
    expect(<int>{1, 2}, contains(result!.data['value']));
  });

  test('removes unreadable cache files after a failed read', () async {
    const key = 'cache_corrupt_test';
    final name = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    final file = File('${directory.path}/$name.json');
    await file.writeAsString('{broken json');

    final result = await cache.read<Map<String, dynamic>>(
      key,
      decode: (json) => json,
    );

    expect(result, isNull);
    expect(await file.exists(), isFalse);
  });

  test('prunes data cache to the configured capacity', () async {
    cache = CacheService(directory: directory, maxCacheBytes: 120);
    for (var i = 0; i < 16; i++) {
      await cache.write('cache_capacity_$i', <String, dynamic>{
        'value': 'x' * 30,
      });
    }

    expect(await cache.getCacheSize(), lessThanOrEqualTo(120));
    expect(await cache.getCacheCount(), lessThan(16));
  });

  test('clears data cache and legacy playlist preferences', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ka_music_cached_playlists_user', '[]');
    await cache.write('cache_clear_test', <String, dynamic>{'value': true});
    final generation = cache.clearGeneration;

    await cache.clearAllCache();

    expect(cache.clearGeneration, generation + 1);
    expect(prefs.containsKey('ka_music_cached_playlists_user'), isFalse);
    expect(
      await cache.read<Map<String, dynamic>>(
        'cache_clear_test',
        decode: (json) => json,
      ),
      isNull,
    );
  });
}
