/// Serializes native audio-session operations; stale requests never start playback.
class AudioFocusGate {
  AudioFocusGate({
    required Future<bool> Function(bool) setActive,
    this.resetBeforeAcquire = true,
  }) : _setActive = setActive;

  /// Android audio_session caches requests; other platforms need no reset.
  final bool resetBeforeAcquire;

  final Future<bool> Function(bool) _setActive;
  Future<void> _tail = Future<void>.value();
  int _generation = 0;

  void invalidate() => ++_generation;

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> acquire() {
    final generation = ++_generation;
    return _enqueue(() async {
      if (generation != _generation) return false;
      if (resetBeforeAcquire && !await _setActive(false)) return false;
      if (generation != _generation) return false;
      final granted = await _setActive(true);
      if (!granted || generation != _generation) {
        // audio_session caches even a denied Android request. Clear it too.
        await _setActive(false);
        return false;
      }
      return true;
    });
  }

  Future<void> release() {
    invalidate();
    return _enqueue(() async {
      await _setActive(false);
    });
  }
}
