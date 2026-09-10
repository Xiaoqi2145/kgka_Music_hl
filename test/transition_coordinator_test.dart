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
  test('beginIntent revokes older intents, not committed entries', () {
    final coordinator = TransitionCoordinator()..commit(1);
    final first = coordinator.beginIntent();
    expect(coordinator.isCurrentIntent(first), isTrue);
    final second = coordinator.beginIntent();
    expect(coordinator.isCurrentIntent(first), isFalse);
    expect(coordinator.isCurrentIntent(second), isTrue);
    expect(coordinator.committedEntry?.id, 1);
  });

  test('a queue refresh revokes work leases but never a pending intent', () {
    final coordinator = TransitionCoordinator()..commit(1);
    final intent = coordinator.beginIntent();
    final lease = coordinator.lease;
    // 歌单页后台补拉整张歌单 / 预解析重置：只作废完成与异步租约。
    coordinator.invalidateWork();
    expect(coordinator.isCurrent(lease), isFalse);
    expect(coordinator.isCurrentIntent(intent), isTrue);
    // 显式取消（seek、换音质、暂停）才作废在途的加载意图。
    coordinator.invalidateIntents();
    expect(coordinator.isCurrentIntent(intent), isFalse);
  });

  test('a commit ends its own load intent', () {
    final coordinator = TransitionCoordinator();
    final intent = coordinator.beginIntent();
    expect(coordinator.isCurrentIntent(intent), isTrue);
    coordinator.commit(1);
    expect(coordinator.isCurrentIntent(intent), isFalse);
    expect(coordinator.committedEntry?.id, 1);
  });

  test('a seek revokes a load intent before it touches the player', () {
    final coordinator = TransitionCoordinator()..commit(1);
    final intent = coordinator.beginIntent();
    coordinator.seek();
    expect(coordinator.isCurrentIntent(intent), isFalse);
    expect(coordinator.isCurrent(coordinator.lease), isTrue);
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
