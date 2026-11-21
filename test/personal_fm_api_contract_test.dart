import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/personal_fm_models.dart';

/// 真实响应样本（来自默认 API 的一次 /personal/fm?action=login 调用），
/// 只保留解析所需的字段，用于锁住「接口字段 -> 播放输入」的映射。
const _sample = '''
{
  "song_list": [
    {
      "songname": "谁会被吻 (天气说变冷就变冷)",
      "author_name": "陆政廷Lil Jet",
      "hash": "C8483C1246D22453B4ABB85FD0DCA398",
      "time_length": 181,
      "album_id": "61962429",
      "songid": 263421754,
      "mixsongid": "448263005",
      "singerinfo": [{"id": 598454, "name": "陆政廷Lil Jet"}],
      "trans_param": {"union_cover": "http://imge.kugou.com/stdmusic/400/x.jpg"},
      "rec_song_info": {"similar_desc": "低", "rec_desc": "正在随机推荐歌曲"}
    }
  ],
  "mode": "normal",
  "status": 1,
  "error_code": 0,
  "cur_mark": "99999998"
}''';

void main() {
  test('真实 FM 响应可解析为播放输入', () {
    final batch = PersonalFmBatch.fromJson(
      jsonDecode(_sample) as Map<String, dynamic>,
    );
    expect(batch.ok, isTrue);
    expect(batch.tracks, hasLength(1));
    expect(batch.curMark, '99999998');

    final track = batch.tracks.single;
    expect(track.song.hash, 'C8483C1246D22453B4ABB85FD0DCA398');
    expect(track.song.title, '谁会被吻 (天气说变冷就变冷)');
    expect(track.song.artist, '陆政廷Lil Jet');
    expect(track.song.albumId, '61962429');
    expect(track.song.albumAudioId, '448263005');
    expect(track.song.duration, const Duration(seconds: 181));
    expect(track.song.coverUrl, contains('kugou'));
    expect(track.songId, '263421754');
  });

  test('缺 hash 的条目在解析阶段就被丢弃', () {
    final batch = PersonalFmBatch.fromJson(<String, dynamic>{
      'status': 1,
      'song_list': <dynamic>[
        <String, dynamic>{'songname': 'no hash' },
        <String, dynamic>{'songname': 'ok', 'hash': 'H1'},
      ],
    });
    expect(batch.tracks, hasLength(1));
    expect(batch.tracks.single.song.hash, 'H1');
  });

  test('recommendDesc 缺失时不影响播放字段', () {
    final batch = PersonalFmBatch.fromJson(<String, dynamic>{
      'status': 1,
      'song_list': <dynamic>[
        <String, dynamic>{'songname': 'a', 'hash': 'H2' },
      ],
    });
    expect(batch.tracks.single.recommendDesc, isNull);
    expect(batch.tracks.single.song.title, 'a');
  });
}
