import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';

class _Player implements AudioPlayer {
  final events = StreamController<PlayerEvent>.broadcast(sync: true);
  final speeds = StreamController<double>.broadcast(sync: true);
  final discontinuities = StreamController<PositionDiscontinuity>.broadcast(
    sync: true,
  );
  PlayerEvent _event = PlayerEvent();
  Duration _pausedPosition = Duration.zero;

  @override
  Stream<PlayerEvent> get playerEventStream => events.stream;
  @override
  Stream<double> get speedStream => speeds.stream;
  @override
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      discontinuities.stream;

  // Match just_audio: a playing-only event does not reach this stream.
  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      events.stream.map((event) => event.playbackEvent).distinct();

  @override
  bool get playing => _event.playing;
  @override
  ProcessingState get processingState => _event.playbackEvent.processingState;
  @override
  Duration get position {
    final event = _event.playbackEvent;
    if (!_event.playing) return _pausedPosition;
    if (event.processingState != ProcessingState.ready ||
        event.duration == null) {
      return event.updatePosition;
    }
    final projected =
        event.updatePosition + DateTime.now().difference(event.updateTime);
    return projected <= event.duration! ? projected : event.duration!;
  }

  @override
  Duration get bufferedPosition => _event.playbackEvent.bufferedPosition;
  @override
  double speed = 1;

  @override
  PlayerEvent get playerEvent => _event;

  void emit({
    required bool playing,
    ProcessingState? state,
    Duration? position,
    Duration? bufferedPosition,
    DateTime? updateTime,
  }) {
    _event = PlayerEvent(
      playing: playing,
      playbackEvent: _event.playbackEvent.copyWith(
        processingState: state,
        updatePosition: position,
        bufferedPosition: bufferedPosition,
        updateTime: updateTime,
      ),
    );
    _pausedPosition = _event.playbackEvent.updatePosition;
    events.add(_event);
  }

  @override
  Future<void> stop() async =>
      emit(playing: false, state: ProcessingState.idle);

  @override
  Future<void> dispose() async {}

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
    await handler.close();
    await player.events.close();
    await player.speeds.close();
    await player.discontinuities.close();
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

  test(
    'native position and buffer polling do not republish media state',
    () async {
      final start = DateTime(2026, 1, 1, 12);
      player.emit(
        playing: true,
        state: ProcessingState.ready,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        updateTime: start,
      );
      await drain();
      states.clear();

      for (var second = 1; second <= 12; second++) {
        player.emit(
          playing: true,
          state: ProcessingState.ready,
          position: Duration(seconds: second),
          bufferedPosition: Duration(seconds: second + 1),
          updateTime: start.add(Duration(seconds: second)),
        );
      }
      await drain();

      expect(states, isEmpty);
      expect(handler.playbackState.value.updatePosition, Duration.zero);
      expect(handler.playbackState.value.updateTime, start);

      player.emit(
        playing: true,
        state: ProcessingState.buffering,
        position: const Duration(seconds: 13),
        bufferedPosition: const Duration(seconds: 20),
        updateTime: start.add(const Duration(seconds: 13)),
      );
      await drain();
      expect(states, hasLength(1));
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.buffering,
      );
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 13),
      );
    },
  );

  test('pause publishes the projected position to the media session', () async {
    final start = DateTime(2026, 1, 1, 12);
    player.emit(
      playing: true,
      state: ProcessingState.ready,
      position: Duration.zero,
      updateTime: start,
    );
    await drain();
    expect(handler.playbackState.value.updatePosition, Duration.zero);

    // just_audio.pause() broadcasts the projected position even though the
    // previous ready snapshot still anchored the seek bar at zero.
    final pausedAt = const Duration(seconds: 37);
    player.emit(
      playing: false,
      state: ProcessingState.ready,
      position: pausedAt,
      updateTime: DateTime.now(),
    );
    await drain();

    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1], MediaControl.play);
    expect(handler.playbackState.value.updatePosition, pausedAt);
    expect(handler.playbackState.value.position, pausedAt);
  });

  test('seek and speed changes publish a new position baseline', () async {
    final start = DateTime(2026, 1, 1, 12);
    player.emit(
      playing: true,
      state: ProcessingState.ready,
      position: Duration.zero,
      updateTime: start,
    );
    await drain();
    states.clear();

    final seeked = PlaybackEvent(
      processingState: ProcessingState.ready,
      updatePosition: const Duration(seconds: 42),
      updateTime: start.add(const Duration(seconds: 1)),
    );
    player.discontinuities.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.seek,
        PlaybackEvent(
          processingState: ProcessingState.ready,
          updatePosition: Duration.zero,
          updateTime: start,
        ),
        seeked,
      ),
    );
    await drain();
    expect(states, hasLength(1));
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 42),
    );

    player.speed = 1.5;
    player.speeds.add(1.5);
    await drain();
    expect(states, hasLength(2));
    expect(handler.playbackState.value.speed, 1.5);
  });
}
