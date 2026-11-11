import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/playlist_cache_keys.dart';

void main() {
  test('page and full-song keys use one canonical id', () {
    final playlist = PlaylistSummary(
      id: 'gid',
      title: 'Playlist',
      listId: 'list',
      sourceGlobalId: 'source-gid',
      source: 1,
    );

    expect(PlaylistCacheKeys.page(playlist), 'cache_playlist_gid');
    expect(PlaylistCacheKeys.fullSongs(playlist), 'cache_playlist_gid_full');
    expect(
      PlaylistCacheKeys.invalidationKeys(playlist),
      containsAll(<String>[
        'cache_playlist_gid',
        'cache_playlist_gid_full',
        'cache_playlist_list',
        'cache_playlist_list_full',
        'cache_playlist_source-gid',
        'cache_playlist_source-gid_full',
      ]),
    );
  });

  test('collected album keys use the album id', () {
    final album = PlaylistSummary(
      id: 'source-id',
      title: 'Album',
      musiclibId: 'album-id',
      sourceGlobalId: null,
    );

    expect(album.isCollectedAlbum, isTrue);
    expect(PlaylistCacheKeys.page(album), 'cache_album_album-id');
    expect(PlaylistCacheKeys.fullSongs(album), 'cache_album_album-id_full');
    expect(
      PlaylistCacheKeys.invalidationKeys(album),
      containsAll(<String>[
        'cache_album_album-id',
        'cache_album_album-id_full',
        'cache_playlist_album-id',
        'cache_playlist_album-id_full',
      ]),
    );
  });
}
