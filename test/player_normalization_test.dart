import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
  int? get currentIndex => 0;
  @override
  int? get androidAudioSessionId => 42;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
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
  }

  @override
  Future<void> play() {
    plays++;
    audioPlayer.playing = true;
    return playbackDone.future;
  }

  @override
  Future<void> close() async {
    if (!playbackDone.isCompleted) playbackDone.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements MusicApi {
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async => PlayUrl(
    url: 'https://example.invalid/song.mp3',
    hash: song.hash,
    loudness: const LoudnessData(lufs: -8),
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
}
