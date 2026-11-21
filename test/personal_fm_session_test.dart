import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/models/personal_fm_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/personal_fm_session.dart';

/// 可控的假 MusicApi：把 /personal/fm 的两次调用拆开，方便断言单飞与去重。
class _FakeApi extends MusicApi {
  _FakeApi() : super(ApiClient());

  final List<Map<String, Object?>> feedbackCalls = [];
  int fetchCount = 0;
  PersonalFmBatch nextBatch = PersonalFmBatch.empty;
  PersonalFmBatch feedbackBatch = PersonalFmBatch.empty;
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
  }) async {
    feedbackCalls.add({
      'action': action,
      'hash': hash,
      'playtime': playtimeSeconds,
      'remain': remainSongCount,
      'overplay': isOverplay,
    });
    return feedbackBatch;
  }
}

PersonalFmTrack _track(String id, {String? hash}) {
  final digest = hash ?? 'H$id';
  return PersonalFmTrack(
    song: Song(
      id: id,
      title: 'song $id',
      artist: 'artist',
      hash: digest,
      catalogId: id,
    ),
    songId: id,
  );
}

PersonalFmBatch _batch(List<String> ids) =>
    PersonalFmBatch(tracks: ids.map(_track).toList(), status: 1, errorCode: 0);

void main() {
  group('PersonalFmSession 候选与历史', () {
    test('start 拉取首批并按顺序取歌', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2', '3']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);

      final outcome = await session.start();
      expect(outcome, PersonalFmStartOutcome.started);
      expect(session.isActive, isTrue);
      expect(api.fetchCount, 1);
      expect(session.pendingCount, 3);

      final first = session.peekNext();
      expect(first!.song.id, '1');
      session.commit(first, PersonalFmTrackSource.candidate);
      expect(session.current!.song.id, '1');
      expect(session.pendingCount, 2);
    });

    test('peek 不消耗候选；commit 才消耗', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();

      expect(session.peekNext()!.song.id, '1');
      expect(session.peekNext()!.song.id, '1');
      expect(session.pendingCount, 2);
    });

    test('回听弹出历史，再前进回到暂存曲目', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2', '3']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();

      final a = session.peekNext()!;
      session.commit(a, PersonalFmTrackSource.candidate);
      final b = session.peekNext()!;
      session.commit(b, PersonalFmTrackSource.candidate);
      expect(session.current!.song.id, '2');

      final back = session.peekPrevious();
      expect(back!.song.id, '1');
      session.commit(back, PersonalFmTrackSource.history);
      expect(session.current!.song.id, '1');
      expect(session.canGoForward, isTrue);

      final forward = session.peekNext();
      expect(forward!.song.id, '2');
      session.commit(forward, PersonalFmTrackSource.restored);
      expect(session.current!.song.id, '2');
      expect(session.pendingCount, 1);
    });

    test('不喜欢从候选与回听路径排除', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();

      final a = session.peekNext()!;
      session.commit(a, PersonalFmTrackSource.candidate);
      session.dislikeCurrent();
      expect(session.peekPrevious(), isNull);
      expect(session.pendingCount, 1);
    });

    test('去重：同一曲库 ID 不会重复入池', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();
      expect(session.pendingCount, 2);

      api.nextBatch = _batch(['1', '2', '3']);
      await session.retry();
      expect(session.pendingCount, 3);
    });
  });

  group('PersonalFmSession 单飞与失败', () {
    test('并发补池共享同一次请求', () async {
      final api = _FakeApi()..nextBatch = _batch(['1']);
      final gate = Completer<void>();
      api.gate = gate;
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);

      final first = session.start();
      final second = session.start();
      gate.complete();
      await Future.wait([first, second]);
      expect(api.fetchCount, 1);
    });

    test('空批次返回 empty 而不是失败', () async {
      final api = _FakeApi()..nextBatch = PersonalFmBatch.empty;
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      expect(await session.start(), PersonalFmStartOutcome.empty);
    });

    test('请求异常返回 failed 并记录错误', () async {
      final api = _FakeApi()..fetchError = StateError('boom');
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      expect(await session.start(), PersonalFmStartOutcome.failed);
      expect(session.lastError, contains('boom'));
    });

    test('失败后进入退避，不在同一次播放里反复重试', () async {
      final api = _FakeApi()..fetchError = StateError('boom');
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();
      await session.ensureNextTrack();
      expect(api.fetchCount, 1);
    });
  });

  group('PersonalFmSession 反馈', () {
    test('反馈返回足量候选时不另发补池请求', () async {
      final api = _FakeApi()
        ..nextBatch = _batch(['1', '2', '3', '4', '5'])
        ..feedbackBatch = _batch(['5', '6', '7', '8', '9']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();
      final first = session.peekNext()!;
      session.commit(first, PersonalFmTrackSource.candidate);
      session.commit(session.peekNext()!, PersonalFmTrackSource.candidate);

      await session.reportDeparture(
        first,
        action: PersonalFmAction.play,
        playtimeSeconds: 42,
        isOverplay: true,
        canRefill: () => true,
      );

      expect(api.fetchCount, 1);
      expect(session.upcoming.map((track) => track.song.id), [
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
      ]);
    });

    test('离曲按动作上报并带上播放秒数', () async {
      final api = _FakeApi()..nextBatch = _batch(['1']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();
      final track = session.peekNext()!;
      session.commit(track, PersonalFmTrackSource.candidate);

      await session.reportDeparture(
        track,
        action: PersonalFmAction.garbage,
        playtimeSeconds: 42,
        isOverplay: false,
      );
      expect(api.feedbackCalls.single['action'], PersonalFmAction.garbage);
      expect(api.feedbackCalls.single['playtime'], 42);
      expect(api.feedbackCalls.single['overplay'], isFalse);
      expect(session.feedbackState, PersonalFmFeedbackState.synced);
    });

    test('stop 清空全部缓冲', () async {
      final api = _FakeApi()..nextBatch = _batch(['1', '2']);
      final session = PersonalFmSession(api, ownerKey: 'u', launchId: 'l');
      addTearDown(session.dispose);
      await session.start();
      final track = session.peekNext()!;
      session.commit(track, PersonalFmTrackSource.candidate);
      session.stop();
      expect(session.isActive, isFalse);
      expect(session.pendingCount, 0);
      expect(session.current, isNull);
      expect(session.peekNext(), isNull);
    });
  });

  group('PersonalFmTrack 解析', () {
    test('解析接口字段：songid、封面与秒级时长', () {
      final track = PersonalFmTrack.fromJson(<String, dynamic>{
        'songname': '爱不曾离开',
        'author_name': '袁娅维',
        'hash': 'ABC',
        'time_length': 245,
        'album_id': '81273034',
        'songid': 373220038,
        'mixsongid': '576813756',
        'singerinfo': [
          {'id': 6792, 'name': '袁娅维'},
        ],
        'trans_param': {'union_cover': 'http://img/x.jpg'},
        'rec_song_info': {'rec_desc': '正在随机推荐歌曲', 'similar_desc': '低'},
      });

      expect(track.song.title, '爱不曾离开');
      expect(track.song.hash, 'ABC');
      expect(track.song.catalogId, '576813756');
      expect(track.song.duration, const Duration(seconds: 245));
      expect(track.song.coverUrl, 'http://img/x.jpg');
      expect(track.songId, '373220038');
      expect(track.recommendDesc, '正在随机推荐歌曲');
      expect(track.dedupeKey, 'id:576813756');
    });

    test('无曲库 ID 时回落到 hash 去重', () {
      final track = PersonalFmTrack.fromJson(<String, dynamic>{
        'songname': 'x',
        'hash': 'ONLYHASH',
      });
      expect(track.dedupeKey, 'hash:ONLYHASH');
    });

    test('业务失败状态不被当作成功', () {
      final batch = PersonalFmBatch.fromJson(<String, dynamic>{
        'status': 0,
        'song_list': <dynamic>[],
      });
      expect(batch.ok, isFalse);
    });
  });
}
