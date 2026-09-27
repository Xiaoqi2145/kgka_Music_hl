/// Derived playback phase. **Read-only projection**: every value comes from
/// signals the controller already owns, so this type can never become a
/// seventh implicit state that writes back into the controller.
///
/// Mirrors the `PlaybackCoreState` idea from the EchoMusic analysis, reduced to
/// what just_audio can actually prove:
/// `idle → loading → buffering → playing ⇄ paused → seeking → stalled → error`.
enum PlaybackPhase {
  /// Nothing loaded yet (cold start, or a session cleared by logout).
  idle,

  /// A load intent is resolving/replacing the native source.
  loading,

  /// Native source is ready but not producing samples yet.
  buffering,

  /// Samples are being produced.
  playing,

  /// Ready, not playing, no pending work.
  paused,

  /// A seek/scrub is in flight; position must not be trusted.
  seeking,

  /// Playing but the position has not advanced for [stalledAfter].
  stalled,

  /// A visible failure is on screen.
  error,
}

/// Inputs for [resolvePlaybackPhase]. Plain values keep the rule testable
/// without constructing a controller.
class PlaybackPhaseInput {
  const PlaybackPhaseInput({
    required this.hasSong,
    required this.isPreparing,
    required this.isPlaying,
    required this.isBuffering,
    required this.isSeeking,
    required this.hasError,
    this.stalled = false,
  });

  final bool hasSong;
  final bool isPreparing;
  final bool isPlaying;
  final bool isBuffering;
  final bool isSeeking;
  final bool hasError;
  final bool stalled;
}

/// Priority order is deliberate and total; the first match wins.
///
/// 1. error      — a visible failure outranks any transport detail
/// 2. idle       — nothing committed
/// 3. loading    — a load intent owns the player
/// 4. seeking    — position is not trustworthy while seeking
/// 5. buffering  — ready but starving; explains why progress stopped
/// 6. stalled    — playing, not buffering, yet not progressing
/// 7. playing / paused
PlaybackPhase resolvePlaybackPhase(PlaybackPhaseInput input) {
  if (input.hasError) return PlaybackPhase.error;
  if (!input.hasSong) return PlaybackPhase.idle;
  if (input.isPreparing) return PlaybackPhase.loading;
  if (input.isSeeking) return PlaybackPhase.seeking;
  // Buffering outranks stalled: a long buffer is a *reason* for the missing
  // progress, not an unexplained stall. Reporting it as `stalled` would hide
  // the ordinary "network is slow" case behind an anomaly label.
  if (input.isBuffering) return PlaybackPhase.buffering;
  if (input.isPlaying && input.stalled) return PlaybackPhase.stalled;
  return input.isPlaying ? PlaybackPhase.playing : PlaybackPhase.paused;
}
