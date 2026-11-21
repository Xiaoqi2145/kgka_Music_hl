import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/playback_stats_service.dart';

void main() {
  test('rankings keep songs with the same title separate by stable key', () {
    const first = Song(
      id: '1',
      title: '同名',
      artist: '甲',
      hash: 'hash-a',
      albumAudioId: '1',
      catalogId: '1',
    );
    const second = Song(
      id: '2',
      title: '同名',
      artist: '乙',
      hash: 'hash-b',
      albumAudioId: '2',
      catalogId: '2',
    );
    expect(playbackSongKey(first), isNot(playbackSongKey(second)));
    expect(cloudSongId(first), '1');
    expect(
      cloudSongId(
        const Song(
          id: 'cloud',
          title: '云盘',
          artist: '甲',
          hash: 'cloud-hash',
          isCloudDrive: true,
        ),
      ),
      isNull,
    );
  });

  test('stats deserialize display maps without losing legacy counts', () {
    final stats = PlaybackStats.fromJson({
      'totalPlays': 2,
      'totalListenMs': 3000,
      'artistPlayCount': {'甲': 2},
      'songPlayCount': {'song-a': 2},
      'songTitles': {'song-a': '同名'},
      'artistNames': {'甲': '甲'},
    });
    expect(stats.totalPlays, 2);
    expect(stats.topSongs.single.key, '同名');
    expect(stats.topSongs.single.value, 2);
    expect(stats.topArtists.single.key, '甲');
  });
}
