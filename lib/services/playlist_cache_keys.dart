import '../models/music_models.dart';

const String fullSongsCacheSuffix = '_full';

/// Cache keys shared by the playlist detail reader and mutation invalidation.
class PlaylistCacheKeys {
  const PlaylistCacheKeys._();

  static String _id(PlaylistSummary playlist) =>
      playlist.albumId ?? playlist.id;

  static String page(PlaylistSummary playlist) {
    return playlist.isCollectedAlbum
        ? 'cache_album_${_id(playlist)}'
        : 'cache_playlist_${playlist.id}';
  }

  static String fullSongs(PlaylistSummary playlist) =>
      '${page(playlist)}$fullSongsCacheSuffix';

  /// Every legacy identifier that may have produced a cache key for a playlist.
  static Iterable<String> invalidationKeys(PlaylistSummary playlist) {
    final ids = <String>{
      playlist.id,
      if (playlist.listId?.isNotEmpty == true) playlist.listId!,
      if (playlist.sourceGlobalId?.isNotEmpty == true) playlist.sourceGlobalId!,
      if (playlist.sourceListId?.isNotEmpty == true) playlist.sourceListId!,
      if (playlist.musiclibId?.isNotEmpty == true) playlist.musiclibId!,
      if (playlist.albumId?.isNotEmpty == true) playlist.albumId!,
    }..removeWhere((id) => id.isEmpty);
    return ids.expand(
      (id) => [
        'cache_playlist_$id',
        'cache_playlist_$id$fullSongsCacheSuffix',
        'cache_album_$id',
        'cache_album_$id$fullSongsCacheSuffix',
      ],
    );
  }
}
