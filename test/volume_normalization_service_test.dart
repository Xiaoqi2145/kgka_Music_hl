import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/loudness_data.dart';
import 'package:kgka_music_hl/services/volume_normalization_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kgka_music_hl/audio_effects');
  const quiet = LoudnessData(lufs: -20);
  const loud = LoudnessData(lufs: -8);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late VolumeNormalizationService service;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    service = VolumeNormalizationService(enabled: true, referenceLufs: -14);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() async {
    await service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'attenuation computes a player gain without waiting for a session',
    () async {
      final gain = await service.applyForTrack(
        audioSessionId: null,
        loudness: loud,
      );
      expect(gain, closeTo(0.501187, 0.00001));
      expect(calls.single.method, 'disableLoudnessEnhancer');
    },
  );

  test(
    'missing session bypasses boost and a later session can apply it',
    () async {
      expect(
        await service.applyForTrack(audioSessionId: null, loudness: quiet),
        1,
      );
      expect(service.currentGain, 1);
      expect(
        await service.applyForTrack(audioSessionId: 42, loudness: quiet),
        greaterThan(1),
      );
      expect(calls.last.arguments['audioSessionId'], 42);
    },
  );

  test(
    'native failure reports bypass rather than a fictitious applied boost',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'enableLoudnessEnhancer') {
          throw PlatformException(code: 'unsupported');
        }
        return null;
      });
      expect(
        await service.applyForTrack(audioSessionId: 42, loudness: quiet),
        1,
      );
      expect(service.currentGain, 1);
      expect(calls.last.method, 'disableLoudnessEnhancer');
    },
  );

  test('latest simultaneous request wins before native work starts', () async {
    final old = service.applyForTrack(audioSessionId: 1, loudness: quiet);
    final latest = service.applyForTrack(audioSessionId: 2, loudness: loud);
    await Future.wait([old, latest]);
    expect(calls.map((c) => c.method), ['disableLoudnessEnhancer']);
    expect(service.currentGain, lessThan(1));
  });

  test(
    'pending old boost cannot run after disable and queued work is coalesced',
    () async {
      final entered = Completer<void>();
      final native = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'enableLoudnessEnhancer') {
          entered.complete();
          await native.future;
        }
        return null;
      });
      final first = service.applyForTrack(audioSessionId: 1, loudness: quiet);
      await entered.future;
      final obsolete = service.applyForTrack(
        audioSessionId: 2,
        loudness: quiet,
      );
      service.enabled = false;
      service.invalidatePending();
      final disabled = service.applyForTrack(
        audioSessionId: 2,
        loudness: quiet,
      );
      native.complete();
      await Future.wait([first, obsolete, disabled]);
      expect(calls.map((c) => c.method), [
        'enableLoudnessEnhancer',
        'disableLoudnessEnhancer',
      ]);
      expect(service.currentGain, 1);
    },
  );

  test(
    'source invalidation skips queued work even with the same song',
    () async {
      final apply = service.applyForTrack(audioSessionId: 1, loudness: quiet);
      service.invalidatePending();
      await apply;
      expect(calls, isEmpty);
      await service.applyForTrack(
        audioSessionId: 1,
        loudness: quiet,
        isCurrent: () => false,
      );
      expect(calls, isEmpty);
    },
  );

  test('half decibel deadband returns bypass consistently', () async {
    expect(
      await service.applyForTrack(
        audioSessionId: 1,
        loudness: const LoudnessData(lufs: -13.8),
      ),
      1,
    );
    expect(service.currentGain, 1);
  });

  test(
    'non Android supports attenuation without native channel calls',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        await service.applyForTrack(audioSessionId: 1, loudness: loud),
        lessThan(1),
      );
      expect(
        await service.applyForTrack(audioSessionId: 1, loudness: quiet),
        1,
      );
      expect(calls, isEmpty);
    },
  );
}
