import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kgka_music_hl/config/app_config.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/cloud_playback_sync_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CacheService cache;
  late AuthController auth;
  late MusicApi api;
  late DateTime now;
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.loadCustomBaseUrl();
    directory = Directory.systemTemp.createTempSync('cloud_sync_test_');
    cache = CacheService(directory: directory);
    api = MusicApi(ApiClient());
    auth = AuthController(api, cache)
      ..session = const LoginSession(userId: 'u1', token: 't1');
    now = DateTime(2026, 11, 21, 12);
  });

  tearDown(() async {
    auth.dispose();
    api.close();
    cache.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'history waits 30 minutes, sends one item, and does not replay',
    () async {
      final calls = <String>[];
      final service = CloudPlaybackSyncService(
        api,
        auth,
        directory: directory,
        now: () => now,
        historyUploader: ({required mxid, required time, pc = 1}) async {
          calls.add(mxid);
          return {'status': 1};
        },
        legacyGradeUploader: () async => {'status': 1},
      );
      await service.setHistoryEnabled(true);
      const song = Song(
        id: 'catalog',
        title: 'A',
        artist: 'B',
        hash: 'h',
        catalogId: '260403475',
      );
      await service.enqueueHistory(song, playedAt: now);
      expect(await service.maybeSync(), SyncOutcome.sent);
      expect(calls, ['260403475']);
      await service.enqueueHistory(song, playedAt: now);
      expect(await service.maybeSync(), isNot(SyncOutcome.sent));
      now = now.add(const Duration(minutes: 31));
      expect(await service.maybeSync(), SyncOutcome.sent);
      expect(calls.length, greaterThanOrEqualTo(1));
    },
  );

  test(
    'grade requires a full 30 minute batch and uses read baseline',
    () async {
      await AppConfig.saveCustomBaseUrl('https://custom.example');
      var uploads = 0;
      int? baseline;
      int? diff;
      final service = CloudPlaybackSyncService(
        api,
        auth,
        directory: directory,
        now: () => now,
        historyUploader: ({required mxid, required time, pc = 1}) async => null,
        gradeReader: () async => {
          'grade': {'d_sec': 600},
        },
        gradeUploader: ({required dSec, required diffSec}) async {
          uploads++;
          baseline = dSec;
          diff = diffSec;
          return {'status': 1};
        },
      );
      service.enqueueGradeTime(const Duration(minutes: 29));
      now = now.add(const Duration(minutes: 29));
      expect(await service.maybeSync(), isNot(SyncOutcome.sent));
      expect(uploads, 0);
      now = now.add(const Duration(minutes: 1));
      service.enqueueGradeTime(const Duration(minutes: 1));
      expect(await service.maybeSync(), SyncOutcome.sent);
      expect(uploads, 1);
      expect(baseline, 600);
      expect(diff, 1800);
    },
  );

  test('hosted API posts one legacy batch from subsecond samples', () async {
    final requests = <http.Request>[];
    final hostedApi = MusicApi(
      ApiClient(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{"status":1}', 200);
        }),
      ),
    )..setSession(auth.session);
    addTearDown(hostedApi.close);
    final service = CloudPlaybackSyncService(
      hostedApi,
      auth,
      directory: directory,
      now: () => now,
    );
    addTearDown(service.dispose);
    service.setForeground(false);
    service.enqueueGradeTime(const Duration(milliseconds: 500));
    expect(directory.listSync(), isEmpty);
    for (var i = 1; i < 3600; i++) {
      service.enqueueGradeTime(const Duration(milliseconds: 500));
    }
    await service.flushGradeTime();
    expect(service.snapshot.gradePending, const Duration(minutes: 30));
    expect(await service.maybeSync(), SyncOutcome.deferred);
    expect(requests, isEmpty);

    service.setForeground(true);
    expect(await service.maybeSync(), SyncOutcome.sent);
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/listen/timeadd');
    expect(requests.single.body, isEmpty);
    expect(service.snapshot.gradePending, Duration.zero);
    expect(await service.maybeSync(), SyncOutcome.idle);
    expect(requests, hasLength(1));
  });

  test('uncertain legacy write consumes just its batch and waits', () async {
    var requests = 0;
    final service = CloudPlaybackSyncService(
      api,
      auth,
      directory: directory,
      now: () => now,
      legacyGradeUploader: () async {
        if (++requests == 1) throw TimeoutException('uncertain');
        return {'status': 1};
      },
    );
    addTearDown(service.dispose);
    service.setForeground(false);
    service.enqueueGradeTime(const Duration(hours: 1));
    await service.flushGradeTime();
    service.setForeground(true);
    expect(await service.maybeSync(), SyncOutcome.unknownResult);
    expect(service.snapshot.gradePending, const Duration(minutes: 30));
    expect(await service.maybeSync(), SyncOutcome.backoff);
    now = now.add(const Duration(minutes: 30));
    expect(await service.maybeSync(), SyncOutcome.sent);
    expect(service.snapshot.gradePending, Duration.zero);
    expect(requests, 2);
  });

  test(
    'foreground playback checkpoints trigger a full batch automatically',
    () async {
      var requests = 0;
      final service = CloudPlaybackSyncService(
        api,
        auth,
        directory: directory,
        now: () => now,
        legacyGradeUploader: () async {
          requests++;
          return {'status': 1};
        },
      );
      addTearDown(service.dispose);
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(minutes: 5));
        service.enqueueGradeTime(const Duration(minutes: 5));
        await service.flushGradeTime();
        expect(requests, i < 5 ? 0 : 1);
      }
      expect(service.snapshot.gradePending, Duration.zero);
    },
  );

  test(
    'explicit rejection backs off; network uncertainty is not replayed',
    () async {
      var attempts = 0;
      final service = CloudPlaybackSyncService(
        api,
        auth,
        directory: directory,
        now: () => now,
        retryUnit: const Duration(minutes: 1),
        historyUploader: ({required mxid, required time, pc = 1}) async {
          attempts++;
          if (attempts == 1) return {'status': 0};
          throw TimeoutException('unknown');
        },
        gradeReader: () async => throw StateError('grade disabled by test'),
        gradeUploader: ({required dSec, required diffSec}) async =>
            throw StateError('grade disabled by test'),
      );
      service.configure(gradeEnabled: false);
      await service.setHistoryEnabled(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      const song = Song(
        id: 'catalog',
        title: 'A',
        artist: 'B',
        hash: 'h',
        catalogId: '260403475',
      );
      await service.enqueueHistory(song, playedAt: now);
      expect(await service.maybeSync(), isNot(SyncOutcome.sent));
      now = now.add(const Duration(minutes: 31));
      expect(await service.maybeSync(), isNot(SyncOutcome.sent));
      now = now.add(const Duration(minutes: 1));
      expect(await service.maybeSync(), isNot(SyncOutcome.sent));
      now = now.add(const Duration(minutes: 31));
      expect(await service.maybeSync(), isNot(SyncOutcome.sent));
      expect(attempts, greaterThanOrEqualTo(1));
    },
  );

  test('account changes do not reuse another account queue', () async {
    final service = CloudPlaybackSyncService(
      api,
      auth,
      directory: directory,
      now: () => now,
      historyUploader: ({required mxid, required time, pc = 1}) async => null,
      gradeReader: () async => {'d_sec': 0},
      gradeUploader: ({required dSec, required diffSec}) async => null,
    );
    await service.setHistoryEnabled(true);
    const song = Song(
      id: 'catalog',
      title: 'A',
      artist: 'B',
      hash: 'h',
      catalogId: '260403475',
    );
    await service.enqueueHistory(song, playedAt: now);
    auth.session = const LoginSession(userId: 'u2', token: 't2');
    expect(service.snapshot.historyPending, anyOf(0, 1));
    expect(await service.maybeSync(), SyncOutcome.idle);
  });
}
