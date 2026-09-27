import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/loudness_data.dart';
import 'package:kgka_music_hl/services/playback_loudness.dart';

void main() {
  test(
    'window eviction rejects late results but returns data for persistence',
    () async {
      final lookup = LoudnessLookup();
      const data = LoudnessData(lufs: -9);
      lookup.retainKeys({'A', 'B', 'C'});
      for (final key in ['A', 'B', 'C']) {
        lookup.put(key, data);
      }
      final response = Completer<LoudnessData?>();
      final pending = lookup.resolve('late', () => response.future);
      lookup.retainKeys({'B', 'C', 'D'});
      response.complete(data);
      expect(await pending, data);
      expect(lookup.get('late'), isNull);
      expect(lookup.get('A'), isNull);
      expect(lookup.get('B'), data);
      expect(lookup.get('C'), data);
      lookup.put('D', data);
      lookup.put('A', data);
      expect(lookup.get('D'), data);
      expect(lookup.get('A'), isNull);
    },
  );

  const data = LoudnessData(lufs: -9);

  test('loading time does not consume the three second playback window', () {
    var time = Duration.zero;
    final state = PlaybackLoudness(elapsed: () => time);
    state.begin('song:standard', null);
    time = const Duration(seconds: 20);
    state.startPlayback();
    time += const Duration(seconds: 2);
    expect(state.accept(state.key!, state.generation, data), isTrue);
    expect(state.data, data);
  });

  test(
    'late metadata is cached but cannot leak through a session callback',
    () async {
      var time = Duration.zero;
      final state = PlaybackLoudness(elapsed: () => time);
      final lookup = LoudnessLookup();
      final response = Completer<LoudnessData?>();
      state.begin('song:standard', null);
      final generation = state.generation;
      final request = lookup.resolve(state.key!, () => response.future);
      state.startPlayback();
      time = const Duration(seconds: 20);
      response.complete(data);
      expect(state.accept(state.key!, generation, await request), isFalse);
      expect(state.data, isNull);
      expect(lookup.get(state.key!), data);
      // Automatic callbacks only see state.data; the next playback uses cache.
      state.begin(state.key!, lookup.get(state.key!));
      expect(state.data, data);
    },
  );

  test('window closes at three seconds and is not extended by resume', () {
    var time = Duration.zero;
    final state = PlaybackLoudness(elapsed: () => time);
    state.begin('A', null);
    state.startPlayback();
    time = const Duration(seconds: 3);
    state.startPlayback();
    expect(state.accept('A', state.generation, data), isFalse);
    state.reopen(data);
    expect(state.data, data);
    expect(state.accept('A', state.generation, data), isTrue);
  });

  test('A to B to A and quality changes reject old generations', () {
    final state = PlaybackLoudness();
    state.begin('A:standard', null);
    final old = state.generation;
    state.begin('B:standard', null);
    expect(state.accept('A:standard', old, data), isFalse);
    state.begin('A:standard', null);
    expect(state.accept('A:standard', old, data), isFalse);
    final standard = state.generation;
    state.begin('A:lossless', null);
    expect(state.accept('A:standard', standard, data), isFalse);
    expect(state.data, isNull);
  });

  test(
    'late session bypasses first gain but restores previously applied gain',
    () {
      var time = Duration.zero;
      final state = PlaybackLoudness(elapsed: () => time);
      state.begin('A', data);
      state.startPlayback();
      time = const Duration(seconds: 20);
      expect(state.applicableData, isNull);
      state.reopen(data);
      expect(state.applicableData, data);
      state.markApplied(state.generation);
      time += const Duration(seconds: 20);
      expect(state.applicableData, data);
      state.begin('B', null);
      expect(state.applicableData, isNull);
    },
  );

  test('invalid metadata never replaces valid metadata', () {
    final state = PlaybackLoudness()..begin('A', data);
    expect(state.accept('A', state.generation, const LoudnessData()), isFalse);
    expect(state.data, data);
  });

  test('lookup coalesces pending requests and prefers cached data', () async {
    final lookup = LoudnessLookup();
    final response = Completer<LoudnessData?>();
    var calls = 0;
    Future<LoudnessData?> fetch() {
      calls++;
      return response.future;
    }

    final first = lookup.resolve('source:A:standard', fetch);
    final second = lookup.resolve('source:A:standard', fetch);
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    response.complete(data);
    expect(await first, data);
    expect(await lookup.resolve('source:A:standard', fetch), data);
    expect(calls, 1);
    expect(lookup.get('source:A:lossless'), isNull);
    expect(lookup.get('other:A:standard'), isNull);
  });

  test(
    'missing metadata and errors back off without poisoning retries',
    () async {
      var now = DateTime(2026);
      final lookup = LoudnessLookup(now: () => now);
      var calls = 0;
      Future<LoudnessData?> missing() async {
        calls++;
        return null;
      }

      expect(await lookup.resolve('A', missing), isNull);
      expect(await lookup.resolve('A', missing), isNull);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      await expectLater(
        lookup.resolve('A', () async => throw StateError('offline')),
        throwsStateError,
      );
      expect(await lookup.resolve('A', missing), isNull);
      now = now.add(const Duration(minutes: 1));
      expect(await lookup.resolve('A', () async => data), data);
    },
  );

  test(
    'an authoritative miss is remembered as a negative cache entry',
    () async {
      var now = DateTime(2026);
      final lookup = LoudnessLookup(now: () => now);
      expect(lookup.isKnownUnnormalizable('A'), isFalse);
      var calls = 0;
      Future<LoudnessData?> missing() async {
        calls++;
        return null;
      }

      expect(await lookup.resolve('A', missing), isNull);
      expect(lookup.isKnownUnnormalizable('A'), isTrue);
      expect(lookup.get('A'), isNull);
      // Second call inside the backoff window never reaches the network.
      expect(await lookup.resolve('A', missing), isNull);
      expect(calls, 1);
      // A usable response clears both the negative entry and the backoff.
      lookup.put('A', data);
      expect(lookup.isKnownUnnormalizable('A'), isFalse);
      expect(lookup.get('A'), data);
    },
  );

  test('put(null) is a no-op so local cache misses stay unmarked', () {
    final lookup = LoudnessLookup();
    lookup.put('A', null);
    expect(lookup.isKnownUnnormalizable('A'), isFalse);
    lookup.put('B', const LoudnessData());
    expect(lookup.isKnownUnnormalizable('B'), isFalse);
    expect(lookup.get('B'), isNull);
  });

  test(
    'markMissing alone suppresses a repeat resolve (backoff path)',
    () async {
      var now = DateTime(2026);
      final lookup = LoudnessLookup(now: () => now);
      lookup.markMissing('A');
      var calls = 0;
      Future<LoudnessData?> fetch() async {
        calls++;
        return data;
      }

      expect(await lookup.resolve('A', fetch), isNull);
      expect(calls, 0, reason: 'markMissing 必须同时写入退避，否则 resolve 仍会打网络');
      now = now.add(const Duration(minutes: 1));
      expect(await lookup.resolve('A', fetch), data);
      expect(calls, 1);
    },
  );

  test('isKnownUnnormalizable alone reports the negative entry', () {
    final lookup = LoudnessLookup();
    lookup.markMissing('A');
    expect(lookup.isKnownUnnormalizable('A'), isTrue);
    expect(lookup.get('A'), isNull);
  });

  test('negative entries are evicted with the playback window', () async {
    final lookup = LoudnessLookup();
    lookup.retainKeys({'A', 'B'});
    lookup.markMissing('A');
    lookup.markMissing('B');
    expect(lookup.isKnownUnnormalizable('A'), isTrue);
    lookup.retainKeys({'B'});
    expect(lookup.isKnownUnnormalizable('A'), isFalse);
    expect(lookup.isKnownUnnormalizable('B'), isTrue);
  });

  test('a miss outside the retained window is not remembered', () {
    final lookup = LoudnessLookup();
    lookup.retainKeys({'A'});
    lookup.markMissing('B');
    expect(lookup.isKnownUnnormalizable('B'), isFalse);
  });
}
