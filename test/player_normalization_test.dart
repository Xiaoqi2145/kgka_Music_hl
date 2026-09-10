import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/models/loudness_data.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';

class _Player implements AudioPlayer {
  final volumes = <double>[];
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  bool playing = false;
  @override
  Duration get position => Duration.zero;
  @override
  int? get currentIndex => sequenceState.currentIndex;
  final indices = StreamController<int?>.broadcast(sync: true);
  final sequences = StreamController<SequenceState>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  @override
  SequenceState sequenceState = SequenceState(
    sequence: [],
    currentIndex: null,
    shuffleIndices: [],
    shuffleModeEnabled: false,
    loopMode: LoopMode.off,
  );
  @override
  Stream<SequenceState> get sequenceStateStream => sequences.stream;
  void emitSequence(List<IndexedAudioSource> sources, int index) {
    sequenceState = sequenceState.copyWith(
      sequence: sources,
      currentIndex: index,
    );
    sequences.add(sequenceState);
    indices.add(sequenceState.currentIndex);
  }

  @override
  int? get androidAudioSessionId => 42;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => indices.stream;
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handler implements MusicAudioHandler {
  @override
  final _Player audioPlayer = _Player();
  final playbackDone = Completer<void>();
  int plays = 0;
  @override
  void Function(bool)? onPlaybackIntent;
  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}
  @override
  void detachTransportControls() {}
  @override
  void invalidatePendingPlay() {}
  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    audioPlayer.processingState = ProcessingState.ready;
    audioPlayer.emitSequence([AudioSource.uri(Uri.parse(url), tag: song)], 0);
  }

  Completer<void>? removal;
  bool failRemoval = false;
  @override
  Future<void> appendPlaylistEntry(Song song, String url) async {
    audioPlayer.emitSequence([
      ...audioPlayer.sequenceState.sequence,
      AudioSource.uri(Uri.parse(url), tag: song),
    ], audioPlayer.currentIndex!);
  }

  @override
  Future<void> removePlaylistEntryAt(int index) async {
    if (failRemoval) throw StateError('remove failed');
    // Native index notification arrives before remove's acknowledgement.
    await Future<void>.delayed(Duration.zero);
    final sources = [...audioPlayer.sequenceState.sequence]..removeAt(index);
    audioPlayer.emitSequence(
      sources,
      (audioPlayer.currentIndex! - 1).clamp(0, sources.length),
    );
    await removal?.future;
  }

  @override
  void setCurrentMediaItem(Song song) {}

  @override
  Future<void> play() {
    plays++;
    audioPlayer.playing = true;
    return playbackDone.future;
  }

  @override
  Future<void> close() async {
    if (!playbackDone.isCompleted) playbackDone.complete();
    await audioPlayer.indices.close();
    await audioPlayer.sequences.close();
    await audioPlayer.positions.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements MusicApi {
  @override
  Future<List<LyricLine>> lyrics(
    Song song, {
    bool Function()? isCancelled,
  }) async => [];
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async => PlayUrl(
    url: 'https://example.invalid/song.mp3',
    hash: song.hash,
    loudness: LoudnessData(lufs: song.hash == 'B' ? -6 : -8),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends PlayerController {
  _Controller(super.api, super.handler);
  @override
  Future<void> loadLyrics(Song song, {bool force = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  const effects = MethodChannel('kgka_music_hl/audio_effects');
  const song = Song(id: '1', title: 'test', artist: 'artist', hash: 'A');

  test(
    'play and quality reload finish while playback and native effects remain pending',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings.volume_normalization_enabled': true,
        'settings.volume_normalization_ref_lufs': -14.0,
        'settings.add_listening_time_enabled': false,
        'settings.resume_playback_enabled': false,
      });
      final native = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(effects, (call) async {
        if (call.method == 'disableLoudnessEnhancer') await native.future;
        return null;
      });
      final support = await Directory.systemTemp.createTemp(
        'kamusic-norm-test-',
      );
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => support.path,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathProvider, null);
        await support.delete(recursive: true);
      });
      final handler = _Handler();
      final controller = _Controller(_Api(), handler);
      // Drain settings restoration before playback.
      await Future<void>.delayed(Duration.zero);
      await controller.playSong(song).timeout(const Duration(seconds: 2));
      expect(handler.plays, 1);
      expect(handler.playbackDone.isCompleted, isFalse);
      expect(native.isCompleted, isFalse);
      expect(controller.isPreparing, isFalse);
      controller.isPlaying = true;
      final other = AudioQuality.values.firstWhere(
        (q) => q != controller.audioQuality,
      );
      await controller
          .setAudioQuality(other, reloadCurrent: true)
          .timeout(const Duration(seconds: 2));
      expect(handler.plays, 2);
      expect(controller.isPreparing, isFalse);
      expect(controller.errorMessage, isNull);
      expect(handler.playbackDone.isCompleted, isFalse);
      native.complete();
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.volumes.last, closeTo(0.501187, 0.00001));
      await controller.flushPersistence();
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      messenger.setMockMethodCallHandler(effects, null);
    },
  );
  for (final mode in [0, 1, 2]) {
    final failRemoval = mode == 1;
    final replaceDuringTrim = mode == 2;
    test(
      'natural transition survives trim (failure=$failRemoval, replacement=$replaceDuringTrim)',
      () async {
        SharedPreferences.setMockInitialValues({
          'settings.volume_normalization_enabled': true,
          'settings.volume_normalization_ref_lufs': -14.0,
          'settings.add_listening_time_enabled': false,
          'settings.resume_playback_enabled': false,
        });
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(effects, (_) async => null);
        final support = await Directory.systemTemp.createTemp(
          'kamusic-trim-test-',
        );
        const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
        messenger.setMockMethodCallHandler(
          pathProvider,
          (_) async => support.path,
        );
        final handler = _Handler()..failRemoval = failRemoval;
        final controller = _Controller(_Api(), handler);
        addTearDown(() async {
          if (handler.removal?.isCompleted == false) {
            handler.removal!.complete();
          }
          await controller.flushPersistence();
          controller.dispose();
          await Future<void>.delayed(Duration.zero);
          messenger.setMockMethodCallHandler(effects, null);
          messenger.setMockMethodCallHandler(pathProvider, null);
          await support.delete(recursive: true);
        });
        Future<void> drain() async {
          for (var i = 0; i < 10; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        }

        await drain();
        const next = Song(id: '2', title: 'next', artist: 'artist', hash: 'B');
        await controller.playSong(song, queue: [song, next]);
        controller.isPlaying = true;
        controller.duration = const Duration(seconds: 100);
        handler.audioPlayer.positions.add(const Duration(seconds: 80));
        await drain();
        expect(handler.audioPlayer.sequenceState.sequence, hasLength(2));
        handler.removal = Completer<void>();
        final seen = <String?>[];
        controller.addListener(() => seen.add(controller.currentSong?.hash));
        handler.audioPlayer.volumes.clear();
        final oldSnapshot = handler.audioPlayer.sequenceState;
        handler.audioPlayer.emitSequence([
          ...handler.audioPlayer.sequenceState.sequence,
        ], 1);
        await drain();
        expect(controller.currentSong?.hash, 'B');
        expect(seen, isNot(contains('A')));
        expect(handler.audioPlayer.volumes.last, closeTo(0.398107, 0.00001));
        expect(
          handler.audioPlayer.volumes,
          everyElement(closeTo(0.398107, 0.00001)),
        );
        final count = handler.audioPlayer.volumes.length;
        // A buffered obsolete snapshot and repeated B snapshots must not reopen
        // the source/window or schedule more normalization work.
        handler.audioPlayer.sequences.add(oldSnapshot);
        for (var i = 0; i < 30; i++) {
          handler.audioPlayer.emitSequence([
            ...handler.audioPlayer.sequenceState.sequence,
          ], handler.audioPlayer.currentIndex!);
        }
        await drain();
        expect(controller.currentSong?.hash, 'B');
        expect(handler.audioPlayer.volumes.length, count);
        if (replaceDuringTrim) {
          const replacement = Song(
            id: '3',
            title: 'replacement',
            artist: 'artist',
            hash: 'C',
          );
          await controller.playSong(replacement, queue: [replacement]);
          await drain();
        }
        handler.removal!.complete();
        await drain();
        expect(controller.currentSong?.hash, replaceDuringTrim ? 'C' : 'B');
        expect(
          handler.audioPlayer.sequenceState.sequence.last.tag,
          isA<Song>().having(
            (song) => song.hash,
            'hash',
            replaceDuringTrim ? 'C' : 'B',
          ),
        );
      },
    );
  }
}
