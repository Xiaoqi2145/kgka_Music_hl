import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';

/// 播放历史记录服务。
///
/// 将最近播放过的歌曲按时间倒序持久化到 SharedPreferences（JSON 格式），
/// 同一首歌重复播放时会移动到列表头部，最多保留 [_maxRecords] 条。
class PlaybackHistoryService {
  static const _key = 'playback_history';
  static const _maxRecords = 500;
  List<Song>? _songs;
  Future<void>? _loadFuture;
  Timer? _persistTimer;
  bool _dirty = false;

  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/playback_history.json');
  }

  Future<void> _ensureLoaded() async {
    if (_songs != null) return;
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
    String? raw;
    final file = await _file();
    if (file.existsSync()) raw = await file.readAsString();
    final prefs = await SharedPreferences.getInstance();
    raw ??= prefs.getString(_key);
    try {
      final decoded = raw == null ? const [] : await compute(_decodeList, raw);
      _songs = decoded
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .where((song) => song.hash.isNotEmpty)
          .take(_maxRecords)
          .toList();
    } catch (_) {
      _songs = <Song>[];
    }
    if (prefs.containsKey(_key)) {
      _dirty = true;
      await flush();
      await prefs.remove(_key);
    }
  }

  /// 记录一次播放：去重后插入到头部，超出上限时截断。
  Future<void> record(Song song) async {
    if (song.hash.isEmpty) return;
    await _ensureLoaded();
    _songs!.removeWhere((item) => item.hash == song.hash);
    _songs!.insert(0, song);
    if (_songs!.length > _maxRecords)
      _songs!.removeRange(_maxRecords, _songs!.length);
    _dirty = true;
    _schedulePersist();
  }

  /// 读取播放历史，最多返回 [limit] 条。
  Future<List<Song>> getHistory({int limit = 100}) async {
    await _ensureLoaded();
    return _songs!.take(limit).toList(growable: false);
  }

  /// 清空播放历史。
  Future<void> clear() async {
    await _ensureLoaded();
    _songs!.clear();
    _dirty = false;
    _persistTimer?.cancel();
    final file = await _file();
    if (file.existsSync()) await file.delete();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 5), () => unawaited(flush()));
  }

  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _ensureLoaded();
    if (!_dirty) return;
    _dirty = false;
    final raw = await compute(
      _encodeList,
      _songs!.map((song) => song.toCache()).toList(growable: false),
    );
    final file = await _file();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(raw);
    if (file.existsSync()) await file.delete();
    await temporary.rename(file.path);
  }
}

List<dynamic> _decodeList(String raw) => jsonDecode(raw) as List<dynamic>;

String _encodeList(List<Map<String, dynamic>> value) => jsonEncode(value);
