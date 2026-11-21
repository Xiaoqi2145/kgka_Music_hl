import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/listening_session.dart';

ListeningSample _sample(
  int positionMs,
  int elapsedMs, {
  bool canAdvance = true,
  double speed = 1,
}) => ListeningSample(
  position: Duration(milliseconds: positionMs),
  elapsed: Duration(milliseconds: elapsedMs),
  canAdvance: canAdvance,
  speed: speed,
);

void main() {
  test('counts verified media progress after the first baseline', () {
    final tracker = ListeningSessionTracker();
    expect(tracker.add(_sample(0, 0)), Duration.zero);
    expect(tracker.add(_sample(1000, 1000)), const Duration(seconds: 1));
    expect(tracker.media, const Duration(seconds: 1));
    expect(tracker.qualified, isTrue);
  });

  test('pause and buffering break continuity without adding time', () {
    final tracker = ListeningSessionTracker();
    tracker.add(_sample(1000, 1000));
    tracker.add(_sample(2000, 2000));
    expect(tracker.add(_sample(3000, 3000, canAdvance: false)), Duration.zero);
    expect(tracker.media, const Duration(seconds: 1));
    expect(tracker.add(_sample(4000, 4000)), Duration.zero);
  });

  test('seek jump establishes a new baseline instead of being counted', () {
    final tracker = ListeningSessionTracker();
    tracker.add(_sample(1000, 1000));
    expect(tracker.add(_sample(61000, 2000)), Duration.zero);
    expect(tracker.media, Duration.zero);
    expect(tracker.add(_sample(62000, 3000)), const Duration(seconds: 1));
  });

  test('double speed counts wall-clock time, not twice the display jump', () {
    final tracker = ListeningSessionTracker();
    tracker.add(_sample(0, 0, speed: 2));
    final added = tracker.add(_sample(2000, 1000, speed: 2));
    expect(added, const Duration(seconds: 1));
  });

  test('long gaps are conservative and start a fresh baseline', () {
    final tracker = ListeningSessionTracker();
    tracker.add(_sample(0, 0));
    expect(tracker.add(_sample(1000, 5000)), Duration.zero);
    expect(tracker.add(_sample(2000, 6000)), const Duration(seconds: 1));
  });
}
