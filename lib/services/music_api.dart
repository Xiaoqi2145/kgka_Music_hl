import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../core/api_client.dart';
import '../models/app_version.dart';
import '../models/music_models.dart';

class MusicApi {
  MusicApi(this._client);

  static const _registerHint = '若没有账号请先在酷狗音乐概念版App注册';

  final ApiClient _client;

  /// 暴露 ApiClient 当前持有的后端 session key（由响应 header 自动保存）。
  String? get clientSessionId => _client.sessionId;

  void setSession(LoginSession? session) {
    if (session == null) {
      _client.token = null;
      _client.t1 = null;
      _client.sessionId = null;
      return;
    }
    _client.token = session.token;
    _client.t1 = session.t1;
    // 扫码/手机号登录返回的 session 不携带 sessionId，
    // 此时 _client.sessionId 已由 ApiClient._processResponse 从
    // 登录请求的响应 header (X-Kg-Session-Id) 中保存。
    // 不能用 null 覆盖，否则后续请求无法关联到后端 session，
    // 导致 /user/detail、/user/playlist 等接口拿不到登录态。
    final sid = session.sessionId;
    if (sid != null && sid.isNotEmpty) {
      _client.sessionId = sid;
    }
  }

  Future<void> sendLoginCode(String mobile) async {
    final json = asMap(
      await _client.post('/captcha/sent', query: {'mobile': mobile}),
    );
    if (!_isSuccess(json)) {
      throw ApiException('发送验证码失败，$_registerHint${_failureSuffix(json)}');
    }
  }

  Future<PhoneLoginResult> loginWithPhone({
    required String mobile,
    required String code,
    String? userId,
  }) async {
    final json = asMap(
      await _client.post(
        '/login/cellphone',
        body: {
          'mobile': mobile,
          'code': code,
          if (userId != null && userId.isNotEmpty) 'userId': userId,
        },
      ),
    );
    if (_requiresUserSelection(json)) {
      final accounts = asList(json['accounts'])
          .whereType<Map>()
          .map((item) => MobileLoginAccount.fromJson(asMap(item)))
          .where((item) => item.userId.isNotEmpty)
          .toList();
      return PhoneLoginResult.accountSelection(
        accounts: accounts,
        message:
            asString(json['message']) ?? asString(json['msg']) ?? '请选择需要登录的账号',
        errorCode: asInt(json['errorCode'] ?? json['error_code']),
      );
    }
    if (!_isSuccess(json)) {
      throw ApiException('登录失败，$_registerHint${_failureSuffix(json)}');
    }
    final session = LoginSession.fromJson(json);
    return PhoneLoginResult.success(
      LoginSession(
        userId: session.userId,
        token: session.token,
        t1: session.t1,
        sessionId: _client.sessionId,
      ),
    );
  }

  Future<LoginSession> refreshToken() async {
    final json = asMap(await _client.post('/login/token'));
    final session = LoginSession.fromJson(json);
    return LoginSession(
      userId: session.userId,
      token: session.token,
      t1: session.t1,
      sessionId: _client.sessionId,
    );
  }

  Future<void> logout() async {
    await _client.post('/login/logout');
  }

  Future<QrCodeInfo> getQrCode() async {
    final json = asMap(await _client.get('/login/qr/key'));
    return QrCodeInfo.fromJson(json);
  }

  Future<QrCheckResult> checkQrStatus(String key) async {
    final json = asMap(await _client.get('/login/qr/check', {'key': key}));
    return QrCheckResult.fromJson(json);
  }

  Future<UserProfile> userDetail() async {
    final json = asMap(await _client.get('/user/detail'));
    return UserProfile.fromJson(json);
  }

  Future<List<PlaylistSummary>> userPlaylists({
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/user/playlist', {'page': page, 'pagesize': pageSize}),
    );
    _debugPlaylistLogObject('raw response', json);
    final currentUserId = asString(json['userid']);
    final rawItems = asList(json['info']).whereType<Map<String, dynamic>>();
    _debugPlaylistLogObject(
      'raw item fields',
      rawItems
          .map(
            (item) => {
              'name': item['name'],
              'listid': item['listid'],
              'global_collection_id': item['global_collection_id'],
              'count': item['count'],
              'is_def': item['is_def'],
              'is_default': item['is_default'],
              'type': item['type'],
              'userid': item['userid'],
              'list_create_username': item['list_create_username'],
              'list_create_userid': item['list_create_userid'],
              'list_create_gid': item['list_create_gid'],
              'list_create_listid': item['list_create_listid'],
            },
          )
          .toList(),
    );
    final playlists = rawItems
        .map(
          (item) =>
              PlaylistSummary.fromUser(item, currentUserId: currentUserId),
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
    final orderedPlaylists = _orderUserPlaylistsForDisplay(playlists);
    _debugPlaylistLogObject(
      'parsed item fields',
      orderedPlaylists
          .map(
            (item) => {
              'title': item.title,
              'id': item.id,
              'songCount': item.songCount,
              'isDefault': item.isDefault,
              'type': item.type,
              'source': item.source,
              'isLikedPlaylist': item.isLikedPlaylist,
              'isCreatedPlaylist': item.isCreatedPlaylist,
              'creatorName': item.creatorName,
              'creatorUserId': item.creatorUserId,
              'currentUserId': item.currentUserId,
              'sourceGlobalId': item.sourceGlobalId,
              'sourceListId': item.sourceListId,
              'hasCollectionSource': item.hasCollectionSource,
            },
          )
          .toList(),
    );
    return orderedPlaylists;
  }

  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async {
    final json = asMap(
      await _client.get('/top/playlist', {
        'category_id': categoryId,
        'page': page,
      }),
    );
    return asList(json['special_list'])
        .whereType<Map<String, dynamic>>()
        .map(PlaylistSummary.fromRecommend)
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  Future<DailyRecommend> dailyRecommend() async {
    final json = asMap(await _client.get('/recommend/songs'));
    return DailyRecommend.fromJson(json);
  }

  Future<List<AlbumShopItem>> albumShop({
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/album/shop', {'page': page, 'pagesize': pageSize}),
    );
    return asList(json['album_list'])
        .whereType<Map<String, dynamic>>()
        .map(AlbumShopItem.fromJson)
        .where((item) => item.mediaId > 0)
        .toList();
  }

  Future<List<FmStation>> fmRecommendedStations() async {
    final raw = await _client.get('/fm/recommend');
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    return items
        .whereType<Map>()
        .map((item) => FmStation.fromJson(asMap(item)))
        .where((station) => station.id.isNotEmpty)
        .toList();
  }

  Future<List<FmClassGroup>> fmClassGroups() async {
    final raw = await _client.get('/fm/class');
    final json = asMap(raw);
    return asList(json['class_list'] ?? json['data'])
        .whereType<Map>()
        .map((item) => FmClassGroup.fromJson(asMap(item)))
        .where((group) => group.stations.isNotEmpty)
        .toList();
  }

  Future<List<Song>> fmSongs(
    FmStation station, {
    int offset = -1,
    int size = 20,
  }) async {
    final raw = await _client.get('/fm/songs', {
      'fmid': station.id,
      'type': station.type,
      'offset': offset,
      'size': size,
    });
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    final pages = items
        .whereType<Map>()
        .map((item) => FmSongPage.fromJson(asMap(item)))
        .toList();
    if (pages.isEmpty) {
      return const [];
    }
    return pages.expand((page) => page.songs).toList();
  }

  Future<Map<String, FmImage>> fmImages(List<String> fmids) async {
    final ids = fmids.where((id) => id.isNotEmpty).toSet().join(',');
    if (ids.isEmpty) {
      return const {};
    }
    final raw = await _client.get('/fm/image', {'fmid': ids});
    final items = raw is List ? raw : asList(asMap(raw)['data']);
    return {
      for (final image
          in items
              .whereType<Map>()
              .map((item) => FmImage.fromJson(asMap(item)))
              .where((image) => image.fmid.isNotEmpty))
        image.fmid: image,
    };
  }

  Future<VipReceiveHistory> vipReceiveHistory() async {
    final json = asMap(await _client.get('/youth/month/vip/record'));
    return VipReceiveHistory.fromJson(json);
  }

  Future<OneDayVipResult> dailyVip() async {
    final json = asMap(await _client.get('/youth/day/vip'));
    return OneDayVipResult.fromJson(json);
  }

  Future<UpgradeVipResult> upgradeVipReward() async {
    final json = asMap(await _client.get('/youth/day/vip/upgrade'));
    return UpgradeVipResult.fromJson(json);
  }

  Future<void> addListeningTime() async {
    await _client.post('/listen/timeadd');
  }

  Future<AppVersionInfo> latestAppVersion(AppUpdatePlatform platform) async {
    final json = asMap(
      await _client.get('/mobile/app/versions/latest', {
        'platform': platform.apiValue,
      }),
    );
    return AppVersionInfo.fromJson(json);
  }

  Future<ArtistDetail> artistDetail(String id) async {
    final json = asMap(await _client.get('/artist/detail', {'id': id}));
    return ArtistDetail.fromJson(json, id: id);
  }

  Future<List<Song>> artistAudios(
    String id, {
    int page = 1,
    int pageSize = 30,
    String sort = 'hot',
  }) async {
    final raw = await _client.get('/artist/audios', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
      'sort': sort,
    });
    _debugArtistLogObject('/artist/audios raw', raw);

    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['data'] ??
                json['songs'] ??
                json['song'] ??
                json['list'] ??
                json['info'] ??
                _firstListValue(json),
          );
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => Song.fromArtistAudio(item, artistId: id))
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  Future<SongPage> albumSongPage(
    String id, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/album/songs', {
      'id': id,
      'page': page,
      'pagesize': pageSize,
    });
    final json = asMap(raw);
    final items = raw is List
        ? raw
        : asList(
            json['songs'] ??
                json['data'] ??
                json['info'] ??
                _firstListValue(json),
          );
    final songs = items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromAlbum)
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return SongPage(songs: songs, rawItemCount: items.length);
  }

  Object? _firstListValue(Map<String, dynamic> json) {
    for (final value in json.values) {
      if (value is List) {
        return value;
      }
      if (value is Map) {
        final nested = _firstListValue(asMap(value));
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  Future<MusicCommentResponse> musicComments(
    String mixsongid, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = asMap(
      await _client.get('/comment/music', {
        'mixsongid': mixsongid,
        'page': page,
        'pagesize': pageSize,
      }),
    );
    return MusicCommentResponse.fromJson(json);
  }

  Future<PlaylistSummary> playlistInfo(String id) async {
    final json = asMap(await _client.get('/playlist/detail', {'ids': id}));
    return PlaylistSummary.fromDetail(json);
  }

  Future<List<Song>> playlistSongs(
    String id, {
    int page = 1,
    int pageSize = 80,
    bool fetchAll = false,
    bool Function()? shouldCancel,
  }) async {
    if (!fetchAll) {
      final songPage = await playlistSongPage(
        id,
        page: page,
        pageSize: pageSize,
      );
      return songPage.songs;
    }

    final allSongs = <Song>[];
    var currentPage = 1;
    const perPage = 200;
    while (true) {
      if (shouldCancel?.call() == true) break;
      final songPage = await playlistSongPage(
        id,
        page: currentPage,
        pageSize: perPage,
      );
      final songs = songPage.songs;
      if (songs.isEmpty) break;
      allSongs.addAll(songs);
      if (shouldCancel?.call() == true) break;
      if (songPage.rawItemCount < perPage) break;
      currentPage++;
    }
    return allSongs;
  }

  Future<SongPage> playlistSongPage(
    String id, {
    int page = 1,
    int pageSize = 80,
  }) async {
    final json = asMap(
      await _client.get('/playlist/track/all', {
        'id': id,
        'page': page,
        'pagesize': pageSize,
      }),
    );
    final items = asList(json['songs']);
    final songs = items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromPlaylist)
        .where((song) => song.hash.isNotEmpty)
        .toList();
    return SongPage(songs: songs, rawItemCount: items.length);
  }

  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    final json = asMap(
      await _client.get('/song/url', {
        'hash': song.hash,
        'quality': quality.apiValue,
        'album_id': song.albumId,
        'album_audio_id': song.albumAudioId,
        'free_part': false,
      }),
    );
    // 🔍 调试：检查 API 是否返回 volume 响度数据
    debugPrint('[KA Music][loudness] /song/url response keys: ${json.keys}');
    if (json.containsKey('volume')) {
      debugPrint(
        '[KA Music][loudness] volume=${json['volume']}'
        ' volume_gain=${json['volume_gain']}'
        ' volume_peak=${json['volume_peak']}',
      );
    }
    return PlayUrl.fromJson(json);
  }

  /// 获取云盘歌曲列表（分页）。
  Future<CloudDriveResult> cloudDrive({int page = 1, int pageSize = 30}) async {
    final json = asMap(
      await _client.get('/user/cloud', {'page': page, 'pagesize': pageSize}),
    );
    final info = CloudDriveInfo.fromJson(json);
    final songs = asList(json['list'])
        .whereType<Map<String, dynamic>>()
        .map(CloudDriveSongMeta.fromJson)
        .where((item) => item.song.hash.isNotEmpty)
        .map((item) => item.song)
        .toList();
    return CloudDriveResult(info: info, songs: songs);
  }

  /// 获取云盘歌曲的播放地址。
  Future<PlayUrl> cloudSongUrl(Song song) async {
    final json = asMap(
      await _client.get('/user/cloud/url', {
        'hash': song.hash,
        'album_audio_id': song.albumAudioId,
        'audio_id': song.albumAudioId,
        'name': song.title,
      }),
    );
    final url = asString(json['url']) ?? '';
    final hash = asString(json['hash']) ?? song.hash;
    return PlayUrl(url: url, hash: hash);
  }

  Future<void> createPlaylist(String name, {bool private = false}) async {
    await _client.post(
      '/playlist/create',
      query: {'name': name, 'type': private ? 1 : 0},
    );
  }

  Future<void> collectPlaylist({
    required String name,
    required String globalCollectionId,
  }) async {
    await _client.post(
      '/playlist/add',
      query: {'name': name, 'list_create_gid': globalCollectionId},
    );
  }

  Future<void> deletePlaylist(String listId) async {
    await _client.post('/playlist/del', query: {'listid': listId});
  }

  Future<void> addToPlaylist(String listId, Song song) async {
    await addSongsToPlaylist(listId, [song]);
  }

  Future<void> addSongsToPlaylist(String listId, List<Song> songs) async {
    if (songs.isEmpty) return;
    await _client.post(
      '/playlist/tracks/add',
      body: {'listId': listId, 'songs': songs.map(_songAddPayload).toList()},
    );
  }

  Future<void> removeFromPlaylist(String listId, Song song) async {
    await removeSongsFromPlaylist(listId, [song]);
  }

  Future<void> removeSongsFromPlaylist(String listId, List<Song> songs) async {
    final fileIds = songs
        .map((song) => song.id)
        .where((id) => id.isNotEmpty)
        .join(',');
    if (fileIds.isEmpty) return;
    await _client.post(
      '/playlist/tracks/del',
      query: {'listid': listId, 'fileids': fileIds},
    );
  }

  Map<String, Object?> _songAddPayload(Song song) {
    return {
      'name': song.title,
      'hash': song.hash,
      'albumId': song.albumId,
      'mixSongId': song.albumAudioId ?? song.id,
    };
  }

  bool _isSuccess(Map<String, dynamic> json) {
    return asInt(json['status']) == 1;
  }

  bool _requiresUserSelection(Map<String, dynamic> json) {
    final requiresUserSelection = json['requiresUserSelection'];
    if (requiresUserSelection is bool) {
      return requiresUserSelection;
    }
    final errorCode = asInt(json['errorCode'] ?? json['error_code']);
    final accounts = asList(json['accounts']);
    return errorCode == 34175 && accounts.isNotEmpty;
  }

  String _failureSuffix(Map<String, dynamic> json) {
    final message =
        asString(json['msg']) ??
        asString(json['message']) ??
        asString(json['errmsg']) ??
        asString(json['error']) ??
        asString(json['error_msg']);
    if (message != null) {
      return '：$message';
    }

    final errorCode =
        asString(json['error_code']) ??
        asString(json['errcode']) ??
        asString(json['code']);
    if (errorCode != null) {
      return '（错误码：$errorCode）';
    }

    return '';
  }

  Future<List<SearchHotCategory>> searchHotKeywords() async {
    final json = asMap(await _client.get('/search/hot'));
    return asList(json['list'])
        .whereType<Map<String, dynamic>>()
        .map(SearchHotCategory.fromJson)
        .toList();
  }

  Future<List<String>> searchSuggest(String keywords) async {
    final json = asMap(
      await _client.get('/search/suggest', {'keywords': keywords}),
    );
    final items = asList(json['music']);
    return items
        .whereType<Map<String, dynamic>>()
        .map((item) => asString(item['keyword']) ?? '')
        .where((k) => k.isNotEmpty)
        .toList();
  }

  Future<List<Song>> searchSongs(
    String keywords, {
    int page = 1,
    int pageSize = 30,
  }) async {
    final raw = await _client.get('/search', {
      'keywords': keywords,
      'page': page,
      'pagesize': pageSize,
      'type': 'song',
    });
    if (kDebugMode) {
      debugPrint('[KA Music][search] keywords="$keywords"');
      debugPrint('[KA Music][search] raw type: ${raw.runtimeType}');
      if (raw is List) {
        debugPrint('[KA Music][search] list length: ${raw.length}');
      } else if (raw is Map) {
        debugPrint('[KA Music][search] map keys: ${raw.keys.toList()}');
      }
    }
    // API returns either a plain array or { songs: [...] }
    final List songs;
    if (raw is List) {
      songs = raw;
    } else {
      final json = asMap(raw);
      songs = asList(json['songs'] ?? json['song'] ?? json['lists']);
    }
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Song.fromSearch)
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  /// 搜索网易云歌曲。
  ///
  /// 使用独立的网易云 API（`wyy.music.api.hoilai.cn`）：
  /// 1. 调用 `/search?keywords=xxx` 获取歌曲 ID 列表
  /// 2. 调用 `/song/detail?ids=id1,id2,...` 获取歌曲详情（名称、歌手、专辑、封面）
  Future<List<Song>> searchNetEaseSongs(
    String keywords, {
    int limit = 30,
    int offset = 0,
  }) async {
    final baseUri = Uri.parse('https://wyy.music.api.hoilai.cn');

    // 1. 搜索获取歌曲 ID
    final searchUri = baseUri.replace(
      path: '/search',
      queryParameters: {
        'keywords': keywords,
        'limit': '$limit',
        'offset': '$offset',
        'type': '1',
      },
    );
    final searchResponse = await _client.getRaw(searchUri);
    final searchJson = asMap(searchResponse);
    final rawSongs = asList(
      searchJson['result'] is Map
          ? asMap(searchJson['result'])['songs']
          : searchJson['songs'],
    );
    final ids = rawSongs
        .whereType<Map>()
        .map((item) => asInt(asMap(item)['id']))
        .whereType<int>()
        .where((id) => id > 0)
        .toList();
    if (ids.isEmpty) return const [];

    // 2. 批量获取歌曲详情
    final detailUri = baseUri.replace(
      path: '/song/detail',
      queryParameters: {'ids': ids.join(',')},
    );
    final detailResponse = await _client.getRaw(detailUri);
    final detailJson = asMap(detailResponse);
    final songsList = asList(detailJson['songs']);

    return songsList
        .whereType<Map<String, dynamic>>()
        .map((item) => NetEaseSong.fromJson(item).toSong())
        .where((song) => song.hash.isNotEmpty)
        .toList();
  }

  Future<List<LyricLine>> lyrics(Song song) async {
    _debugLyricLog(
      'request song="${song.title}" artist="${song.artist}" hash="${song.hash}" albumAudioId="${song.albumAudioId}"',
    );
    // 请求多个候选并选择解析行数最多的版本。部分后端会把片段歌词排在
    // 完整歌词前面，直接取第一项会导致播放器只显示一行。
    final candidates = await searchLyricCandidates(song);
    _debugLyricLog('lyric candidate count=${candidates.length}');
    if (candidates.isEmpty) {
      _debugLyricLog('no lyric candidate found');
      return const [];
    }

    var best = const <LyricLine>[];
    for (final candidate in candidates) {
      final lines = await lyricsFromCandidate(candidate);
      if (lines.length > best.length) {
        best = lines;
      }
    }
    return best;
  }

  Future<List<LyricCandidate>> searchLyricCandidates(Song song) async {
    final raw = await _client.get('/search/lyric', {
      'hash': song.hash,
      'album_audio_id': song.albumAudioId,
      'keywords': '${song.title} ${song.artist}',
      'keyword': '${song.title} ${song.artist}',
      'duration': song.duration?.inMilliseconds,
      // EchoMusic/API 使用 yes/no 开关返回候选列表。
      'man': 'yes',
    });
    final root = asMap(raw);
    final values = [
      root['candidates'],
      root['candidate'],
      root['list'],
      root['lyrics'],
      root['items'],
      root['info'],
      root['data'],
    ];
    final result = <LyricCandidate>[];
    void collect(Object? value) {
      if (value is List) {
        for (final item in value) collect(item);
      } else if (value is Map) {
        final candidate = LyricCandidate.fromJson(asMap(value));
        if (candidate.id.isNotEmpty && candidate.accessKey.isNotEmpty) {
          result.add(candidate);
        } else {
          for (final child in asMap(value).values) collect(child);
        }
      }
    }

    // API 在不同版本中可能直接返回数组，或把候选放在未约定名称的字段中。
    // 从根节点递归收集，避免只拿到一个摘要/片段歌词。
    collect(raw);
    for (final value in values) collect(value);
    final unique = <String, LyricCandidate>{};
    for (final candidate in result) {
      unique['${candidate.id}:${candidate.accessKey}'] = candidate;
    }
    return unique.values.toList(growable: false);
  }

  Future<List<LyricLine>> lyricsFromCandidate(LyricCandidate candidate) async {
    final map = {'id': candidate.id, 'accesskey': candidate.accessKey};
    final krc = await _lyricByFormat(map, 'krc');
    return krc.isNotEmpty ? krc : _lyricByFormat(map, 'lrc');
  }

  Future<List<LyricLine>> _lyricByFormat(
    Map<String, dynamic> candidate,
    String format,
  ) async {
    final id =
        asString(candidate['id']) ??
        asString(candidate['lyrics_id']) ??
        asString(candidate['lyric_id']) ??
        asString(candidate['lyricid']);
    final accessKey =
        asString(candidate['accesskey']) ??
        asString(candidate['access_key']) ??
        asString(candidate['accessKey']);
    if (id == null || accessKey == null) {
      return const [];
    }

    final result = asMap(
      await _client.get('/lyric', {
        'id': id,
        'accesskey': accessKey,
        'fmt': format,
        'decode': true,
      }),
    );
    _debugLyricLogObject('$format lyric response keys', result.keys.toList());

    final translationContent = asString(result['decodedTranslation']);
    final candidates = [
      asString(result['decodedContent']),
      asString(result['rawContent']),
      asString(result['content']),
    ].whereType<String>().toList();
    _debugLyricLog('$format content candidate count=${candidates.length}');

    candidates.sort((a, b) {
      final score = _lyricContentScore(b).compareTo(_lyricContentScore(a));
      return score != 0 ? score : b.length.compareTo(a.length);
    });
    var best = const <LyricLine>[];
    for (var index = 0; index < candidates.length; index++) {
      final content = candidates[index];
      _debugLyricContent(
        '$format content[$index] score=${_lyricContentScore(content)} length=${content.length}',
        content,
      );
      if (translationContent != null) {
        _debugLyricContent(
          '$format decodedTranslation length=${translationContent.length}',
          translationContent,
        );
      }
      final lines = parseLyrics(
        content,
        translationContent: translationContent,
      );
      _debugLyricLog('$format content[$index] parsed lines=${lines.length}');
      if (lines.length > best.length) {
        best = lines;
      }
    }
    _debugLyricLog('$format lyric parsed lines=${best.length}');
    return best;
  }
}

List<PlaylistSummary> _orderUserPlaylistsForDisplay(
  List<PlaylistSummary> playlists,
) {
  if (playlists.length <= 2) {
    return playlists;
  }
  return [...playlists.take(2), ...playlists.skip(2).toList().reversed];
}

List<LyricLine> parseLyrics(String? content, {String? translationContent}) {
  if (content == null || content.trim().isEmpty) {
    return const [];
  }

  final normalized = content
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n');
  final krcLines = _parseKrc(normalized);
  final parsed = krcLines.isNotEmpty ? krcLines : _parseLrc(normalized);
  if (parsed.isEmpty) {
    return const [];
  }
  // 署名/水印/标题卡等非歌词行不删除——删除会使主歌词与翻译轨的行号错开。
  // 打上 hidden 标记保留原位，由 UI 层隐藏，行号与翻译轨保持一一对应。
  final lyricLines = _markHiddenLyricLines(parsed);

  final variants = _parseLyricVariants(
    translationContent: translationContent,
    originalContent: normalized,
  );
  return _mergeLyricVariants(lyricLines, variants);
}

/// LLM/翻译工具在歌词或翻译轨道开头插入的水印署名行，
/// 如 "以下歌词翻译由文曲大模型提供"、"翻译由文曲大模型生成"。
final _lyricAttributionPattern = RegExp(
  '('
  r'^(以下|下述|本).*(翻译|译文|音译|罗马音|罗马字|拼音)'
  r'|(歌词)?(翻译|译文|音译|罗马音|罗马字|拼音)(内容)?(由|来自).{1,32}'
  r'(提供|生成|完成|输出|制作)[。.!！?？]?\s*$'
  ')',
);

bool _isLyricAttributionText(String text) {
  final normalized = text.trim();
  return normalized.isNotEmpty && _lyricAttributionPattern.hasMatch(normalized);
}

List<LyricLine> _markHiddenLyricLines(List<LyricLine> lines) {
  return [
    for (var index = 0; index < lines.length; index++)
      if (_looksLikeLeadingTitleCredit(lines, index))
        lines[index].copyWith(hidden: true, titleCard: true)
      else if (_isLyricMetadataText(lines[index].text))
        lines[index].copyWith(hidden: true)
      else
        lines[index],
  ];
}

List<LyricLine> _parseKrc(String content) {
  final lines = <LyricLine>[];
  final offset = _extractOffset(content);
  final lineExpression = RegExp(r'^\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\](.*)$');
  final wordExpression = RegExp(r'<\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*>');

  for (final rawLine in content.split('\n')) {
    final match = lineExpression.firstMatch(rawLine.trim());
    if (match == null) {
      continue;
    }

    final start = int.tryParse(match.group(1) ?? '');
    final duration = int.tryParse(match.group(2) ?? '');
    if (start == null || duration == null) {
      continue;
    }

    final content = match.group(3) ?? '';
    final words = <LyricWord>[];
    final matches = wordExpression.allMatches(content).toList();
    for (var index = 0; index < matches.length; index++) {
      final wordMatch = matches[index];
      final wordStart = int.tryParse(wordMatch.group(1) ?? '') ?? 0;
      final wordDuration = int.tryParse(wordMatch.group(2) ?? '') ?? 0;
      final wordEnd = index + 1 < matches.length
          ? matches[index + 1].start
          : content.length;
      final wordText = content.substring(wordMatch.end, wordEnd);
      if (wordText.isEmpty) {
        continue;
      }
      words.add(
        LyricWord(
          time: Duration(
            milliseconds: (start + wordStart + offset)
                .clamp(0, 1 << 31)
                .toInt(),
          ),
          duration: Duration(
            milliseconds: wordDuration.clamp(0, 1 << 31).toInt(),
          ),
          text: wordText,
        ),
      );
    }

    final displayWords = _trimLyricWords(words);
    final text = displayWords.isEmpty
        ? content.replaceAll(wordExpression, '').trim()
        : displayWords.map((word) => word.text).join();
    if (text.isEmpty) {
      continue;
    }

    lines.add(
      LyricLine(
        time: Duration(
          milliseconds: (start + offset).clamp(0, 1 << 31).toInt(),
        ),
        duration: Duration(milliseconds: duration.clamp(0, 1 << 31).toInt()),
        text: text,
        words: displayWords,
      ),
    );
  }

  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

List<LyricWord> _trimLyricWords(List<LyricWord> words) {
  final result = words
      .map(
        (word) => LyricWord(
          time: word.time,
          duration: word.duration,
          text: word.text,
        ),
      )
      .toList();
  while (result.isNotEmpty && result.first.text.trim().isEmpty) {
    result.removeAt(0);
  }
  while (result.isNotEmpty && result.last.text.trim().isEmpty) {
    result.removeLast();
  }
  if (result.isEmpty) {
    return result;
  }
  result[0] = LyricWord(
    time: result[0].time,
    duration: result[0].duration,
    text: result[0].text.trimLeft(),
  );
  final lastIndex = result.length - 1;
  result[lastIndex] = LyricWord(
    time: result[lastIndex].time,
    duration: result[lastIndex].duration,
    text: result[lastIndex].text.trimRight(),
  );
  return result.where((word) => word.text.isNotEmpty).toList();
}

List<LyricLine> _parseLrc(String content) {
  final lines = <LyricLine>[];
  final offset = _extractOffset(content);
  final expression = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final rawLine in content.split('\n')) {
    final matches = expression.allMatches(rawLine).toList();
    if (matches.isEmpty) {
      continue;
    }
    final text = rawLine.replaceAll(expression, '').trim();
    if (text.isEmpty) {
      continue;
    }
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
      final fraction = match.group(3) ?? '0';
      final milliseconds = fraction.length == 3
          ? int.parse(fraction)
          : int.parse(fraction.padRight(3, '0'));
      lines.add(
        LyricLine(
          time: Duration(
            milliseconds:
                (Duration(
                          minutes: minutes,
                          seconds: seconds,
                          milliseconds: milliseconds,
                        ).inMilliseconds +
                        offset)
                    .clamp(0, 1 << 31)
                    .toInt(),
          ),
          text: text,
        ),
      );
    }
  }

  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

int _extractOffset(String content) {
  final match = RegExp(
    r'^\[offset:([+-]?\d+)\]',
    multiLine: true,
  ).firstMatch(content);
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}

int _lyricContentScore(String content) {
  var score = 0;
  if (RegExp(
    r'^\[\s*-?\d+\s*,\s*-?\d+\s*\].*<',
    multiLine: true,
  ).hasMatch(content)) {
    score += 100;
  }
  if (RegExp(
    r'^\[\s*-?\d+\s*,\s*-?\d+\s*\]',
    multiLine: true,
  ).hasMatch(content)) {
    score += 60;
  }
  if (RegExp(r'\[\d{1,2}:\d{1,2}').hasMatch(content)) {
    score += 40;
  }
  if (content.contains('[language:')) {
    score += 10;
  }
  return score;
}

_ParsedLyricVariants _parseLyricVariants({
  required String? translationContent,
  required String originalContent,
}) {
  final decodedTranslation = _parseTimedVariant(translationContent);
  final krcVariants = _parseKrcLanguageVariants(originalContent);
  return _ParsedLyricVariants(
    translation: !decodedTranslation.isEmpty
        ? decodedTranslation
        : krcVariants.translation,
    romanization: krcVariants.romanization,
  );
}

_TimedLyricVariant _parseTimedVariant(String? content) {
  final lines = _removeLyricMetadataLines(parseLyrics(content));
  return _TimedLyricVariant(
    byTime: {
      for (final line in lines)
        if (line.text.isNotEmpty) line.time.inMilliseconds: line.text,
    },
  );
}

_ParsedLyricVariants _parseKrcLanguageVariants(String content) {
  final match = RegExp(
    r'^\[language:([A-Za-z0-9+/=]+)\]',
    multiLine: true,
  ).firstMatch(content);
  final encoded = match?.group(1);
  if (encoded == null || encoded.isEmpty) {
    return const _ParsedLyricVariants();
  }

  try {
    final decoded = utf8.decode(base64.decode(encoded));
    final json = jsonDecode(decoded);
    final translationByTime = <int, String>{};
    final translationByIndex = <String>[];
    final romanizationByTime = <int, String>{};
    final romanizationByIndex = <String>[];
    _collectKrcLanguageRows(
      json,
      translationByTime: translationByTime,
      translationByIndex: translationByIndex,
      romanizationByTime: romanizationByTime,
      romanizationByIndex: romanizationByIndex,
    );
    final cleanedTranslationByTime = _removeLyricMetadataFromTimedMap(
      translationByTime,
    );
    final cleanedRomanizationByTime = _removeLyricMetadataFromTimedMap(
      romanizationByTime,
    );
    // 按行号对齐的翻译行不做任何过滤：每行主歌词（含标题卡/署名行）在
    // 翻译轨里都有自己的一行（未翻译为空串占位），过滤会使行号错位。
    return _ParsedLyricVariants(
      translation: _TimedLyricVariant(
        byTime: cleanedTranslationByTime,
        byIndex: translationByIndex,
      ),
      romanization: _TimedLyricVariant(
        byTime: cleanedRomanizationByTime,
        byIndex: romanizationByIndex,
      ),
    );
  } catch (_) {
    return const _ParsedLyricVariants();
  }
}

/// 歌词接口有时会把歌曲标题、歌手和制作信息编码成带时间戳的歌词行。
/// 这些行不能参与翻译/音译对齐，否则同一时间点的元数据会覆盖第一句歌词。
List<LyricLine> _removeLyricMetadataLines(List<LyricLine> lines) {
  return [
    for (var index = 0; index < lines.length; index++)
      if (!_isLyricMetadataText(lines[index].text) &&
          !_looksLikeLeadingTitleCredit(lines, index))
        lines[index],
  ];
}

Map<int, String> _removeLyricMetadataFromTimedMap(Map<int, String> values) {
  return Map.fromEntries(
    values.entries.where((entry) => !_isLyricMetadataText(entry.value)),
  );
}

void _collectKrcLanguageRows(
  Object? value, {
  required Map<int, String> translationByTime,
  required List<String> translationByIndex,
  required Map<int, String> romanizationByTime,
  required List<String> romanizationByIndex,
}) {
  if (value is List) {
    for (final item in value) {
      _collectKrcLanguageRows(
        item,
        translationByTime: translationByTime,
        translationByIndex: translationByIndex,
        romanizationByTime: romanizationByTime,
        romanizationByIndex: romanizationByIndex,
      );
    }
    return;
  }
  if (value is! Map) {
    return;
  }

  final map = asMap(value);
  final sectionType = asInt(map['type']);
  final lyricContent = map['lyricContent'];
  if (lyricContent is List) {
    for (final row in lyricContent) {
      final parsedRow = _parseKrcLanguageRow(row, sectionType);
      if (parsedRow == null) {
        continue;
      }

      final byTime = sectionType == 0 ? romanizationByTime : translationByTime;
      final byIndex = sectionType == 0
          ? romanizationByIndex
          : translationByIndex;

      if (parsedRow.time != null) {
        // 时间轨按时间对齐，空行没有意义，跳过以免遮蔽同时间的翻译。
        if (parsedRow.text.isNotEmpty) {
          byTime[parsedRow.time!] = parsedRow.text;
        }
      } else {
        // 行号轨不过滤：署名/标题卡行与未翻译的空串行都占一个行位，
        // 丢弃会使后续行整体错位。
        byIndex.add(parsedRow.text);
      }
    }
  }

  for (final child in map.values) {
    if (child is List || child is Map) {
      _collectKrcLanguageRows(
        child,
        translationByTime: translationByTime,
        translationByIndex: translationByIndex,
        romanizationByTime: romanizationByTime,
        romanizationByIndex: romanizationByIndex,
      );
    }
  }
}

({int? time, String text})? _parseKrcLanguageRow(
  Object? row,
  int? sectionType,
) {
  if (row is! List || row.isEmpty) {
    return null;
  }

  final time = row.length > 1 ? asInt(row[0]) : null;
  final values = row.map(asString).whereType<String>().toList();
  if (time == null && values.isEmpty) {
    // 整行都是空串/空白：未翻译的占位行，保留空文本占住行号位。
    return (time: null, text: '');
  }

  final text = time != null && row.length > 1
      ? asString(row[1])
      : (sectionType == 0 ? values.join('') : values.join(' ').trim());
  // 空文本行是合法的占位行（未翻译的署名/标题卡行位），不能丢弃。
  if (text == null) {
    return null;
  }
  return (time: time, text: text);
}

List<LyricLine> _mergeLyricVariants(
  List<LyricLine> lines,
  _ParsedLyricVariants variants,
) {
  if (variants.isEmpty) {
    return lines;
  }

  final indexedTranslations = _indexedLyricVariants(
    lines,
    variants.translation,
  );
  final indexedRomanizations = _indexedLyricVariants(
    lines,
    variants.romanization,
  );
  final merged = <LyricLine>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    // 署名/标题卡/水印等隐藏行不挂翻译/音译：它们与首句时间相近，
    // 时间匹配会错误挂上首句翻译；锁定对齐时它们照常消耗自己的行位。
    if (line.hidden) {
      merged.add(line);
      continue;
    }
    merged.add(
      line.copyWith(
        translation:
            variants.translation.byTime[line.time.inMilliseconds] ??
            _nearestLyricVariant(
              line.time.inMilliseconds,
              variants.translation.byTime,
            ) ??
            indexedTranslations[index],
        romanization:
            variants.romanization.byTime[line.time.inMilliseconds] ??
            _nearestLyricVariant(
              line.time.inMilliseconds,
              variants.romanization.byTime,
            ) ??
            indexedRomanizations[index],
      ),
    );
  }
  return merged;
}

Map<int, String> _indexedLyricVariants(
  List<LyricLine> lines,
  _TimedLyricVariant variant,
) {
  if (variant.byIndex.isEmpty) {
    return const {};
  }

  // 按行号与主歌词锁定对齐：KRC language 轨的每一行主歌词（含标题卡/
  // 署名行）都有自己的一行，未翻译的行是空串占位。隐藏行照常消耗行位，
  // 保持后续行对齐。唯一例外是 LLM 插在翻译轨顶部的水印行——它没有
  // 对应的歌词槽位，配到非隐藏行时直接丢弃。
  final result = <int, String>{};
  var lineIndex = 0;
  var rowCursor = 0;
  while (lineIndex < lines.length && rowCursor < variant.byIndex.length) {
    final rowText = variant.byIndex[rowCursor].trim();
    if (_isLyricAttributionText(rowText) && !lines[lineIndex].hidden) {
      rowCursor++;
      continue;
    }
    rowCursor++;
    final line = lines[lineIndex];
    if (rowText.isNotEmpty && !_sameLyricText(line.text, rowText)) {
      result[lineIndex] = rowText;
    }
    lineIndex++;
  }

  return result;
}

bool _looksLikeLeadingTitleCredit(List<LyricLine> lines, int index) {
  if (index > 2) {
    return false;
  }
  final text = lines[index].text;
  if (_isTitleCardText(text) && _hasTitleCardTiming(lines, index)) {
    return true;
  }
  final looksLikeTitle =
      RegExp(r'\s[-–—]\s').hasMatch(text) || text.contains('/');
  if (!looksLikeTitle) {
    return false;
  }
  return lines
      .skip(index + 1)
      .take(6)
      .any((line) => _isLyricMetadataText(line.text));
}

/// 形如 "歌名 - 歌手" / "歌手-歌名" 的标题卡文本：
/// 只有一个分隔符、两侧非空、无句末标点且整体较短。
/// 部分歌词的标题卡后面没有任何署名行，此时只能靠文本与时序特征识别。
final _titleCardSpacedSeparator = RegExp(r'\s[-–—]\s');
final _titleCardMixedScriptSeparator = RegExp(
  '[A-Za-z0-9][-–—][\u3040-\u30FF\u3400-\u9FFF\uF900-\uFAFF]'
  '|[\u3040-\u30FF\u3400-\u9FFF\uF900-\uFAFF][-–—][A-Za-z0-9]',
);

bool _isTitleCardText(String text) {
  final normalized = text.trim();
  if (normalized.isEmpty || normalized.length > 60) {
    return false;
  }
  if (RegExp(r'[。．.!！?？,，、;；~～]+$').hasMatch(normalized)) {
    return false;
  }
  final spaced = _titleCardSpacedSeparator.allMatches(normalized).toList();
  if (spaced.length == 1) {
    final left = normalized.substring(0, spaced.first.start).trim();
    final right = normalized.substring(spaced.first.end).trim();
    return left.isNotEmpty && right.isNotEmpty;
  }
  if (spaced.isNotEmpty) {
    return false;
  }
  // 无空格连字符仅在两侧脚本不同时视为标题（如 "Ending Note-門谷純"）。
  return RegExp(r'[-–—]').allMatches(normalized).length == 1 &&
      _titleCardMixedScriptSeparator.hasMatch(normalized);
}

/// 标题卡通常出现在歌曲开头并横跨前奏：起点在 10 秒内，
/// 且自身时长或与下一行的时间间隔达到 8 秒。
/// 时序证据用来排除 "Wow - oh" 这类含连字符的真实歌词首行。
bool _hasTitleCardTiming(List<LyricLine> lines, int index) {
  final line = lines[index];
  final start = line.time.inMilliseconds;
  if (start > 10000) {
    return false;
  }
  final duration = line.duration?.inMilliseconds ?? 0;
  if (duration >= 8000) {
    return true;
  }
  if (index + 1 >= lines.length) {
    return false;
  }
  final gap = lines[index + 1].time.inMilliseconds - (start + duration);
  return gap >= 8000;
}

/// 署名前缀中常见繁体/日文汉字到简体的映射，
/// 使 "作詞"（繁体/日文）与 "作词"（简体）命中同一词表。
const _creditPrefixSimplified = {
  '詞': '词',
  '編': '编',
  '製': '制',
  '發': '发',
  '劃': '划',
  '監': '监',
  '統': '统',
  '籌': '筹',
  '權': '权',
  '錄': '录',
  '師': '师',
  '帶': '带',
  '聲': '声',
  '貝': '贝',
  '鍵': '键',
  '盤': '盘',
  '樂': '乐',
  '藝': '艺',
};

String _simplifyCreditPrefix(String prefix) {
  final buffer = StringBuffer();
  for (final rune in prefix.runes) {
    if (rune <= 0xFFFF) {
      final char = String.fromCharCode(rune);
      buffer.write(_creditPrefixSimplified[char] ?? char);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

bool _isLyricMetadataText(String text) {
  final normalized = text.trim();
  if (_isLyricAttributionText(normalized)) {
    return true;
  }
  final colonIndex = normalized.indexOf(RegExp(r'[:：]'));
  // 40 覆盖最长的英文复合署名前缀（如 "recording and mixing engineers"）。
  if (colonIndex < 0 || colonIndex > 40) {
    return false;
  }

  final prefix = normalized
      .substring(0, colonIndex)
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');
  if (prefix.isEmpty) {
    return false;
  }
  final simplifiedPrefix = _simplifyCreditPrefix(prefix);

  const prefixes = {
    '词',
    '曲',
    '作词',
    '填词',
    '作曲',
    '词曲',
    '编曲',
    '演唱',
    '歌手',
    '翻译',
    '译文',
    '音译',
    '罗马音',
    '罗马字',
    '拼音',
    '艺人',
    '原唱',
    '翻唱',
    '制作',
    '制作人',
    '出品',
    '发行',
    '企划',
    '监制',
    '统筹',
    '版权',
    '录音',
    '录音师',
    '录音室',
    '混音',
    '混音师',
    '混音室',
    '母带',
    '母带师',
    '母带室',
    '和声',
    '和声编写',
    '和声编配',
    '配唱',
    '吉他',
    '贝斯',
    '鼓',
    '键盘',
    '弦乐',
    '乐器独奏',
    '演奏',
    '录制',
    '人声',
    '助理',
    'op',
    'sp',
    'cp',
    'isrc',
    'upc',
    'vocal',
    'vocals',
    'translation',
    'translated by',
    'lyric',
    'lyrics',
    'lyricist',
    'composer',
    'arranger',
    'producer',
    'produced by',
    'mix',
    'mixing',
    'mixed',
    'master',
    'mastering',
    'mastered',
    'recording',
    'guitar',
    'bass',
    'drums',
    'piano',
    'strings',
    'keyboard',
    'keyboards',
    'percussion',
    'synth',
    'synthesizer',
    'orchestra',
    'chorus',
    'programming',
    'engineer',
    'engineers',
    'recording engineer',
    'recording engineers',
    'mixing engineer',
    'mixing engineers',
    'recording & mixing engineer',
    'recording & mixing engineers',
    'recording and mixing engineer',
    'recording and mixing engineers',
    'publisher',
    'copyright',
  };
  if (prefixes.contains(simplifiedPrefix)) {
    return true;
  }

  // 复合/双语署名前缀，如 "词 Lyricist"、"作词/作曲"：
  // 空格、斜杠或 & 分隔的每一段都是已知署名词时视为元数据。
  final segments = simplifiedPrefix
      .split(RegExp(r'[\s/&+]+'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.length > 1 && segments.every(prefixes.contains)) {
    return true;
  }

  // Some KRC files use compound production credits such as
  // "Recording&Mixing Engineers" or bilingual forms such as
  // "和声编写 Voicing Arrangement" / "出品 Produced by".
  final compactPrefix = simplifiedPrefix.replaceAll(RegExp(r'[\s&+/_-]+'), '');
  const productionRoleTokens = {
    'recording',
    'mixing',
    'mastering',
    'engineer',
    'engineers',
    'producer',
    'produced',
    'arranger',
    'arrangement',
    'instrument',
    'supervisor',
    'assistant',
    'recorded',
    'translated',
    'editing',
    'written',
    'director',
    'executive',
    'coordinator',
    'planning',
  };
  return productionRoleTokens.any(compactPrefix.contains);
}

bool _sameLyricText(String a, String b) {
  return _compactLyricText(a) == _compactLyricText(b);
}

String _compactLyricText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    if (_isHanRune(rune) ||
        _isKanaRune(rune) ||
        _isHangulRune(rune) ||
        _isLatinRune(rune) ||
        (rune >= 0x30 && rune <= 0x39)) {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

bool _isHanRune(int rune) {
  return (rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff) ||
      (rune >= 0xf900 && rune <= 0xfaff);
}

bool _isKanaRune(int rune) {
  return (rune >= 0x3040 && rune <= 0x30ff) ||
      (rune >= 0x31f0 && rune <= 0x31ff);
}

bool _isHangulRune(int rune) {
  return (rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0x3130 && rune <= 0x318f) ||
      (rune >= 0xac00 && rune <= 0xd7af);
}

bool _isLatinRune(int rune) {
  return (rune >= 0x41 && rune <= 0x5a) || (rune >= 0x61 && rune <= 0x7a);
}

String? _nearestLyricVariant(int time, Map<int, String> variants) {
  var bestDistance = 1 << 31;
  String? bestText;
  for (final entry in variants.entries) {
    final distance = (entry.key - time).abs();
    if (distance < bestDistance && distance <= 250) {
      bestDistance = distance;
      bestText = entry.value;
    }
  }
  return bestText;
}

class _ParsedLyricVariants {
  const _ParsedLyricVariants({
    this.translation = const _TimedLyricVariant(),
    this.romanization = const _TimedLyricVariant(),
  });

  final _TimedLyricVariant translation;
  final _TimedLyricVariant romanization;

  bool get isEmpty => translation.isEmpty && romanization.isEmpty;
}

class _TimedLyricVariant {
  const _TimedLyricVariant({this.byTime = const {}, this.byIndex = const []});

  final Map<int, String> byTime;
  final List<String> byIndex;

  bool get isEmpty => byTime.isEmpty && byIndex.isEmpty;
}

void _debugLyricLog(String message) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  debugPrint('[KA Music][lyrics] $message');
}

void _debugLyricLogObject(String label, Object? value) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert(value);
  _debugLyricContent(label, text);
}

void _debugLyricContent(String label, String content) {
  if (!AppConfig.debugLyrics || !kDebugMode) {
    return;
  }
  debugPrint('[KA Music][lyrics] ==== $label ====');
  const chunkSize = 1800;
  for (var start = 0; start < content.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, content.length);
    debugPrint(content.substring(start, end));
  }
  debugPrint('[KA Music][lyrics] ==== end $label ====');
}

void _debugPlaylistLogObject(String label, Object? value) {
  if (!kDebugMode) {
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert(value);
  debugPrint('[KA Music][playlists] ==== $label ====');
  const chunkSize = 1800;
  for (var start = 0; start < text.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, text.length);
    debugPrint(text.substring(start, end));
  }
  debugPrint('[KA Music][playlists] ==== end $label ====');
}

void _debugArtistLogObject(String label, Object? value) {
  if (!kDebugMode) {
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert(value);
  debugPrint('[KA Music][artist] ==== $label ====');
  const chunkSize = 1800;
  for (var start = 0; start < text.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, text.length);
    debugPrint(text.substring(start, end));
  }
  debugPrint('[KA Music][artist] ==== end $label ====');
}
