/// Why a playback attempt did not reach a committed entry.
///
/// This is a **classification of existing behaviour**, not a new control flow:
/// every value maps to a branch `PlayerController._playSong` already takes.
enum PlaybackFailure {
  /// The resolver returned an empty URL for every quality in the ladder.
  resolveEmpty,

  /// A network round trip failed (timeout, DNS, HTTP error).
  resolveNetwork,

  /// The native player refused the source (single-source load not acknowledged).
  loadRejected,

  /// A downloaded/play-cache file was unusable; the local source is invalidated
  /// and the ladder continues on the network.
  localCorrupt,

  /// The output device disappeared.
  deviceLost,

  /// Anything not covered above.
  unknown,
}

/// The recovery action that already exists for each failure class.
enum PlaybackRecovery {
  /// Try the next lower quality in the configured ladder.
  degradeQuality,

  /// Retry the same request (ApiClient already owns bounded retries).
  retry,

  /// Roll back to the previously committed entry and its position.
  rollbackPrevious,

  /// Drop the local source and re-resolve over the network.
  forceNetwork,

  /// Pause and surface the error; never auto-resume on another output.
  pauseAndReport,
}

/// Explicit table so "what happens next" is reviewable in one place instead of
/// being spread across the load state machine.
const playbackRecoveryForFailure = <PlaybackFailure, PlaybackRecovery>{
  PlaybackFailure.resolveEmpty: PlaybackRecovery.degradeQuality,
  PlaybackFailure.resolveNetwork: PlaybackRecovery.retry,
  PlaybackFailure.loadRejected: PlaybackRecovery.rollbackPrevious,
  PlaybackFailure.localCorrupt: PlaybackRecovery.forceNetwork,
  PlaybackFailure.deviceLost: PlaybackRecovery.pauseAndReport,
  PlaybackFailure.unknown: PlaybackRecovery.rollbackPrevious,
};

/// User-visible message per class. Kept here so the wording cannot drift away
/// from the classification.
String playbackFailureMessage(PlaybackFailure failure) => switch (failure) {
  PlaybackFailure.resolveEmpty => '暂时没有可播放地址',
  PlaybackFailure.resolveNetwork => '网络异常，请重试',
  PlaybackFailure.loadRejected => '播放失败，请重试',
  PlaybackFailure.localCorrupt => '本地文件不可用，已切换网络音源',
  PlaybackFailure.deviceLost => '音频设备已断开',
  PlaybackFailure.unknown => '播放失败，请重试',
};
