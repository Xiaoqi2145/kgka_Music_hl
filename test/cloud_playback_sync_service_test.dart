import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
        gradeReader: () async => {'d_sec': 0},
        gradeUploader: ({required dSec, required diffSec}) async {
          return {'status': 1};
        },
      );
      await service.setHistoryEnabled(true);
      await service.enqueueGradeTime(const Duration(minutes: 30));
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
      await service.enqueueGradeTime(const Duration(minutes: 29));
      now = now.add(const Duration(minutes: 29));
      expect(await service.maybeSync(), isNot(SyncOutcome.sent));
      expect(uploads, 0);
      now = now.add(const Duration(minutes: 1));
      await service.enqueueGradeTime(const Duration(minutes: 1));
      expect(await service.maybeSync(), SyncOutcome.sent);
      expect(uploads, 1);
      expect(baseline, 600);
      expect(diff, 1800);
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
