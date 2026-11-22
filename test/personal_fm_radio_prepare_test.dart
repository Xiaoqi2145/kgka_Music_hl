import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/models/personal_fm_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/personal_fm_session.dart';

/// 可控的假 MusicApi：只覆盖推荐与反馈两条链路。
class _FakeApi extends MusicApi {
  _FakeApi() : super(ApiClient());

  int fetchCount = 0;
  PersonalFmBatch nextBatch = PersonalFmBatch.empty;
  Object? fetchError;
  Completer<void>? gate;

  @override
  Future<PersonalFmBatch> personalFm({
    PersonalFmMode mode = PersonalFmMode.normal,
    int songPoolId = 0,
    String? hash,
    String? songId,
    int? playtimeSeconds,
    bool isOverplay = false,
    int remainSongCount = 0,
  }) async {
    fetchCount++;
    final waiting = gate;
    if (waiting != null) await waiting.future;
    final error = fetchError;
    if (error != null) throw error;
    return nextBatch;
  }

  @override
  Future<PersonalFmBatch> personalFmFeedback({
    required PersonalFmAction action,
    required String hash,
    String? songId,
    required int playtimeSeconds,
    required int remainSongCount,
    bool isOverplay = false,
    PersonalFmMode mode = PersonalFmMode.normal,
    int songPoolId = 0,
  }) async => PersonalFmBatch.empty;
}

PersonalFmTrack _track(String id) => PersonalFmTrack(
  song: Song(
    id: id,
    title: 'song $id',
    artist: 'artist',
    hash: 'H$id',
    catalogId: id,
  ),
  songId: id,
);

PersonalFmBatch _batch(List<String> ids) =>
    PersonalFmBatch(tracks: ids.map(_track).toList(), status: 1, errorCode: 0);

void main() {
  group('电台页准备候选（不自动开播）', () {
    test('空池时取一批推荐，但不激活会话、不选曲', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2', '3']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);

      expect(session.isActive, isFalse);
      expect(session.hasCandidates, isFalse);

      final ok = await session.ensureRecommendations();

      expect(ok, isTrue);
      expect(api.fetchCount, 1);
      expect(session.hasCandidates, isTrue);
      expect(session.isActive, isFalse);
      expect(session.current, isNull);
    });

    test('已有候选时再次进入不重复请求', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.ensureRecommendations();

      await session.ensureRecommendations();

      expect(api.fetchCount, 1);
    });

    test('并发进入共享同一次请求（单飞）', () async {
      final api = _FakeApi()..nextBatch = _batch(['1']);
      final gate = Completer<void>();
      api.gate = gate;
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);

      final a = session.ensureRecommendations();
      final b = session.ensureRecommendations();
      gate.complete();
      await Future.wait([a, b]);

      expect(api.fetchCount, 1);
    });

    test('失败后沿用退避：状态未变不会为页面打开反复请求', () async {
      final api = _FakeApi()..fetchError = StateError('boom');
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);

      expect(await session.ensureRecommendations(), isFalse);
      expect(await session.ensureRecommendations(), isFalse);
      expect(api.fetchCount, 1);

      // 用户重试才重新请求。
      api.fetchError = null;
      api.nextBatch = _batch(['1']);
      expect(await session.retryRecommendations(), isTrue);
      expect(api.fetchCount, 2);
    });

    test('activateForBrowsing 让已准备的候选可被 peek，空池返回 false', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);

      expect(session.activateForBrowsing(), isFalse);
      await session.ensureRecommendations();
      expect(session.activateForBrowsing(), isTrue);
      expect(session.isActive, isTrue);
      expect(session.peekNext()!.song.id, '1');
    });
  });

  group('点选候选后的待播顺序', () {
    test('被选歌曲之后的候选排在前面，原本在前的移到末尾', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2', '3', '4', '5']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.ensureRecommendations();
      session.activateForBrowsing();

      final third = session.upcoming.elementAt(2);
      expect(third.song.id, '3');

      session.commit(third, PersonalFmTrackSource.candidate);

      expect(session.current!.song.id, '3');
      expect(session.upcoming.map((t) => t.song.id), ['4', '5', '1', '2']);
    });

    test('点选靠后的候选不会回跳到未播候选', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2', '3', '4', '5']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.ensureRecommendations();
      session.activateForBrowsing();

      session.commit(session.upcoming.last, PersonalFmTrackSource.candidate);

      expect(session.current!.song.id, '5');
      expect(session.peekNext()!.song.id, '1');
      expect(session.upcoming.length, 4);
    });
  });
}
