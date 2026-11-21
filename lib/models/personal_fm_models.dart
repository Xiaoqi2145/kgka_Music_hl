import 'music_models.dart';

/// 酷狗「私人 FM / 红心电台」的推荐模式。
///
/// 首版只上线 [normal]（红心）；[small]（小众）与 [peak]（30 秒速览）保留
/// 常量以便后续按真机体验放开，不做入口、不参与默认请求。
enum PersonalFmMode {
  normal('normal', '红心'),
  small('small', '小众'),
  peak('peak', '30 秒速览');

  const PersonalFmMode(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static PersonalFmMode fromApi(String? value) => PersonalFmMode.values
      .firstWhere((mode) => mode.apiValue == value, orElse: () => normal);
}

/// 离曲时上报给酷狗的行为。
///
/// 只包含 api.json 中 `/personal/fm` 明确声明并已实测可用的动作。
/// `click_red` / `cancel_red` 是方案里待验证的动作，未接入：红心一律以
/// 账号「我喜欢」为准，避免在未确认契约前发出副作用请求。
enum PersonalFmAction {
  play('play'),
  garbage('garbage');

  const PersonalFmAction(this.apiValue);

  final String apiValue;
}

/// 一次离曲反馈的同步状态，供电台页显示「已同步 / 仅本机」等提示。
enum PersonalFmFeedbackState {
  /// 没有在途反馈。
  idle,

  /// 请求已发出，尚未拿到业务结果。
  syncing,

  /// 服务端确认成功。
  synced,

  /// 请求已发出但结果未知（超时 / 断网）：不回滚，按结果未知处理。
  unknown,

  /// 服务端明确返回失败。
  failed,
}

/// 一首私人 FM 推荐。
///
/// [song] 承担播放链路的全部输入（音源解析、历史、歌词、封面）；其余字段
/// 只在离曲反馈时使用，普通播放不会读取它们。
class PersonalFmTrack {
  const PersonalFmTrack({
    required this.song,
    this.songId,
    this.recommendDesc,
    this.similarDesc,
  });

  final Song song;

  /// 接口原始 `songid`（int64 文本）。反馈请求优先使用它而不是 `mixsongid`。
  final String? songId;

  /// `rec_song_info.rec_desc`，例如「正在随机推荐歌曲」。
  final String? recommendDesc;

  /// `rec_song_info.similar_desc`，例如「相似度低」。
  final String? similarDesc;

  /// 去重键：优先可靠的酷狗曲库 ID，缺失时回落到资源 hash。
  ///
  /// 曲库 ID 在同一首歌的不同音质 hash 之间保持不变，比 hash 更接近
  /// 「这是同一首歌」的语义；hash 则覆盖 ID 缺失的部署。
  String get dedupeKey {
    final catalogId = song.catalogId;
    if (catalogId != null && catalogId.isNotEmpty) {
      return 'id:$catalogId';
    }
    return 'hash:${song.hash}';
  }

  factory PersonalFmTrack.fromJson(Map<String, dynamic> json) {
    final recInfo = asMap(json['rec_song_info']);
    final transParam = asMap(json['trans_param']);
    final artists = parseArtists(
      json,
      fallbackName: asString(json['author_name']),
    );
    final artistName = artists.map((artist) => artist.name).join(' / ');
    final displayName =
        asString(json['songname']) ??
        asString(json['audio_name']) ??
        asString(json['name']);
    final songId = asString(json['songid']);
    final mixSongId = asString(json['mixsongid']);

    return PersonalFmTrack(
      song: Song(
        // 与其它来源保持一致：id 优先取混合 ID，缺失时退回 songid / hash。
        id: mixSongId ?? songId ?? asString(json['hash']) ?? '',
        title: displayName ?? '未知歌曲',
        artist: artistName.isNotEmpty
            ? artistName
            : (asString(json['author_name']) ?? '未知艺人'),
        hash:
            asString(json['hash']) ??
            asString(json['hash_320']) ??
            asString(json['hash_flac']) ??
            '',
        albumId: asString(json['album_id']),
        albumAudioId: mixSongId ?? songId,
        albumName: asString(json['album_name']),
        coverUrl: normalizeImageUrl(
          asString(transParam['union_cover']) ?? asString(json['sizable_cover']),
        ),
        artists: artists,
        catalogId: mixSongId,
        // FM 的 time_length 是秒；Song.fromFm 只认毫秒字段，这里单独解析。
        duration: durationFromSeconds(json['time_length']),
      ),
      songId: songId,
      recommendDesc: asString(recInfo['rec_desc']),
      similarDesc: asString(recInfo['similar_desc']),
    );
  }
}

/// 一批私人 FM 推荐结果。
class PersonalFmBatch {
  const PersonalFmBatch({
    this.tracks = const [],
    this.status,
    this.errorCode,
    this.mode,
    this.curMark,
  });

  static const empty = PersonalFmBatch();

  final List<PersonalFmTrack> tracks;

  /// 业务状态：1 表示成功。缺省时按成功处理（部分部署不返回该字段）。
  final int? status;
  final int? errorCode;
  final String? mode;

  /// 服务端推荐标记，随推荐一起下发；本实现只做诊断保留。
  final String? curMark;

  bool get ok =>
      (status == null || status == 1) && (errorCode == null || errorCode == 0);

  /// 业务成功但没有任何可播放曲目：候选耗尽 / 曲库空结果。
  bool get isEmpty => tracks.isEmpty;

  factory PersonalFmBatch.fromJson(Map<String, dynamic> json) {
    final tracks = asList(json['song_list'])
        .whereType<Map>()
        .map((item) => PersonalFmTrack.fromJson(asMap(item)))
        .where((track) => track.song.hash.isNotEmpty)
        .toList();
    return PersonalFmBatch(
      tracks: tracks,
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
      mode: asString(json['mode']),
      curMark: asString(json['cur_mark']),
    );
  }
}
