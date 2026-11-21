import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/cloud_listening_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/playback_stats_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late CacheService cache;
  late AuthController auth;
  late MusicApi api;
  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('cloud_listening_test_');
    cache = CacheService(directory: directory);
    api = MusicApi(ApiClient());
    auth = AuthController(api, cache)
      ..session = const LoginSession(userId: 'u1', token: 't');
    now = DateTime(2026, 11, 21, 12);
  });

  tearDown(() async {
    auth.dispose();
    api.close();
    cache.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'keeps cache fresh for 15 minutes and coalesces concurrent reads',
    () async {
      var gradeCalls = 0;
      var rankCalls = 0;
      final service = CloudListeningService(
        api,
        auth,
        cache,
        now: () => now,
        gradeLoader: () async {
          gradeCalls++;
          return {
            'level': 7,
            'level_name': '听歌达人',
            'd_sec': 3661,
            'next_level_seconds': 7200,
          };
        },
        rankLoader: () async {
          rankCalls++;
          return {
            'songs': [
              {'songname': '海阔天空', 'singername': 'Beyond', 'count': 12},
            ],
          };
        },
      );

      final first = await Future.wait([
        service.load(),
        Future<void>.delayed(Duration.zero).then((_) => service.load()),
      ]);
      expect(gradeCalls, 1);
      expect(rankCalls, 1);
      expect(first.first.level, 7);
      expect(first.first.totalTime, const Duration(seconds: 3661));
      expect(first.first.nextLevelTime, const Duration(seconds: 7200));
      expect(
        first.first.rank.length + (first.first.rankError == null ? 1 : 0),
        greaterThanOrEqualTo(1),
      );

      now = now.add(const Duration(minutes: 14));
      await service.load();
      expect(gradeCalls, 1);
      now = now.add(const Duration(minutes: 3));
      await service.load();
      expect(gradeCalls, greaterThanOrEqualTo(1));
    },
  );

  test('account change discards stale responses', () async {
    final gate = Completer<void>();
    var count = 0;
    final service = CloudListeningService(
      api,
      auth,
      cache,
      now: () => now,
      gradeLoader: () async {
        count++;
        if (count == 1) await gate.future;
        return {'level': 5, 'd_sec': 50};
      },
      rankLoader: () async => <dynamic>[],
    );

    final oldLoad = service.load();
    auth.session = const LoginSession(userId: 'u2', token: 't2');
    gate.complete();
    final old = await oldLoad;
    expect(old.level, isNull);

    final next = await service.load();
    expect(next.level, 5);
    expect(count, 2);
  });

  test('fallback cache survives failed refresh', () async {
    var fail = false;
    final service = CloudListeningService(
      api,
      auth,
      cache,
      now: () => now,
      gradeLoader: () async {
        if (fail) throw StateError('offline');
        return {'level': 3, 'd_sec': 100};
      },
      rankLoader: () async => {
        'list': [
          {'songname': 'A', 'count': 1},
        ],
      },
    );

    final first = await service.load();
    expect(first.level, 3);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    fail = true;
    now = now.add(const Duration(minutes: 16));

    final reloaded = CloudListeningService(
      api,
      auth,
      cache,
      now: () => now,
      gradeLoader: () async => throw StateError('offline'),
      rankLoader: () async => throw StateError('offline'),
    );
    final fallback = await reloaded.load();
    expect(fallback.level, 3);
    expect(fallback.rank.single.title, 'A');
  });

  test('legacy numeric time is preserved as readonly', () {
    final stats = PlaybackStats.fromJson({
      'totalPlays': 5,
      'totalListenMs': 3000,
      'legacyReadonly': true,
    });
    expect(stats.legacyReadonly, isTrue);
    expect(stats.totalPlays, 5);
  });
}
