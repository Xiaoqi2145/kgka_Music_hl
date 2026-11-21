import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';

/// 播放统计数据。
///
/// 包含累计播放次数、累计听歌时长、最常听歌手/歌曲 Top 10、首次播放时间。
/// 通过 [toJson]/[fromJson] 持久化到 SharedPreferences。
class PlaybackStats {
  const PlaybackStats({
    this.totalPlays = 0,
    this.totalListenTime = Duration.zero,
    this.artistPlayCount = const {},
    this.songPlayCount = const {},
    this.songTitles = const {},
    this.artistNames = const {},
    this.firstPlayDate,
    this.legacyReadonly = false,
  });

  /// 累计播放次数（每次调用 recordPlay +1）。
  final int totalPlays;

  /// 累计听歌时长。
  final Duration totalListenTime;

  /// 稳定歌手键 -> 播放次数。
  final Map<String, int> artistPlayCount;

  /// 稳定曲目键 -> 播放次数。
  final Map<String, int> songPlayCount;

  /// 稳定曲目键 -> 展示标题，避免同名歌曲合并。
  final Map<String, String> songTitles;

  /// 稳定歌手键 -> 展示名称。
  final Map<String, String> artistNames;

  /// 首次播放时间（本地统计）。
  final DateTime? firstPlayDate;

  /// 旧版只含播放次数；单独保留为升级前快照。
  final bool legacyReadonly;

  factory PlaybackStats.fromJson(Map<String, dynamic> json) {
    return PlaybackStats(
      totalPlays: json['totalPlays'] as int? ?? 0,
      totalListenTime: Duration(
        milliseconds: json['totalListenMs'] as int? ?? 0,
      ),
      artistPlayCount: Map<String, int>.from(
        json['artistPlayCount'] as Map? ?? const {},
      ),
      songPlayCount: Map<String, int>.from(
        json['songPlayCount'] as Map? ?? const {},
      ),
      songTitles: Map<String, String>.from(
        json['songTitles'] as Map? ?? const {},
      ),
      artistNames: Map<String, String>.from(
        json['artistNames'] as Map? ?? const {},
      ),
      firstPlayDate: json['firstPlayDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['firstPlayDate'] as int)
          : null,
      legacyReadonly: json['legacyReadonly'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'totalPlays': totalPlays,
    'totalListenMs': totalListenTime.inMilliseconds,
    'artistPlayCount': artistPlayCount,
    'songPlayCount': songPlayCount,
    'songTitles': songTitles,
    'artistNames': artistNames,
    'firstPlayDate': firstPlayDate?.millisecondsSinceEpoch,
    if (legacyReadonly) 'legacyReadonly': true,
  };

  /// 格式化听歌时长为 "x小时y分钟" 或 "y分钟"。
  String get formattedListenTime {
    final h = totalListenTime.inHours;
    final m = totalListenTime.inMinutes.remainder(60);
    if (h > 0) return '$h小时$m分钟';
    if (m > 0) return '$m分钟';
    return '不足1分钟';
  }

  /// 最常听歌手 Top 10。
  List<MapEntry<String, int>> get topArtists {
    final entries = artistPlayCount.entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(10)
        .map(
          (entry) => MapEntry(artistNames[entry.key] ?? entry.key, entry.value),
        )
        .toList();
  }

  /// 最常听歌曲 Top 10。
  List<MapEntry<String, int>> get topSongs {
    final entries = songPlayCount.entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(10)
        .map(
          (entry) => MapEntry(songTitles[entry.key] ?? entry.key, entry.value),
        )
        .toList();
  }
}

/// 播放统计服务。
///
/// 提供本地播放统计的记录与查询：每次播放记 +1，每上报一次听歌时长同步累加。
class PlaybackStatsService {
  static const _prefsKey = 'playback_stats';
  static const _legacyKey = 'playback_stats_legacy_v1';
  static const _checkpointDuration = Duration(minutes: 5);

  PlaybackStats? _stats;
  Future<void>? _loadFuture;
  Timer? _persistTimer;
  bool _dirty = false;
  bool _legacyStats = false;
  bool _legacySaved = false;
  bool _saveQueued = false;
  int _dataVersion = 0;
  Future<void>? _saveFuture;
  Duration _uncheckpointedTime = Duration.zero;

  Future<void> _ensureLoaded() async {
    if (_stats != null) return;
    final pending = _loadFuture;
    if (pending != null) return pending;
    final future = _load();
    _loadFuture = future;
    try {
      await future;
    } finally {
      _loadFuture = null;
    }
  }

  Future<void> _load() async {
    final file = await _file();
    final prefs = await SharedPreferences.getInstance();
    try {
      if (file.existsSync()) {
        final raw = await file.readAsString();
        final storedJson = asMap(jsonDecode(raw));
        final stored = PlaybackStats.fromJson(storedJson);
        if (stored.legacyReadonly) {
          await _preserveLegacy(prefs, stored);
          _stats = const PlaybackStats();
        } else if (_isLegacy(storedJson)) {
          await _preserveLegacy(prefs, stored);
          _stats = const PlaybackStats();
          _dirty = true;
        } else {
          _stats = stored;
        }
      } else {
        final raw = prefs.getString(_prefsKey);
        if (raw != null) {
          final json = jsonDecode(raw);
          if (json is Map<String, dynamic>) {
            _stats = PlaybackStats.fromJson(json);
            _legacyStats = _isLegacy(json);
            if (_legacyStats) {
              await _preserveLegacy(prefs, _stats!);
              _stats = const PlaybackStats();
            }
            _dirty = true;
          }
        }
      }
    } catch (_) {
      _stats = const PlaybackStats();
    }
    _stats ??= const PlaybackStats();
    _dataVersion = 0;
    if (_dirty) unawaited(flush());
  }

  /// 读取当前统计；无数据时返回空的 [PlaybackStats]。
  Future<PlaybackStats> getStats() async {
    await _ensureLoaded();
    return _stats!;
  }

  /// 记录一次播放：累加播放次数，统计歌手/歌曲计数。
  Future<void> recordPlay(Song song) async {
    await _ensureLoaded();
    final stats = _stats!;
    final artistCount = Map<String, int>.of(stats.artistPlayCount);
    final songCount = Map<String, int>.of(stats.songPlayCount);
    final songTitles = Map<String, String>.of(stats.songTitles);
    final artistNames = Map<String, String>.of(stats.artistNames);

    final songKey = playbackSongKey(song);
    final artistKey = playbackArtistKey(song);
    artistCount[artistKey] = (artistCount[artistKey] ?? 0) + 1;
    songCount[songKey] = (songCount[songKey] ?? 0) + 1;
    songTitles[songKey] = song.title.trim().isEmpty ? '未知歌曲' : song.title;
    artistNames[artistKey] = artistKey;

    final updated = PlaybackStats(
      totalPlays: stats.totalPlays + 1,
      totalListenTime: stats.totalListenTime,
      artistPlayCount: artistCount,
      songPlayCount: songCount,
      songTitles: songTitles,
      artistNames: artistNames,
      firstPlayDate: stats.firstPlayDate ?? DateTime.now(),
    );
    _stats = updated;
    _markChanged();
  }

  /// 累加听歌时长。
  Future<void> addListenTime(Duration duration) async {
    if (duration <= Duration.zero) return;
    await _ensureLoaded();
    final stats = _stats!;
    final updated = PlaybackStats(
      totalPlays: stats.totalPlays,
      totalListenTime: stats.totalListenTime + duration,
      artistPlayCount: stats.artistPlayCount,
      songPlayCount: stats.songPlayCount,
      songTitles: stats.songTitles,
      artistNames: stats.artistNames,
      firstPlayDate: stats.firstPlayDate,
    );
    _stats = updated;
    _uncheckpointedTime += duration;
    _markChanged();
    _scheduleCheckpoint();
  }

  /// 清空统计。
  Future<void> clear() async {
    _stats = const PlaybackStats();
    _saveQueued = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    final file = await _file();
    if (file.existsSync()) await file.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await prefs.remove(_legacyKey);
    _legacyStats = false;
    _uncheckpointedTime = Duration.zero;
    _dirty = false;
    ++_dataVersion;
  }

  Future<void> _save(PlaybackStats stats, int version) async {
    if (version != _dataVersion) return;
    final prefs = await SharedPreferences.getInstance();
    if (_legacyStats) await _preserveLegacy(prefs, stats);
    if (version != _dataVersion) return;
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(jsonEncode(stats.toJson()));
    if (file.existsSync()) await file.delete();
    await temporary.rename(file.path);
    await prefs.remove(_prefsKey);
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 5), () {
      _persistTimer = null;
      _saveQueued = true;
      unawaited(flush());
    });
  }

  void _scheduleCheckpoint() {
    if (_uncheckpointedTime < _checkpointDuration) return;
    _uncheckpointedTime = Duration.zero;
    _saveQueued = true;
    unawaited(flush());
  }

  void _markChanged() {
    _dirty = true;
    ++_dataVersion;
    if (_persistTimer == null && _saveQueued == false) {
      _schedulePersist();
    }
  }

  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_saveFuture == null && !_saveQueued) _saveQueued = true;
    await _ensureLoaded();
    if (!_dirty) return;
    if (!_saveQueued) return;
    _saveQueued = false;
    final pending = _saveFuture;
    if (pending != null) {
      await pending;
      if (!_dirty) return;
    }
    _dirty = false;
    final version = _dataVersion;
    final save = _save(_stats!, version);
    _saveFuture = save;
    try {
      await save;
    } finally {
      if (identical(_saveFuture, save)) _saveFuture = null;
    }
    if (_dirty) {
      _schedulePersist();
    }
  }

  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/playback_stats.json');
  }

  static bool _isLegacy(Map<String, dynamic> json) =>
      json['legacyReadonly'] == true ||
      (json['totalListenMs'] == null && (json['totalPlays'] as num? ?? 0) > 0);

  Future<void> _preserveLegacy(
    SharedPreferences prefs,
    PlaybackStats stats,
  ) async {
    if (_legacySaved) return;
    final legacy = PlaybackStats(
      totalPlays: stats.totalPlays,
      totalListenTime: stats.totalListenTime,
      artistPlayCount: stats.artistPlayCount,
      songPlayCount: stats.songPlayCount,
      songTitles: stats.songTitles,
      artistNames: stats.artistNames,
      firstPlayDate: stats.firstPlayDate,
      legacyReadonly: true,
    );
    await prefs.setString(_legacyKey, jsonEncode(legacy.toJson()));
    _legacySaved = true;
    _legacyStats = true;
  }
}

/// Stable, source-qualified identity used by local rankings and cloud queues.
///
/// Numeric [Song.id] values are intentionally not trusted as catalog IDs: the
/// parser may fall back to audio/file IDs when MixSongID is absent.
String playbackSongKey(Song song) {
  final hash = song.hash.trim();
  if (song.source == SongSource.kugou &&
      !song.isCloudDrive &&
      hash.isNotEmpty) {
    return 'kugou:hash:$hash';
  }
  return '${song.source.name}:hash:$hash';
}

String playbackArtistKey(Song song) {
  final artist = song.artist.trim();
  return artist.isEmpty ? '未知艺人' : artist;
}

/// Catalog identity suitable for cloud history upload, or null when the song
/// cannot be proven to belong to the Kugou catalog.
String? cloudSongId(Song song) {
  if (song.source != SongSource.kugou || song.isCloudDrive) return null;
  final catalogId = song.catalogId?.trim();
  if (catalogId != null && RegExp(r'^\d+$').hasMatch(catalogId)) {
    return catalogId;
  }
  final audioId = song.albumAudioId?.trim();
  if (audioId != null && RegExp(r'^\d+$').hasMatch(audioId)) {
    return audioId;
  }
  return null;
}
