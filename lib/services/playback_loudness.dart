import 'dart:async';

import '../models/loudness_data.dart';

/// Source/quality scoped metadata. Lookup never owns or waits for playback.
class LoudnessLookup {
  LoudnessLookup({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _cache = <String, LoudnessData>{};
  final _pending = <String, Future<LoudnessData?>>{};
  final _retryAfter = <String, DateTime>{};
  final _unnormalizable = <String>{};
  Set<String>? _retainedKeys;

  /// Evict results outside the playback window, including late completions.
  void retainKeys(Set<String> keys) {
    _retainedKeys = Set.of(keys);
    _cache.removeWhere((key, _) => !keys.contains(key));
    _retryAfter.removeWhere((key, _) => !keys.contains(key));
    _unnormalizable.removeWhere((key) => !keys.contains(key));
  }

  bool _canRetain(String key) => _retainedKeys?.contains(key) ?? true;

  LoudnessData? get(String key) => _cache[key];

  /// A key whose response carried no usable loudness. Distinguishing
  /// "known to be unnormalizable" from "not asked yet" is what stops the
  /// hydration path from re-requesting the same song forever.
  bool isKnownUnnormalizable(String key) => _unnormalizable.contains(key);

  /// Store a usable lookup result and clear any negative entry.
  ///
  /// A null / unusable [data] is a **no-op**: callers hand in null both when
  /// the server has no loudness for a song and when a local cache entry simply
  /// carries none. Only [resolve] knows which of the two happened, so only it
  /// may mark a song as unnormalizable.
  void put(String key, LoudnessData? data) {
    if (!_canRetain(key) || data?.canNormalize != true) return;
    _unnormalizable.remove(key);
    _cache[key] = data!;
    _retryAfter.remove(key);
  }

  /// The authoritative source (a network round trip) answered without usable
  /// loudness. Remember it, otherwise every later caller triggers a fresh
  /// request for a value that cannot change.
  void markMissing(String key) {
    if (!_canRetain(key)) return;
    _unnormalizable.add(key);
    _retryAfter[key] = _now().add(const Duration(minutes: 1));
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
            // We asked the server, so a miss is authoritative: cache the
            // negative result instead of asking again on the next call.
            if (data?.canNormalize == true) {
              put(key, data);
              return data;
            }
            markMissing(key);
            return null;
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
  PlaybackLoudness({Duration Function()? elapsed, int Function()? generation})
    : _elapsed = elapsed ?? (Stopwatch()..start()).elapsedGetter,
      _generation = generation;

  final Duration Function() _elapsed;

  /// When supplied, the pipeline generation is owned elsewhere (see
  /// `TransitionCoordinator.generation`) so the two can never drift apart.
  /// Without it the window keeps its own counter.
  final int Function()? _generation;
  int _localGeneration = 0;
  static const window = Duration(seconds: 3);
  int get generation => _generation?.call() ?? _localGeneration;
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

  /// Advance the pipeline generation. Only meaningful when this window owns
  /// its counter; when generation is injected the caller bumps it instead.
  void begin(String sourceKey, LoudnessData? initial) {
    if (_generation == null) _localGeneration++;
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
    if (_generation == null) _localGeneration++;
    _startedAt = _elapsed();
    if (cached?.canNormalize == true) data = cached;
  }
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}
