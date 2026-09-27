import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/playback_failure.dart';
import 'package:kgka_music_hl/services/playback_phase.dart';

PlaybackPhaseInput input({
  bool hasSong = true,
  bool isPreparing = false,
  bool isPlaying = true,
  bool isBuffering = false,
  bool isSeeking = false,
  bool hasError = false,
  bool stalled = false,
}) => PlaybackPhaseInput(
  hasSong: hasSong,
  isPreparing: isPreparing,
  isPlaying: isPlaying,
  isBuffering: isBuffering,
  isSeeking: isSeeking,
  hasError: hasError,
  stalled: stalled,
);

void main() {
  group('resolvePlaybackPhase', () {
    test('error outranks every transport detail', () {
      expect(
        resolvePlaybackPhase(
          input(hasError: true, isPreparing: true, isSeeking: true),
        ),
        PlaybackPhase.error,
      );
    });

    test('no song is idle even while a load intent is resolving', () {
      expect(
        resolvePlaybackPhase(input(hasSong: false, isPreparing: true)),
        PlaybackPhase.idle,
      );
    });

    test('loading outranks seeking and buffering', () {
      expect(
        resolvePlaybackPhase(
          input(isPreparing: true, isSeeking: true, isBuffering: true),
        ),
        PlaybackPhase.loading,
      );
    });

    test('seeking outranks stalled and buffering', () {
      expect(
        resolvePlaybackPhase(
          input(isSeeking: true, stalled: true, isBuffering: true),
        ),
        PlaybackPhase.seeking,
      );
    });

    test('buffering outranks stalled: a slow network is not an anomaly', () {
      expect(
        resolvePlaybackPhase(input(stalled: true, isBuffering: true)),
        PlaybackPhase.buffering,
      );
    });

    test('stalled only applies while playing', () {
      expect(
        resolvePlaybackPhase(input(stalled: true, isPlaying: true)),
        PlaybackPhase.stalled,
      );
      expect(
        resolvePlaybackPhase(input(stalled: true, isPlaying: false)),
        PlaybackPhase.paused,
      );
    });

    test('buffering outranks playing and paused', () {
      expect(
        resolvePlaybackPhase(input(isBuffering: true)),
        PlaybackPhase.buffering,
      );
      expect(
        resolvePlaybackPhase(input(isBuffering: true, isPlaying: false)),
        PlaybackPhase.buffering,
      );
    });

    test('the happy path is playing and a ready idle player is paused', () {
      expect(resolvePlaybackPhase(input()), PlaybackPhase.playing);
      expect(
        resolvePlaybackPhase(input(isPlaying: false)),
        PlaybackPhase.paused,
      );
    });

    test('every phase is reachable', () {
      final reached = <PlaybackPhase>{
        resolvePlaybackPhase(input(hasError: true)),
        resolvePlaybackPhase(input(hasSong: false)),
        resolvePlaybackPhase(input(isPreparing: true)),
        resolvePlaybackPhase(input(isSeeking: true)),
        resolvePlaybackPhase(input(stalled: true)),
        resolvePlaybackPhase(input(isBuffering: true)),
        resolvePlaybackPhase(input()),
        resolvePlaybackPhase(input(isPlaying: false)),
      };
      expect(reached, hasLength(PlaybackPhase.values.length));
    });
  });

  group('playback failure classification', () {
    test('every failure class has a recovery action', () {
      for (final failure in PlaybackFailure.values) {
        expect(
          playbackRecoveryForFailure[failure],
          isNotNull,
          reason: '${failure.name} 缺少恢复动作',
        );
      }
    });

    test('every failure class has a user-visible message', () {
      for (final failure in PlaybackFailure.values) {
        expect(playbackFailureMessage(failure), isNotEmpty);
      }
    });

    test('empty URLs degrade quality while device loss never auto-resumes', () {
      expect(
        playbackRecoveryForFailure[PlaybackFailure.resolveEmpty],
        PlaybackRecovery.degradeQuality,
      );
      expect(
        playbackRecoveryForFailure[PlaybackFailure.deviceLost],
        PlaybackRecovery.pauseAndReport,
      );
    });

    test('a corrupt local file switches to the network, not to a rollback', () {
      expect(
        playbackRecoveryForFailure[PlaybackFailure.localCorrupt],
        PlaybackRecovery.forceNetwork,
      );
    });
  });
}
