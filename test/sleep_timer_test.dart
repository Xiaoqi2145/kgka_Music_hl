import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Player implements AudioPlayer {
  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  Duration get position => Duration.zero;
  @override
  PlaybackEvent playbackEvent = PlaybackEvent();
  @override
  int? get androidAudioSessionId => null;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Stream<SequenceState> get sequenceStateStream => const Stream.empty();
  @override
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  SequenceState sequenceState = SequenceState(
    sequence: const [],
    currentIndex: null,
    shuffleIndices: const [],
    shuffleModeEnabled: false,
    loopMode: LoopMode.off,
  );
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handler implements MusicAudioHandler {
  int pauses = 0;

  @override
  final AudioPlayer audioPlayer = _Player();

  @override
  void Function(bool)? onPlaybackIntent;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    Future<void> Function(Duration)? onSeek,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  Stream<PositionDiscontinuity> get boundaryStream => const Stream.empty();

  @override
  Future<void> close() async {}

  @override
  Future<void> seekDirect(Duration position) async {}

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements MusicApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'settings.add_listening_time_enabled': false,
      'settings.resume_playback_enabled': false,
    });
    support = await Directory.systemTemp.createTemp('kamusic-sleep-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => support.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (support.existsSync()) await support.delete(recursive: true);
  });

  test('countdown only notifies sleep timer listeners', () async {
    final controller = PlayerController(_Api(), _Handler());
    var controllerNotifications = 0;
    var countdownNotifications = 0;
    controller.addListener(() => controllerNotifications++);
    controller.sleepTimerRemainingListenable.addListener(
      () => countdownNotifications++,
    );
    addTearDown(() async {
      controller.cancelSleepTimer();
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    await Future<void>.delayed(Duration.zero);
    controllerNotifications = 0;

    controller.setSleepTimer(const Duration(seconds: 3));
    expect(controllerNotifications, 1);
    expect(controller.sleepTimerRemaining, const Duration(seconds: 3));

    controllerNotifications = 0;
    countdownNotifications = 0;
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 100));
    expect(controllerNotifications, 0);
    expect(countdownNotifications, greaterThan(0));
    expect(
      controller.sleepTimerRemaining,
      lessThan(const Duration(seconds: 3)),
    );
  });

  test('timer expiry pauses playback once and clears the countdown', () async {
    final handler = _Handler();
    final controller = PlayerController(_Api(), handler);
    addTearDown(() async {
      controller.cancelSleepTimer();
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    await Future<void>.delayed(Duration.zero);

    controller.setSleepTimer(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1, milliseconds: 150));

    expect(handler.pauses, 1);
    expect(controller.sleepTimerRemaining, isNull);
    expect(controller.sleepTimerRemainingListenable.value, isNull);
    expect(controller.sleepTimerUiListenable.value.active, isFalse);
  });

  test('finish-song selection is kept before a timer is started', () async {
    final controller = PlayerController(_Api(), _Handler());
    addTearDown(() async {
      controller.cancelSleepTimer();
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    await Future<void>.delayed(Duration.zero);

    var globalNotifications = 0;
    controller.addListener(() => globalNotifications++);
    controller.updateSleepTimerOption(true);

    expect(globalNotifications, 0);
    expect(controller.sleepTimerUiListenable.value.sheetSelection, isTrue);
    expect(controller.isSleepTimerActive, isFalse);
  });
}
