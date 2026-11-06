import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';

class _Player implements AudioPlayer {
  final events = StreamController<PlayerEvent>.broadcast(sync: true);
  PlayerEvent _event = PlayerEvent();

  @override
  Stream<PlayerEvent> get playerEventStream => events.stream;

  // Match just_audio: a playing-only event does not reach this stream.
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      events.stream.map((event) => event.playbackEvent).distinct();

  @override
  bool get playing => _event.playing;
  @override
  ProcessingState get processingState => _event.playbackEvent.processingState;
  @override
  Duration get position => _event.playbackEvent.updatePosition;
  @override
  Duration get bufferedPosition => _event.playbackEvent.bufferedPosition;
  @override
  double get speed => 1;

  void emit({required bool playing, ProcessingState? state}) {
    _event = PlayerEvent(
      playing: playing,
      playbackEvent: state == null
          ? _event.playbackEvent
          : PlaybackEvent(processingState: state),
    );
    events.add(_event);
  }

  @override
  Future<void> stop() async =>
      emit(playing: false, state: ProcessingState.idle);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Player player;
  late MusicAudioHandler handler;
  late StreamSubscription<PlaybackState> subscription;
  late List<PlaybackState> states;

  Future<void> drain() => Future<void>.delayed(Duration.zero);

  setUp(() {
    player = _Player();
    handler = MusicAudioHandler(audioPlayer: player);
    states = [];
    subscription = handler.playbackState.listen(states.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await player.events.close();
    await drain();
  });

  test('native playing-only changes update notification controls', () async {
    player.emit(playing: false, state: ProcessingState.ready);
    await drain();
    expect(handler.playbackState.value.playing, isFalse);

    player.emit(playing: true);
    await drain();
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.controls[1], MediaControl.pause);

    player.emit(playing: false);
    await drain();
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);
  });

  test('temporary native idle cannot stop a playing media session', () async {
    player.emit(playing: true, state: ProcessingState.ready);
    await drain();
    states.clear();

    player.emit(playing: true, state: ProcessingState.idle);
    await drain();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.loading,
    );
    player.emit(playing: true, state: ProcessingState.loading);
    player.emit(playing: true, state: ProcessingState.buffering);
    player.emit(playing: true, state: ProcessingState.ready);
    await drain();

    expect(states, isNotEmpty);
    expect(states.every((state) => state.playing), isTrue);
    expect(
      states.any((state) => state.processingState == AudioProcessingState.idle),
      isFalse,
    );
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
  });

  test(
    'cold start stays idle and a real stop clears the media session',
    () async {
      player.emit(playing: false, state: ProcessingState.idle);
      await drain();
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );

      player.emit(playing: true, state: ProcessingState.ready);
      await drain();
      await handler.stop();
      await drain();
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    },
  );

  test('paused and completed states preserve their native meaning', () async {
    player.emit(playing: false, state: ProcessingState.ready);
    await drain();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );

    player.emit(playing: true, state: ProcessingState.completed);
    await drain();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.completed,
    );
  });
}
