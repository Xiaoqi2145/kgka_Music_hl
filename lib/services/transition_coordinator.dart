/// Identity of one committed playback instance, never a song hash.
class PlaybackEntry {
  const PlaybackEntry(this.id, this.loadRevision);
  final int id;
  final int loadRevision;
}

/// A completion/async navigation lease belongs to an entry AND a seek/work epoch.
class TransitionLease {
  const TransitionLease(this.entryId, this.seekRevision, this.requestRevision);
  final int entryId;
  final int seekRevision;
  final int requestRevision;
}

/// One click's load intent. Only the newest intent may pause the player,
/// replace the native source or commit; older intents must exit before
/// touching the player.
class LoadIntent {
  const LoadIntent(this.entryId, this.seekRevision, this.intentRevision);
  final int? entryId;
  final int seekRevision;
  final int intentRevision;
}

/// No timers or playlist indices: only an explicit successful load commits.
/// Structure broadcasts and prefetch responses cannot call commit.
class TransitionCoordinator {
  PlaybackEntry? committedEntry;
  int _entrySerial = 0;
  int seekRevision = 0;
  int requestRevision = 0;
  int intentRevision = 0;
  bool _completionConsumed = false;

  TransitionLease? get lease {
    final entry = committedEntry;
    return entry == null
        ? null
        : TransitionLease(entry.id, seekRevision, requestRevision);
  }

  PlaybackEntry commit(int loadRevision) {
    invalidateWork();
    _completionConsumed = false;
    return committedEntry = PlaybackEntry(++_entrySerial, loadRevision);
  }

  void invalidateWork() => requestRevision++;

  void seek() {
    seekRevision++;
    invalidateWork();
    // A successful seek can start a new end-of-playback attempt for this entry.
    _completionConsumed = false;
  }

  /// Start a new load intent. Every older intent is revoked immediately,
  /// before any player state is touched.
  ///
  /// A load intent is deliberately NOT tied to [requestRevision]: revoking a
  /// pending completion/async lease (queue list refresh, prefetch reset) must
  /// never drop a tap that is still resolving. Only a newer intent, a seek or
  /// an explicit [invalidateIntents] cancels it.
  LoadIntent beginIntent() {
    intentRevision++;
    return LoadIntent(committedEntry?.id, seekRevision, intentRevision);
  }

  /// Cancel every pending load intent without touching the player.
  void invalidateIntents() => intentRevision++;

  bool isCurrentIntent(LoadIntent? value) =>
      value != null &&
      value.entryId == committedEntry?.id &&
      value.seekRevision == seekRevision &&
      value.intentRevision == intentRevision;

  bool isCurrent(TransitionLease? value) =>
      value != null &&
      value.entryId == committedEntry?.id &&
      value.seekRevision == seekRevision &&
      value.requestRevision == requestRevision;

  bool consumeCompletion(TransitionLease? value) {
    if (!isCurrent(value) || _completionConsumed) return false;
    _completionConsumed = true;
    return true;
  }
}
