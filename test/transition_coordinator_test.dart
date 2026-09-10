import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/transition_coordinator.dart';

void main() {
  test('one completion token per playback instance, not per song hash', () {
    final coordinator = TransitionCoordinator();
    for (var i = 0; i < 30; i++) {
      final entry = coordinator.commit(i + 1);
      final lease = coordinator.lease;
      expect(entry.id, i + 1);
      expect(coordinator.consumeCompletion(lease), isTrue);
      expect(coordinator.consumeCompletion(lease), isFalse);
    }
  });
  test('A completion cannot advance B or a repeated A instance', () {
    final coordinator = TransitionCoordinator()..commit(1);
    final a = coordinator.lease;
    coordinator.commit(2);
    expect(coordinator.consumeCompletion(a), isFalse);
    final b = coordinator.lease;
    coordinator.commit(3);
    expect(coordinator.consumeCompletion(a), isFalse);
    expect(coordinator.consumeCompletion(b), isFalse);
    expect(coordinator.consumeCompletion(coordinator.lease), isTrue);
  });
  test('30 seek round trips invalidate every captured end/async lease', () {
    final coordinator = TransitionCoordinator()..commit(1);
    for (var i = 0; i < 30; i++) {
      final oldEnd = coordinator.lease;
      coordinator.seek();
      final atTail = coordinator.lease;
      coordinator.seek();
      expect(coordinator.isCurrent(oldEnd), isFalse);
      expect(coordinator.consumeCompletion(atTail), isFalse);
    }
    expect(coordinator.seekRevision, 60);
    expect(coordinator.consumeCompletion(coordinator.lease), isTrue);
  });
  for (final intent in ['pause', 'next', 'previous', 'queue', 'quality']) {
    test('$intent revokes a pending navigation lease, not entry identity', () {
      final coordinator = TransitionCoordinator()..commit(1);
      final entry = coordinator.committedEntry;
      final lease = coordinator.lease;
      coordinator.invalidateWork();
      expect(coordinator.isCurrent(lease), isFalse);
      expect(coordinator.committedEntry, same(entry));
    });
  }
}
