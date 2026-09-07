import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/audio_focus_gate.dart';

void main() {
  test(
    'non-Android activation does not deactivate a playing session',
    () async {
      final calls = <bool>[];
      final gate = AudioFocusGate(
        resetBeforeAcquire: false,
        setActive: (active) async {
          calls.add(active);
          return true;
        },
      );
      expect(await gate.acquire(), isTrue);
      await gate.release();
      expect(calls, [true, false]);
    },
  );

  test('each play clears the cached request before requesting focus', () async {
    final calls = <bool>[];
    final gate = AudioFocusGate(
      setActive: (active) async {
        calls.add(active);
        return true;
      },
    );
    expect(await gate.acquire(), isTrue);
    expect(await gate.acquire(), isTrue);
    await gate.release();
    expect(calls, [false, true, false, true, false]);
  });

  test(
    'denial is not playback permission and clears the cached request',
    () async {
      final calls = <bool>[];
      final gate = AudioFocusGate(
        setActive: (active) async {
          calls.add(active);
          return !active;
        },
      );
      expect(await gate.acquire(), isFalse);
      expect(calls, [false, true, false]);
    },
  );

  test('failed deactivation never attempts activation', () async {
    final calls = <bool>[];
    final gate = AudioFocusGate(
      setActive: (active) async {
        calls.add(active);
        return false;
      },
    );
    expect(await gate.acquire(), isFalse);
    expect(calls, [false]);
  });

  test(
    'pause during activation rejects and releases late focus grant',
    () async {
      final calls = <bool>[];
      final activating = Completer<void>();
      final granted = Completer<bool>();
      final gate = AudioFocusGate(
        setActive: (active) async {
          calls.add(active);
          if (active) {
            activating.complete();
            return granted.future;
          }
          return true;
        },
      );
      final play = gate.acquire();
      await activating.future;
      final pause = gate.release();
      granted.complete(true);
      expect(await play, isFalse);
      await pause;
      expect(calls, [false, true, false, false]);
    },
  );

  test(
    'interruption invalidates pending activation without an extra request',
    () async {
      final deactivating = Completer<void>();
      final deactivated = Completer<bool>();
      final calls = <bool>[];
      final gate = AudioFocusGate(
        setActive: (active) {
          calls.add(active);
          deactivating.complete();
          return deactivated.future;
        },
      );
      final play = gate.acquire();
      await deactivating.future;
      gate.invalidate();
      deactivated.complete(true);
      expect(await play, isFalse);
      expect(calls, [false]);
    },
  );

  test('latest simultaneous play wins', () async {
    final calls = <bool>[];
    final gate = AudioFocusGate(
      setActive: (active) async {
        calls.add(active);
        return true;
      },
    );
    final first = gate.acquire();
    final second = gate.acquire();
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(calls, [false, true]);
  });

  test('a platform error does not poison subsequent requests', () async {
    var fail = true;
    final gate = AudioFocusGate(
      setActive: (active) async {
        if (fail) {
          fail = false;
          throw StateError('platform unavailable');
        }
        return true;
      },
    );
    await expectLater(gate.acquire(), throwsStateError);
    expect(await gate.acquire(), isTrue);
  });
}
