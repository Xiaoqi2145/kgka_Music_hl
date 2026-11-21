import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../controllers/auth_controller.dart';
import '../models/music_models.dart';
import '../services/cache_service.dart';
import '../services/music_api.dart';

typedef CloudGradeLoader = Future<Map<String, dynamic>> Function();
typedef CloudRankLoader = Future<dynamic> Function();

class CloudListeningSource {
  CloudListeningSource(this._auth, this._gradeLoader, this._rankLoader);

  final AuthController _auth;
  final CloudGradeLoader _gradeLoader;
  final CloudRankLoader _rankLoader;

  String? get owner {
    final userId = _auth.session?.userId?.trim();
    if (!_auth.isLoggedIn || userId == null || userId.isEmpty) return null;
    return '${AppConfig.effectiveBaseUrl}|$userId';
  }

  Future<CloudReadResult<CloudListeningGrade>> grade() async {
    final ownerAtStart = owner;
    if (ownerAtStart == null) return const CloudReadResult.absent();
    try {
      final json = await _gradeLoader();
      if (!_stillOwner(ownerAtStart)) return const CloudReadResult.absent();
      final grade = asMap(json['grade']);
      return CloudReadResult(
        CloudListeningGrade.fromJson(grade.isNotEmpty ? grade : json),
      );
    } catch (_) {
      return const CloudReadResult.absent();
    }
  }

  Future<CloudReadResult<List<CloudListenRank>>> rank() async {
    final ownerAtStart = owner;
    if (ownerAtStart == null) return const CloudReadResult.absent();
    try {
      final raw = await _rankLoader();
      if (!_stillOwner(ownerAtStart)) return const CloudReadResult.absent();
      Object? entries = raw;
      if (raw is Map) {
        final map = asMap(raw);
        entries = map['songs'] ?? map['list'] ?? map['data'] ?? map['rank'];
      }
      final list = asList(entries);
      return CloudReadResult(
        list
            .whereType<Map>()
            .map((item) => CloudListenRank.fromJson(asMap(item)))
            .where((item) => item.title.isNotEmpty)
            .toList(growable: false),
      );
    } catch (_) {
      return const CloudReadResult.absent();
    }
  }

  bool _stillOwner(String expected) => owner == expected;
}

class CloudReadResult<T> {
  const CloudReadResult(this.value);
  const CloudReadResult.absent() : value = null;

  final T? value;
  bool get available => value != null;
}

/// Read-only account statistics with a 15-minute freshness window.
///
/// Cache keys include the API origin and user ID. Requests hold their owner
/// string across awaits and are discarded if the account changes.
class CloudListeningService {
  CloudListeningService(
    MusicApi api,
    this._auth,
    this._cache, {
    DateTime Function()? now,
    CloudGradeLoader? gradeLoader,
    CloudRankLoader? rankLoader,
  }) : _now = now ?? DateTime.now,
       _gradeLoader = gradeLoader ?? api.cloudGradeInfo,
       _rankLoader = rankLoader ?? api.cloudListenRank;

  static const refreshInterval = Duration(minutes: 15);

  final AuthController _auth;
  final CacheService _cache;
  final DateTime Function() _now;
  final CloudGradeLoader _gradeLoader;
  final CloudRankLoader _rankLoader;
  late final CloudListeningSource _source = CloudListeningSource(
    _auth,
    _gradeLoader,
    _rankLoader,
  );
  CloudListeningSummary? _memory;
  String? _owner;
  Future<CloudListeningSummary>? _inFlight;

  void reset() {
    _memory = null;
    _owner = null;
    _inFlight = null;
  }

  Future<CloudListeningSummary> load({bool force = false}) async {
    final owner = _source.owner;
    if (owner == null) return const CloudListeningSummary();
    if (_owner != owner) reset();
    final memory = _memory;
    if (!force &&
        memory != null &&
        memory.refreshedAt != null &&
        _now().difference(memory.refreshedAt!) < refreshInterval) {
      return memory;
    }
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _loadOwner(owner);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<CloudListeningSummary> _loadOwner(String owner) async {
    final cached = await _cache.read<CloudListeningSummary>(
      cacheKey(owner),
      decode: CloudListeningSummary.fromJson,
      ttl: refreshInterval,
    );
    if (cached != null && !cached.isStale) {
      _memory = cached.data;
      _owner = owner;
      return cached.data;
    }
    final gradeFuture = _source.grade();
    final rankFuture = _source.rank();
    final gradeResult = await gradeFuture;
    final rankResult = await rankFuture;
    final grade = gradeResult.value;
    final rank = rankResult.value;
    if (_source.owner != owner) {
      return cached?.data ?? const CloudListeningSummary();
    }
    if (!gradeResult.available && !rankResult.available && cached != null) {
      return cached.data;
    }
    final summary = CloudListeningSummary(
      level: grade?.level,
      levelName: grade?.levelName,
      totalSeconds: grade?.totalSeconds,
      nextLevelSeconds: grade?.nextLevelSeconds,
      rank: rank ?? const [],
      refreshedAt: _now(),
      gradeError: gradeResult.available ? null : '等级接口不可用',
      rankError: rankResult.available ? null : '排行接口不可用',
    );
    _memory = summary;
    _owner = owner;
    try {
      await _cache.write(cacheKey(owner), summary.toCache());
    } catch (error) {
      debugPrint('[KA Music][cloud-listening] cache write failed: $error');
    }
    return summary;
  }

  static String cacheKey(String owner) {
    final safe = base64Url.encode(utf8.encode(owner)).replaceAll('=', '');
    return 'cache_user_listening_$safe';
  }
}
