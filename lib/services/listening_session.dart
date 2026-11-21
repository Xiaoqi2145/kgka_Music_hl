/// A sample from the native player at a single instant.
///
/// [position] is media time. [elapsed] must come from a monotonic clock so
/// system wall-clock changes cannot inflate or erase listening time.
class ListeningSample {
  const ListeningSample({
    required this.position,
    required this.elapsed,
    required this.canAdvance,
    this.speed = 1,
  });

  final Duration position;
  final Duration elapsed;
  final bool canAdvance;
  final double speed;
}

/// Accumulates locally verified media playback for one listening session.
///
/// This class deliberately knows nothing about cloud reporting. It establishes
/// a fresh baseline around pauses, buffering, seeks, track changes and speed
/// changes, so an extrapolated progress bar alone can never add time.
class ListeningSessionTracker {
  ListeningSessionTracker({
    this.maxGap = const Duration(seconds: 3),
    this.maxAdvance = const Duration(seconds: 2),
    this.maxPositionAge = const Duration(seconds: 3),
  });

  final Duration maxGap;
  final Duration maxAdvance;
  final Duration maxPositionAge;

  ListeningSample? _anchor;
  Duration? _lastElapsed;
  Duration _media = Duration.zero;
  bool _counted = false;

  Duration get media => _media;
  bool get qualified => _counted;

  /// Returns the newly verified media duration for this sample.
  Duration add(ListeningSample sample) {
    final previous = _anchor;
    if (!sample.canAdvance ||
        sample.position < Duration.zero ||
        !sample.speed.isFinite ||
        sample.speed <= 0) {
      _anchor = null;
      _lastElapsed = null;
      return Duration.zero;
    }
    if (previous == null ||
        !previous.canAdvance ||
        (previous.speed - sample.speed).abs() > 0.001) {
      _lastElapsed = sample.elapsed;
      _anchor = sample;
      return Duration.zero;
    }

    final wall = sample.elapsed - previous.elapsed;
    final sinceLast = _lastElapsed == null
        ? wall
        : sample.elapsed - _lastElapsed!;
    _lastElapsed = sample.elapsed;
    final position = sample.position - previous.position;
    if (wall <= Duration.zero ||
        position <= Duration.zero ||
        wall > maxGap ||
        sinceLast > maxGap ||
        position > maxAdvance) {
      _lastElapsed = sample.elapsed;
      _anchor = sample;
      return Duration.zero;
    }

    final mediaUs = (position.inMicroseconds / sample.speed).floor();
    final verified = mediaUs < wall.inMicroseconds
        ? Duration(microseconds: mediaUs)
        : wall;
    _anchor = sample;
    if (verified <= Duration.zero) return Duration.zero;
    _media += verified;
    if (!_counted && _media >= const Duration(seconds: 1)) {
      _counted = true;
    }
    return verified;
  }

  /// Stop the current sample chain without losing accumulated media time.
  void breakContinuity() {
    _anchor = null;
    _lastElapsed = null;
  }

  /// Drop a baseline that is too old to prove what happened since.
  void expireIfOlderThan(Duration elapsed) {
    final anchor = _anchor;
    if (anchor != null && elapsed - anchor.elapsed > maxPositionAge) {
      _anchor = null;
      _lastElapsed = null;
    }
  }

  /// A pause, seek or speed change invalidates all in-flight samples.
  void restartAt(ListeningSample sample) {
    _anchor = sample.canAdvance ? sample : null;
    _lastElapsed = sample.elapsed;
  }
}
