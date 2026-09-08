import 'dart:async';

import '../models/loudness_data.dart';

/// Source/quality scoped metadata. Lookup never owns or waits for playback.
class LoudnessLookup {
  LoudnessLookup({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _cache = <String, LoudnessData>{};
  final _pending = <String, Future<LoudnessData?>>{};
  final _retryAfter = <String, DateTime>{};
  Set<String>? _retainedKeys;

  /// Evict results outside the playback window, including late completions.
  void retainKeys(Set<String> keys) {
    _retainedKeys = Set.of(keys);
    _cache.removeWhere((key, _) => !keys.contains(key));
    _retryAfter.removeWhere((key, _) => !keys.contains(key));
  }

  bool _canRetain(String key) => _retainedKeys?.contains(key) ?? true;

  LoudnessData? get(String key) => _cache[key];

  void put(String key, LoudnessData? data) {
    if (!_canRetain(key) || data?.canNormalize != true) return;
    _cache[key] = data!;
    _retryAfter.remove(key);
  }

  Future<LoudnessData?> resolve(
    String key,
    Future<LoudnessData?> Function() fetch,
  ) {
    final cached = get(key);
    if (cached != null) return Future.value(cached);
    final pending = _pending[key];
    if (pending != null) return pending;
    final retryAfter = _retryAfter[key];
    if (retryAfter != null && _now().isBefore(retryAfter)) {
      return Future.value();
    }
    final future = Future<LoudnessData?>.sync(fetch)
        .then(
          (data) {
            put(key, data);
            if (_canRetain(key) && get(key) == null) {
              _retryAfter[key] = _now().add(const Duration(minutes: 1));
            }
            return data?.canNormalize == true ? data : null;
          },
          onError: (Object error, StackTrace stack) {
            if (_canRetain(key)) {
              _retryAfter[key] = _now().add(const Duration(minutes: 1));
            }
            Error.throwWithStackTrace(error, stack);
          },
        )
        .whenComplete(() {
          _pending.remove(key);
        });
    _pending[key] = future;
    return future;
  }
}

/// A per-source admission window: late metadata stays cached for the next play,
/// never leaking into this play via session/other automatic callbacks.
class PlaybackLoudness {
  PlaybackLoudness({Duration Function()? elapsed})
    : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedGetter;

  final Duration Function() _elapsed;
  static const window = Duration(seconds: 3);
  int generation = 0;
  String? key;
  LoudnessData? data;
  Duration? _startedAt;
  bool _applied = false;

  bool get _withinWindow =>
      _startedAt == null || _elapsed() - _startedAt! < window;

  /// Session creation can be late too. A first boost after the deadline is
  /// bypassed; already-applied gain can be restored on session recreation.
  LoudnessData? get applicableData => _applied || _withinWindow ? data : null;

  void markApplied(int expectedGeneration) {
    if (generation == expectedGeneration) _applied = true;
  }

  void begin(String sourceKey, LoudnessData? initial) {
    generation++;
    key = sourceKey;
    data = initial?.canNormalize == true ? initial : null;
    _startedAt = null;
    _applied = false;
  }

  void startPlayback() {
    _startedAt ??= _elapsed();
  }

  bool accept(String sourceKey, int expectedGeneration, LoudnessData? value) {
    if (sourceKey != key ||
        expectedGeneration != generation ||
        value?.canNormalize != true) {
      return false;
    }
    final startedAt = _startedAt;
    if (startedAt != null && _elapsed() - startedAt >= window) return false;
    data = value;
    return true;
  }

  /// An explicit setting change starts a new opportunity, not a new song.
  void reopen(LoudnessData? cached) {
    generation++;
    _startedAt = _elapsed();
    if (cached?.canNormalize == true) data = cached;
  }
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}
