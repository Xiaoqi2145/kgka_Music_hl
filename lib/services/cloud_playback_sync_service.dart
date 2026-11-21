import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../controllers/auth_controller.dart';
import '../core/api_client.dart';
import '../models/music_models.dart';
import '../services/music_api.dart';
import '../services/playback_stats_service.dart';

typedef CloudHistoryUploader =
    Future<dynamic> Function({required String mxid, required int time, int pc});
typedef CloudGradeUploader =
    Future<dynamic> Function({required int dSec, required int diffSec});
typedef CloudTimeReader = Future<dynamic> Function();

enum SyncOutcome {
  idle,
  deferred,
  sent,
  retryableFailure,
  unknownResult,
  backoff,
}

class CloudSyncSnapshot {
  const CloudSyncSnapshot({
    this.historyPending = 0,
    this.gradePending = Duration.zero,
    this.lastSyncAt,
    this.historyState = 'idle',
    this.gradeState = 'idle',
  });

  final int historyPending;
  final Duration gradePending;
  final DateTime? lastSyncAt;
  final String historyState;
  final String gradeState;
}

/// Low-frequency cloud writes for one account.
///
/// Every queue, in-flight marker and backoff is persisted with an API-origin
/// and user-scoped key. A sent item stays in-flight until a validated response
/// arrives; after a crash that state is treated as an unknown result and is
/// not replayed automatically.
class CloudPlaybackSyncService extends ChangeNotifier {
  CloudPlaybackSyncService(
    MusicApi api,
    this._auth, {
    CloudHistoryUploader? historyUploader,
    CloudGradeUploader? gradeUploader,
    CloudTimeReader? gradeReader,
    CloudTimeReader? legacyGradeUploader,
    Duration? retryUnit,
    Directory? directory,
    DateTime Function()? now,
  }) : _historyUploader = historyUploader ?? api.cloudUploadHistory,
       _gradeUploader = gradeUploader ?? api.cloudGradeUpdate,
       _gradeReader = gradeReader ?? api.cloudGradeInfo,
       _legacyGradeUploader = legacyGradeUploader ?? api.cloudAddTime,
       _retryUnit = retryUnit ?? const Duration(minutes: 30),
       _directoryOverride = directory,
       _now = now ?? DateTime.now;

  static const syncWindow = Duration(minutes: 30);
  static const historyLimit = 100;
  static const historyMaxAge = Duration(hours: 24);
  static const historyBatch = 20;
  static const gradeBatch = Duration(minutes: 30);
  static const _gradeCheckpoint = Duration(minutes: 5);
  static const gradeMaxAge = Duration(hours: 24);
  static const unknownIsolation = Duration(hours: 6);

  final AuthController _auth;
  final CloudHistoryUploader _historyUploader;
  final CloudGradeUploader _gradeUploader;
  final CloudTimeReader _gradeReader;
  final CloudTimeReader _legacyGradeUploader;
  final Duration _retryUnit;
  final Directory? _directoryOverride;
  final DateTime Function() _now;
  bool _historyEnabled = false;
  bool _gradeEnabled = true;
  bool _foreground = true;
  Future<SyncOutcome>? _inFlight;
  Future<void> _stateOperations = Future<void>.value();
  final _bufferedGradeMicros = <String, int>{};
  final _scheduledGradeCheckpoints = <String>{};
  final _checkpointRetryAt = <String, DateTime>{};
  int _gradeResetsPending = 0;
  CloudSyncSnapshot _snapshot = const CloudSyncSnapshot();
  int _historyFailureCount = 0;
  String? _owner;

  CloudSyncSnapshot get snapshot => _snapshot;
  bool get historyEnabled => _historyEnabled;
  bool get gradeEnabled => _gradeEnabled;
  void notifySettingsChanged() => notifyListeners();

  String? get _storageKeyOwner {
    final userId = _auth.session?.userId?.trim();
    if (!_auth.isLoggedIn || userId == null || userId.isEmpty) return null;
    return '${AppConfig.effectiveBaseUrl}|$userId';
  }

  void configure({bool? historyEnabled, bool? gradeEnabled}) {
    _historyEnabled = historyEnabled ?? _historyEnabled;
    _gradeEnabled = gradeEnabled ?? _gradeEnabled;
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
  }

  Future<void> setHistoryEnabled(bool enabled) {
    final owner = _storageKeyOwner;
    if (owner == null) return Future<void>.value();
    return _withState(() async {
      if (!_isKnownOwner(owner)) return;
      await _ensureOwner(owner);
      if (!_isKnownOwner(owner)) return;
      final state = await _readState(owner);
      _historyEnabled = enabled;
      state['historyEnabled'] = enabled;
      await _writeState(owner, state);
      _updateSnapshot(owner, state);
      if (_isKnownOwner(owner)) notifySettingsChanged();
    });
  }

  Future<void> setGradeEnabled(bool enabled) {
    _gradeEnabled = enabled;
    final owner = _storageKeyOwner;
    if (enabled || owner == null) return Future<void>.value();
    _bufferedGradeMicros.remove(owner);
    _gradeResetsPending++;
    return _withState(() async {
      try {
        final state = await _readState(owner);
        if (_gradePendingMicros(state) == 0 && state['gradeInFlight'] == null) {
          return;
        }
        state['gradePendingMicros'] = 0;
        state.remove('gradeInFlight');
        await _writeState(owner, state);
        _updateSnapshot(owner, state);
      } finally {
        _gradeResetsPending--;
      }
    });
  }

  Future<void> restore() => onAccountChanged();

  Future<void> enqueueHistory(Song song, {required DateTime playedAt}) {
    if (!_historyEnabled) return Future<void>.value();
    final owner = _storageKeyOwner;
    final songId = cloudSongId(song);
    if (owner == null || songId == null || songId.isEmpty) {
      return Future<void>.value();
    }
    return _withState(() => _enqueueHistory(owner, songId, song, playedAt));
  }

  Future<void> _enqueueHistory(
    String owner,
    String songId,
    Song song,
    DateTime playedAt,
  ) async {
    if (!_isKnownOwner(owner)) return;
    await _ensureOwner(owner);
    if (!_isKnownOwner(owner)) return;
    final state = await _readState(owner);
    if (!_isKnownOwner(owner)) return;
    if (_historyEnabled != (state['historyEnabled'] == true)) return;
    final queue = asList(state['history']).whereType<Map>().map(asMap).toList();
    final id = '$songId|${playedAt.millisecondsSinceEpoch}';
    if (queue.any((item) => item['id'] == id)) return;
    queue.add({
      'id': id,
      'mxid': songId,
      'time': playedAt.millisecondsSinceEpoch,
      'created': _now().millisecondsSinceEpoch,
      'title': song.title,
    });
    final cutoff = _now().subtract(historyMaxAge).millisecondsSinceEpoch;
    queue.removeWhere((item) => (asInt(item['created']) ?? 0) < cutoff);
    while (queue.length > historyLimit) {
      queue.removeAt(0);
    }
    state['history'] = queue;
    await _writeState(owner, state);
    _updateSnapshot(owner, state);
  }

  void enqueueGradeTime(Duration duration) {
    if (!_gradeEnabled || duration <= Duration.zero) return;
    final owner = _storageKeyOwner;
    if (owner == null) return;
    final buffered =
        ((_bufferedGradeMicros[owner] ?? 0) + duration.inMicroseconds).clamp(
          0,
          gradeMaxAge.inMicroseconds,
        );
    _bufferedGradeMicros[owner] = buffered;
    if (buffered < _gradeCheckpoint.inMicroseconds) return;
    final retryAt = _checkpointRetryAt[owner];
    if (retryAt != null && _now().isBefore(retryAt)) return;
    if (!_scheduledGradeCheckpoints.add(owner)) return;
    unawaited(
      _withState(() async {
        try {
          if (_isKnownOwner(owner) && _foreground) {
            await _syncOwner(owner, includeHistory: false);
          } else {
            await _checkpointGradeTime(owner);
          }
        } catch (error) {
          _checkpointRetryAt[owner] = _now().add(_gradeCheckpoint);
          debugPrint('[KA Music][cloud-sync] grade checkpoint failed: $error');
        } finally {
          _scheduledGradeCheckpoints.remove(owner);
        }
      }),
    );
  }

  Future<void> flushGradeTime() => _withState(() async {
    for (final owner in _bufferedGradeMicros.keys.toList()) {
      try {
        await _checkpointGradeTime(owner);
      } catch (error) {
        debugPrint('[KA Music][cloud-sync] grade checkpoint failed: $error');
      }
    }
  });

  Future<void> onAccountChanged() {
    final owner = _storageKeyOwner;
    if (_owner == owner) return Future<void>.value();
    return _withState(() async {
      if (owner != _storageKeyOwner) return;
      if (owner != null) {
        await _ensureOwner(owner);
      } else {
        _owner = null;
        _historyEnabled = false;
        _snapshot = const CloudSyncSnapshot();
      }
      if (owner == _storageKeyOwner) notifyListeners();
    });
  }

  Future<Map<String, dynamic>> _checkpointGradeTime(String owner) async {
    final state = await _readState(owner);
    final buffered = _bufferedGradeMicros.remove(owner);
    if (buffered == null) return state;
    state['gradePendingMicros'] = (_gradePendingMicros(state) + buffered).clamp(
      0,
      gradeMaxAge.inMicroseconds,
    );
    try {
      await _writeState(owner, state);
      _checkpointRetryAt.remove(owner);
    } catch (_) {
      if (_gradeEnabled) {
        _bufferedGradeMicros.update(
          owner,
          (value) => value + buffered,
          ifAbsent: () => buffered,
        );
      }
      rethrow;
    }
    _updateSnapshot(owner, state);
    return state;
  }

  Future<T> _withState<T>(Future<T> Function() action) {
    final result = _stateOperations.then((_) => action());
    _stateOperations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<SyncOutcome> maybeSync() {
    final owner = _storageKeyOwner;
    if (owner == null || !_foreground) {
      return Future.value(SyncOutcome.deferred);
    }
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _withState(() => _syncOwner(owner));
    _inFlight = future;
    return _finishSync(future);
  }

  Future<SyncOutcome> _finishSync(Future<SyncOutcome> future) async {
    try {
      return await future;
    } catch (error) {
      debugPrint('[KA Music][cloud-sync] could not sync: $error');
      return SyncOutcome.deferred;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<SyncOutcome> _syncOwner(
    String owner, {
    bool includeHistory = true,
  }) async {
    if (!_isKnownOwner(owner)) return SyncOutcome.deferred;
    await _ensureOwner(owner);
    final state = await _checkpointGradeTime(owner);
    if (!_isKnownOwner(owner) || !_foreground) return SyncOutcome.deferred;
    var outcome = SyncOutcome.idle;
    final lastHistory = asInt(state['historyLastSyncAt']);
    final historyDue =
        lastHistory == null ||
        _now().millisecondsSinceEpoch - lastHistory >=
            syncWindow.inMilliseconds;
    if (includeHistory && historyDue && state['historyEnabled'] == true) {
      final result = await _syncHistory(owner, state);
      if (result == SyncOutcome.sent) {
        outcome = SyncOutcome.sent;
      } else if (result != SyncOutcome.idle && outcome == SyncOutcome.idle) {
        outcome = result;
      }
    }
    if (_gradeEnabled &&
        _gradeResetsPending == 0 &&
        _foreground &&
        _isKnownOwner(owner)) {
      final result = await _syncGrade(owner, state);
      if (result == SyncOutcome.sent) {
        if (outcome == SyncOutcome.idle) outcome = SyncOutcome.sent;
      } else if (result != SyncOutcome.idle && outcome == SyncOutcome.idle) {
        outcome = result;
      }
    }
    _updateSnapshot(owner, state);
    if (!_isKnownOwner(owner)) return SyncOutcome.deferred;
    return outcome;
  }

  bool _isKnownOwner(String? owner) =>
      owner != null && _storageKeyOwner == owner;

  Future<SyncOutcome> _syncHistory(
    String owner,
    Map<String, dynamic> state,
  ) async {
    final queue = asList(state['history']).whereType<Map>().map(asMap).toList();
    if (queue.isEmpty) {
      state['historyInFlight'] = null;
      return SyncOutcome.idle;
    }
    final inFlight = state['historyInFlight'];
    if (inFlight is Map) {
      state['historyQuarantine'] = true;
      state['history'] = const <Map<String, dynamic>>[];
      await _writeState(owner, state);
      return SyncOutcome.unknownResult;
    }
    final retryAt = asInt(state['historyRetryAt']);
    if (retryAt != null && _now().millisecondsSinceEpoch < retryAt) {
      return SyncOutcome.backoff;
    }
    final total = asInt(state['historyRetryTotal']) ?? 0;
    if (total >= historyBatch) return SyncOutcome.deferred;
    final item = queue.first;
    final batchId = item['id']?.toString() ?? '';
    state['historyInFlight'] = {
      'id': batchId,
      'at': _now().millisecondsSinceEpoch,
    };
    await _writeState(owner, state);
    if (!_foreground || !_isKnownOwner(owner)) {
      state.remove('historyInFlight');
      await _writeState(owner, state);
      return SyncOutcome.deferred;
    }
    try {
      final result = await _historyUploader(
        mxid: item['mxid'].toString(),
        time: asInt(item['time']) ?? 0,
      );
      if (!_isAccepted(result)) {
        state['historyInFlight'] = null;
        _historyFailureCount++;
        final attempts = asInt(state['historyRetryTotal']) ?? 0;
        state['historyRetryTotal'] = attempts + 1;
        state['historyRetryAt'] = _retryAt(
          _historyFailureCount,
        ).millisecondsSinceEpoch;
        await _writeState(owner, state);
        return SyncOutcome.retryableFailure;
      }
      state['historyInFlight'] = null;
      state['history'] = queue
          .where((entry) => entry['id'] != batchId)
          .toList();
      state['historyRetryAt'] = null;
      state['historyRetryTotal'] = 0;
      _historyFailureCount = 0;
      final syncedAt = _now().millisecondsSinceEpoch;
      state['historyLastSyncAt'] = syncedAt;
      state['lastSyncAt'] = syncedAt;
      await _writeState(owner, state);
      return SyncOutcome.sent;
    } catch (error) {
      // A transport failure can mean the server accepted the write. Keep the
      // in-flight marker so a restart cannot silently replay it.
      debugPrint('[KA Music][cloud-sync] history result unknown: $error');
      state['historyQuarantine'] = true;
      state['history'] = const <Map<String, dynamic>>[];
      await _writeState(owner, state);
      return SyncOutcome.unknownResult;
    }
  }

  Future<SyncOutcome> _syncGrade(
    String owner,
    Map<String, dynamic> state,
  ) async {
    final pending = _gradePendingMicros(state);
    final interrupted = asMap(state['gradeInFlight']);
    if (interrupted.isNotEmpty) {
      final reserved =
          asInt(interrupted['micros']) ?? gradeBatch.inMicroseconds;
      state['gradePendingMicros'] = (pending - reserved).clamp(0, pending);
      state.remove('gradeInFlight');
      await _writeState(owner, state);
      return SyncOutcome.unknownResult;
    }
    if (pending == 0) return SyncOutcome.idle;
    if (pending < gradeBatch.inMicroseconds) return SyncOutcome.deferred;
    final retryAt = asInt(state['gradeRetryAt']);
    if (retryAt != null && _now().millisecondsSinceEpoch < retryAt) {
      return SyncOutcome.backoff;
    }
    final useLegacy = AppConfig.usesHostedApi;
    final session = _auth.session;
    int? baseline;
    if (!useLegacy) {
      try {
        baseline = _gradeBaseline(await _gradeReader());
      } catch (error) {
        debugPrint('[KA Music][cloud-sync] grade baseline unavailable: $error');
        state['gradeRetryAt'] = _now().add(syncWindow).millisecondsSinceEpoch;
        await _writeState(owner, state);
        return SyncOutcome.retryableFailure;
      }
    }
    if (!_canSendGrade(owner, session)) return SyncOutcome.deferred;

    final batch = gradeBatch.inMicroseconds;
    state['gradeInFlight'] = {'micros': batch};
    state['gradeRetryAt'] = _now().add(syncWindow).millisecondsSinceEpoch;
    await _writeState(owner, state);
    if (!_canSendGrade(owner, session)) {
      state.remove('gradeInFlight');
      state.remove('gradeRetryAt');
      await _writeState(owner, state);
      return SyncOutcome.deferred;
    }

    SyncOutcome outcome;
    try {
      final result = useLegacy
          ? await _legacyGradeUploader()
          : await _gradeUploader(
              dSec: baseline!,
              diffSec: gradeBatch.inSeconds,
            );
      outcome = _gradeWriteAccepted(result)
          ? SyncOutcome.sent
          : SyncOutcome.retryableFailure;
    } catch (error) {
      final status = error is ApiException ? error.statusCode : null;
      outcome = const {401, 403, 404, 405, 429}.contains(status)
          ? SyncOutcome.retryableFailure
          : SyncOutcome.unknownResult;
      debugPrint('[KA Music][cloud-sync] grade $outcome (HTTP $status)');
    }
    state.remove('gradeInFlight');
    if (outcome != SyncOutcome.retryableFailure) {
      state['gradePendingMicros'] = pending - batch;
    }
    if (outcome == SyncOutcome.sent) {
      state['lastSyncAt'] = _now().millisecondsSinceEpoch;
    }
    await _writeState(owner, state);
    return outcome;
  }

  bool _canSendGrade(String owner, LoginSession? session) =>
      _foreground &&
      _gradeEnabled &&
      _gradeResetsPending == 0 &&
      _isKnownOwner(owner) &&
      identical(session, _auth.session);

  int _gradePendingMicros(Map<String, dynamic> state) =>
      (asInt(state['gradePendingMicros']) ?? 0).clamp(
        0,
        gradeMaxAge.inMicroseconds,
      );

  bool _gradeWriteAccepted(dynamic value) {
    if (value is! Map) return _isAccepted(value);
    final fields = asMap(value);
    final error = asInt(fields['error_code'] ?? fields['errcode']);
    if (error != null && error != 0) return false;
    final status = fields['status'] ?? fields['code'];
    return status == null || _isAccepted({'status': status});
  }

  DateTime _retryAt(int failures) {
    return _now().add(_retryUnit * (1 << (failures - 1).clamp(0, 2)));
  }

  bool _isAccepted(dynamic value) {
    if (value is Map) {
      final map = asMap(value);
      final status = map['status'] ?? map['code'] ?? map['error_code'];
      if (status != null) {
        final normalized = status.toString().toLowerCase();
        if (normalized == '0' ||
            normalized == 'false' ||
            normalized == 'fail' ||
            normalized == 'failed' ||
            normalized == 'error') {
          return false;
        }
        if (normalized == '1' ||
            normalized == 'ok' ||
            normalized == 'success') {
          return true;
        }
      }
    }
    if (value == null) return true;
    if (value is bool) return value;
    return true;
  }

  int _gradeBaseline(dynamic value) {
    if (value is! Map) {
      throw const FormatException('grade response missing');
    }
    final grade = asMap(asMap(value)['grade']);
    final source = grade.isNotEmpty ? grade : asMap(value);
    final seconds = asInt(source['d_sec'] ?? source['total_seconds']);
    if (seconds == null) throw const FormatException('grade d_sec missing');
    return seconds;
  }

  Future<void> _ensureOwner(String owner) async {
    if (_owner == owner) return;
    final state = await _readState(owner);
    if (!_isKnownOwner(owner)) return;
    _owner = owner;
    _historyEnabled = state['historyEnabled'] == true;
    _updateSnapshot(owner, state);
  }

  void _updateSnapshot(String owner, Map<String, dynamic> state) {
    if (!_isKnownOwner(owner)) return;
    _snapshot = CloudSyncSnapshot(
      historyPending: asList(state['history']).length,
      gradePending: Duration(microseconds: _gradePendingMicros(state)),
      lastSyncAt: _fromMillis(asInt(state['lastSyncAt'])),
      historyState: state['historyInFlight'] == null ? 'queued' : 'inFlight',
      gradeState: state['gradeInFlight'] == null ? 'queued' : 'inFlight',
    );
  }

  DateTime? _fromMillis(int? value) =>
      value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);

  Future<Map<String, dynamic>> _readState(String owner) async {
    final value = await _readStorage(owner);
    final state = value == null ? <String, dynamic>{} : asMap(value);
    // The old queue captured samples even with reporting disabled and did not
    // record their source. Begin a new reporting window with eligible audio.
    if (!state.containsKey('gradePendingMicros')) {
      if (!state.containsKey('historyLastSyncAt') &&
          state['lastSyncAt'] != null) {
        state['historyLastSyncAt'] = state['lastSyncAt'];
      }
      state.remove('gradePendingSeconds');
      state.remove('gradeInFlight');
      state.remove('gradeRetryAt');
      state.remove('gradeRetryTotal');
      state.remove('gradeQuarantine');
    }
    return state;
  }

  Future<dynamic> _readStorage(String owner) async {
    final file = await _file(owner);
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeState(String owner, Map<String, dynamic> state) async {
    final file = await _file(owner);
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(jsonEncode(state), flush: true);
    await temporary.rename(file.path);
  }

  Future<File> _file(String owner) async {
    final directory =
        _directoryOverride ?? await getApplicationSupportDirectory();
    final safe = base64Url.encode(utf8.encode(owner)).replaceAll('=', '');
    return File('${directory.path}/cloud_sync_$safe.json');
  }
}
