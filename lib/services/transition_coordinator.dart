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

/// No timers or playlist indices: only an explicit successful load commits.
/// Structure broadcasts and prefetch responses cannot call commit.
class TransitionCoordinator {
  PlaybackEntry? committedEntry;
  int _entrySerial = 0;
  int seekRevision = 0;
  int requestRevision = 0;
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
