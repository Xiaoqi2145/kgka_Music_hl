import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../controllers/auth_controller.dart';
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
    Duration? retryUnit,
    Directory? directory,
    DateTime Function()? now,
  }) : _historyUploader = historyUploader ?? api.cloudUploadHistory,
       _gradeUploader = gradeUploader ?? api.cloudGradeUpdate,
       _gradeReader = gradeReader ?? api.cloudGradeInfo,
       _retryUnit = retryUnit ?? const Duration(minutes: 30),
       _directoryOverride = directory,
       _now = now ?? DateTime.now;

  static const syncWindow = Duration(minutes: 30);
  static const historyLimit = 100;
  static const historyMaxAge = Duration(hours: 24);
  static const historyBatch = 20;
  static const gradeBatch = Duration(minutes: 30);
  static const gradeMaxAge = Duration(hours: 24);
  static const unknownIsolation = Duration(hours: 6);

  final AuthController _auth;
  final CloudHistoryUploader _historyUploader;
  final CloudGradeUploader _gradeUploader;
  final CloudTimeReader _gradeReader;
  final Duration _retryUnit;
  final Directory? _directoryOverride;
  final DateTime Function() _now;
  bool _historyEnabled = false;
  bool _gradeEnabled = true;
  bool _foreground = true;
  Future<SyncOutcome>? _inFlight;
  CloudSyncSnapshot _snapshot = const CloudSyncSnapshot();
  int _historyFailureCount = 0;
  int _gradeFailureCount = 0;
  String? _owner;

  CloudSyncSnapshot get snapshot => _snapshot;
  bool get historyEnabled => _historyEnabled;
  bool get gradeEnabled => _gradeEnabled;
  void notifySettingsChanged() => notifyListeners();

  String? get _storageKeyOwner {
    final userId = _auth.session?.userId?.trim();
    if (userId == null || userId.isEmpty) return null;
    return '${AppConfig.effectiveBaseUrl}|$userId';
  }

  void configure({bool? historyEnabled, bool? gradeEnabled}) {
    _historyEnabled = historyEnabled ?? _historyEnabled;
    _gradeEnabled = gradeEnabled ?? _gradeEnabled;
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
  }

  Future<void> setHistoryEnabled(bool enabled) async {
    final owner = _storageKeyOwner;
    if (owner == null) return;
    await _ensureOwner(owner);
    if (!_isKnownOwner(owner)) return;
    _historyEnabled = enabled;
    await _persist();
    await _updateSnapshotFromDisk(owner);
    notifySettingsChanged();
  }

  Future<void> setGradeEnabled(bool enabled) async {
    final owner = _storageKeyOwner;
    if (owner == null) return;
    await _ensureOwner(owner);
    if (!_isKnownOwner(owner)) return;
    _gradeEnabled = enabled;
    await _persist();
    await _updateSnapshotFromDisk(owner);
    notifySettingsChanged();
  }

  Future<void> restore() async {
    final owner = _storageKeyOwner;
    if (owner == null) return;
    _owner = owner;
    final raw = await _readStorage(owner);
    if (raw == null) return;
    final map = asMap(raw);
    _historyEnabled = map['historyEnabled'] == true;
    _gradeEnabled = map['gradeEnabled'] != false;
    notifyListeners();
  }

  Future<void> enqueueHistory(Song song, {required DateTime playedAt}) async {
    if (!_historyEnabled) return;
    final owner = _storageKeyOwner;
    if (owner == null) return;
    final songId = cloudSongId(song);
    if (songId == null || songId.isEmpty) return;
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
    _updateSnapshot(state);
  }

  Future<void> enqueueGradeTime(Duration duration) async {
    if (!_gradeEnabled || duration <= Duration.zero) return;
    final owner = _storageKeyOwner;
    if (owner == null) return;
    await _ensureOwner(owner);
    if (!_isKnownOwner(owner)) return;
    final restored = await _readState(owner);
    if (_gradeEnabled != (restored['gradeEnabled'] != false)) return;
    final state = restored;
    final existing = asInt(state['gradePendingSeconds']) ?? 0;
    final maxSeconds = gradeMaxAge.inSeconds;
    state['gradePendingSeconds'] = (existing + duration.inSeconds).clamp(
      0,
      maxSeconds,
    );
    await _writeState(owner, state);
    _updateSnapshot(state);
  }

  Future<void> onAccountChanged() async {
    final owner = _storageKeyOwner;
    if (owner == null) {
      _owner = null;
      _snapshot = const CloudSyncSnapshot();
      notifyListeners();
      return;
    }
    if (_owner == owner) return;
    _owner = owner;
    await restore();
    await _updateSnapshotFromDisk(owner);
    notifyListeners();
  }

  Future<SyncOutcome> maybeSync() async {
    final owner = _storageKeyOwner;
    if (owner == null) return SyncOutcome.deferred;
    await _ensureOwner(owner);
    if (!_isKnownOwner(owner)) return SyncOutcome.deferred;
    final pending = _inFlight;
    if (pending != null) return pending;
    if (!_foreground) {
      return SyncOutcome.deferred;
    }
    final state = await _readState(owner);
    final historyEnabled = state['historyEnabled'] == true;
    final gradeEnabled = state['gradeEnabled'] != false;
    if (!historyEnabled && !gradeEnabled) {
      return SyncOutcome.deferred;
    }
    final future = _syncOwner(owner);
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<SyncOutcome> _syncOwner(String owner) async {
    if (!_isKnownOwner(owner)) return SyncOutcome.deferred;
    final state = await _readState(owner);
    final last = asInt(state['lastSyncAt']);
    if (last != null &&
        _now().millisecondsSinceEpoch - last < syncWindow.inMilliseconds) {
      return SyncOutcome.deferred;
    }
    var outcome = SyncOutcome.idle;
    if (state['historyEnabled'] == true) {
      final result = await _syncHistory(owner, state);
      if (result == SyncOutcome.sent) {
        outcome = SyncOutcome.sent;
      } else if (result != SyncOutcome.idle && outcome == SyncOutcome.idle) {
        outcome = result;
      }
    }
    if (state['gradeEnabled'] != false) {
      final result = await _syncGrade(owner, state);
      if (result == SyncOutcome.sent) {
        if (outcome == SyncOutcome.idle) outcome = SyncOutcome.sent;
      } else if (result != SyncOutcome.idle && outcome == SyncOutcome.idle) {
        outcome = result;
      }
    }
    if (outcome == SyncOutcome.sent || outcome == SyncOutcome.idle) {
      state['lastSyncAt'] = _now().millisecondsSinceEpoch;
    }
    await _writeState(owner, state);
    _updateSnapshot(state);
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
    final pending = asInt(state['gradePendingSeconds']) ?? 0;
    if (pending <= 0) return SyncOutcome.idle;
    final inFlight = state['gradeInFlight'];
    if (inFlight is Map) {
      state['gradeQuarantine'] = true;
      state['gradePendingSeconds'] = 0;
      await _writeState(owner, state);
      return SyncOutcome.unknownResult;
    }
    final retryAt = asInt(state['gradeRetryAt']);
    if (retryAt != null && _now().millisecondsSinceEpoch < retryAt) {
      return SyncOutcome.backoff;
    }
    if (pending < gradeBatch.inSeconds) return SyncOutcome.deferred;
    final attempts = asInt(state['gradeRetryTotal']) ?? 0;
    if (attempts >= 1) return SyncOutcome.deferred;
    final batchSeconds = gradeBatch.inSeconds;
    state['gradeInFlight'] = {
      'seconds': batchSeconds,
      'at': _now().millisecondsSinceEpoch,
    };
    await _writeState(owner, state);
    try {
      final baseline = _gradeBaseline(await _gradeReader());
      final result = await _gradeUploader(
        dSec: baseline,
        diffSec: batchSeconds,
      );
      if (!_isAccepted(result)) {
        state['gradeInFlight'] = null;
        _gradeFailureCount++;
        state['gradeRetryTotal'] = attempts + 1;
        state['gradeRetryAt'] = _retryAt(
          _gradeFailureCount,
        ).millisecondsSinceEpoch;
        await _writeState(owner, state);
        return SyncOutcome.retryableFailure;
      }
      state['gradeInFlight'] = null;
      state['gradePendingSeconds'] = pending - batchSeconds;
      state['gradeRetryAt'] = null;
      state['gradeRetryTotal'] = 0;
      _gradeFailureCount = 0;
      await _writeState(owner, state);
      return SyncOutcome.sent;
    } catch (error) {
      debugPrint('[KA Music][cloud-sync] grade result unknown: $error');
      return SyncOutcome.unknownResult;
    }
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
    _owner = owner;
    await restore();
    await _updateSnapshotFromDisk(owner);
  }

  Future<void> _updateSnapshotFromDisk(String owner) async {
    _updateSnapshot(await _readState(owner));
  }

  void _updateSnapshot(Map<String, dynamic> state) {
    _snapshot = CloudSyncSnapshot(
      historyPending: asList(state['history']).length,
      gradePending: Duration(seconds: asInt(state['gradePendingSeconds']) ?? 0),
      lastSyncAt: _fromMillis(asInt(state['lastSyncAt'])),
      historyState: state['historyInFlight'] == null ? 'queued' : 'inFlight',
      gradeState: state['gradeInFlight'] == null ? 'queued' : 'inFlight',
    );
  }

  DateTime? _fromMillis(int? value) =>
      value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);

  Future<Map<String, dynamic>> _readState(String owner) async {
    final value = await _readStorage(owner);
    return value == null ? <String, dynamic>{} : asMap(value);
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
    await temporary.writeAsString(jsonEncode(state));
    if (file.existsSync()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> _persist() async {
    final owner = _storageKeyOwner;
    if (owner == null) return;
    if (!_isKnownOwner(owner)) return;
    final state = await _readState(owner);
    state['historyEnabled'] = _historyEnabled;
    state['gradeEnabled'] = _gradeEnabled;
    await _writeState(owner, state);
  }

  Future<File> _file(String owner) async {
    final directory =
        _directoryOverride ?? await getApplicationSupportDirectory();
    final safe = base64Url.encode(utf8.encode(owner)).replaceAll('=', '');
    return File('${directory.path}/cloud_sync_$safe.json');
  }
}
