import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
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
  Duration get position => playbackEvent.updatePosition;
  @override
  PlaybackEvent playbackEvent = PlaybackEvent();
  final events = StreamController<PlaybackEvent>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;
  int clock = 0;
  void emitNative(
    ProcessingState state, {
    Duration position = Duration.zero,
    Duration duration = const Duration(seconds: 100),
    DateTime? time,
  }) {
    processingState = state;
    playbackEvent = PlaybackEvent(
      processingState: state,
      updatePosition: position,
      duration: duration,
      currentIndex: 0,
      updateTime: time ?? DateTime(2026).add(Duration(milliseconds: ++clock)),
    );
    events.add(playbackEvent);
  }

  @override
  Future<void> stop() async {
    playing = false;
    processingState = ProcessingState.idle;
  }

  @override
  int? get currentIndex => sequenceState.currentIndex;
  final indices = StreamController<int?>.broadcast(sync: true);
  final sequences = StreamController<SequenceState>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  @override
  SequenceState sequenceState = SequenceState(
    sequence: [],
    currentIndex: null,
    shuffleIndices: [],
    shuffleModeEnabled: false,
    loopMode: LoopMode.off,
  );
  @override
  Stream<SequenceState> get sequenceStateStream => sequences.stream;
  void emitSequence(List<IndexedAudioSource> sources, int index) {
    sequenceState = sequenceState.copyWith(
      sequence: sources,
      currentIndex: index,
    );
    sequences.add(sequenceState);
    indices.add(sequenceState.currentIndex);
  }

  @override
  int? get androidAudioSessionId => 42;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => indices.stream;
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
  final loads = <Song>[];
  final media = <Song>[];
  int appends = 0;
  int removals = 0;
  Completer<void>? loadGate;
  bool failLoad = false;
  /// 原生替换次数（模拟真实 handler 里"暂停 + setAudioSources"的原子操作）。
  int replacements = 0;
  /// 每次原生替换发生时的已提交条目，用于校验不变量 1。
  final commitAtReplace = <int?>[];
  /// 按歌曲 hash 持续失败，用于替换失败回滚测试。
  final Set<String> failingHashes = <String>{};
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
  void invalidatePendingPlay() {}
  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
    Duration start = Duration.zero,
    int? loadSerial,
  }) async {
    // 真实 handler 在替换前先暂停：测试里同步模拟，便于检查不变量。
    audioPlayer.playing = false;
    replacements++;
    onNativeReplace?.call(song, start);
    await loadGate?.future;
    if (failLoad || failingHashes.contains(song.hash)) {
      failLoad = false;
      throw StateError('load failed');
    }
    loads.add(song);
    audioPlayer.emitSequence([AudioSource.uri(Uri.parse(url), tag: song)], 0);
    audioPlayer.emitNative(ProcessingState.ready);
  }

  void Function(Song song, Duration start)? onNativeReplace;

  Completer<void>? removal;
  bool failRemoval = false;
  Future<void> appendPlaylistEntry(Song song, String url) async {
    appends++;
    audioPlayer.emitSequence([
      ...audioPlayer.sequenceState.sequence,
      AudioSource.uri(Uri.parse(url), tag: song),
    ], audioPlayer.currentIndex!);
  }

  Future<void> removePlaylistEntryAt(int index) async {
    removals++;
    if (failRemoval) throw StateError('remove failed');
    // Native index notification arrives before remove's acknowledgement.
    await Future<void>.delayed(Duration.zero);
    final sources = [...audioPlayer.sequenceState.sequence]..removeAt(index);
    audioPlayer.emitSequence(
      sources,
      (audioPlayer.currentIndex! - 1).clamp(0, sources.length),
    );
    await removal?.future;
  }

  @override
  void setCurrentMediaItem(Song song) {
    media.add(song);
  }

  @override
  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {}
  @override
  Future<void> replaceSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {}
  @override
  Future<void> pause() async {
    onPlaybackIntent?.call(false);
    audioPlayer.playing = false;
  }

  @override
  Future<void> stop() async {
    onPlaybackIntent?.call(false);
    audioPlayer.playing = false;
    audioPlayer.processingState = ProcessingState.idle;
  }

  @override
  Future<void> seekDirect(Duration position) => seek(position);
  @override
  Future<void> seek(Duration position) async {
    audioPlayer.emitNative(ProcessingState.ready, position: position);
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
    await audioPlayer.indices.close();
    await audioPlayer.sequences.close();
    await audioPlayer.positions.close();
    await audioPlayer.events.close();
    await audioPlayer.durations.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements MusicApi {
  final requests = <String>[];
  final responses = <String, Completer<PlayUrl>>{};
  final lyricResponses = <String, Completer<List<LyricLine>>>{};
  @override
  Future<List<LyricLine>> lyrics(
    Song song, {
    bool Function()? isCancelled,
  }) async => lyricResponses[song.hash]?.future ?? <LyricLine>[];
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    requests.add(song.hash);
    return responses[song.hash]?.future ??
        PlayUrl(
          url: 'https://example.invalid/song.mp3',
          hash: song.hash,
          loudness: LoudnessData(lufs: song.hash == 'B' ? -6 : -8),
        );
  }

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
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
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
  const b = Song(id: '2', title: 'B', artist: 'artist', hash: 'B');
  const c = Song(id: '3', title: 'C', artist: 'artist', hash: 'C');
  const d = Song(id: '4', title: 'D', artist: 'artist', hash: 'D');
  late _Handler handler;
  late _Api api;
  late PlayerController controller;
  Future<void> drain() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> setup({bool realLyrics = false}) async {
    SharedPreferences.setMockInitialValues({
      'settings.volume_normalization_enabled': true,
      'settings.volume_normalization_ref_lufs': -14.0,
      'settings.add_listening_time_enabled': false,
      'settings.resume_playback_enabled': false,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(effects, (_) async => null);
    final support = await Directory.systemTemp.createTemp(
      'kamusic-transition-',
    );
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathProvider, (_) async => support.path);
    handler = _Handler();
    api = _Api();
    controller = realLyrics
        ? PlayerController(api, handler)
        : _Controller(api, handler);
    addTearDown(() async {
      await controller.flushPersistence();
      controller.dispose();
      await drain();
      messenger.setMockMethodCallHandler(effects, null);
      messenger.setMockMethodCallHandler(pathProvider, null);
      await support.delete(recursive: true);
    });
    await drain();
    await controller.playSong(song, queue: [song, b, c, d]);
    controller.isPlaying = true;
    await drain();
  }

  void tail() {
    handler.audioPlayer.emitNative(
      ProcessingState.ready,
      position: const Duration(seconds: 80),
    );
    handler.audioPlayer.positions.add(const Duration(seconds: 80));
  }

  void complete() => handler.audioPlayer.emitNative(
    ProcessingState.completed,
    position: const Duration(seconds: 100),
  );

  test(
    'prefetch stays pure across two-phase add/remove and old platform index',
    () async {
      await setup();
      final entry = controller.currentEntryId;
      final generation = controller.normalizationGeneration;
      final aSource = handler.audioPlayer.sequenceState.currentSource!;
      tail();
      await drain();
      expect(api.requests.where((s) => s == 'B'), hasLength(1));
      expect(handler.audioPlayer.sequenceState.sequence, hasLength(1));
      handler.audioPlayer.volumes.clear();
      final lines = controller.lyrics;
      final sources = [b, c, d]
          .map(
            (s) =>
                AudioSource.uri(Uri.parse('https://example.invalid/x'), tag: s),
          )
          .toList();
      // Dependency's Dart structure first, old native index later; neither is proof.
      handler.audioPlayer.emitSequence([aSource, sources[0]], 0);
      handler.audioPlayer.emitSequence([sources[0]], 1);
      handler.audioPlayer.emitSequence(sources, 1);
      handler.audioPlayer.emitSequence(sources, 2);
      await drain();
      expect(controller.currentSong, song);
      expect(controller.currentEntryId, entry);
      expect(controller.normalizationGeneration, generation);
      expect(controller.lyrics, same(lines));
      expect(handler.media, [song]);
      expect(handler.audioPlayer.volumes, isEmpty);
      expect(handler.appends, 0);
      expect(handler.removals, 0);
      // Restore the actual single-source snapshot, then a real end advances once.
      handler.audioPlayer.emitSequence([aSource], 0);
      complete();
      complete();
      await drain();
      expect(handler.loads, [song, b]);
      expect(handler.media, [song, b]);
      expect(controller.currentSong, b);
      expect(controller.normalizationGeneration, generation + 1);
      expect(handler.audioPlayer.volumes.last, closeTo(0.398107, 0.00001));
    },
  );

  test(
    'old tail position duration completed snapshots cannot skip B',
    () async {
      await setup();
      tail();
      await drain();
      complete();
      final oldEnd = handler.audioPlayer.playbackEvent;
      await drain();
      final entry = controller.currentEntryId;
      for (var i = 0; i < 30; i++) {
        handler.audioPlayer.events.add(oldEnd);
        handler.audioPlayer.positions.add(const Duration(seconds: 100));
        handler.audioPlayer.durations.add(const Duration(seconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(controller.currentSong, b);
      expect(controller.currentEntryId, entry);
      expect(controller.duration, const Duration(seconds: 100));
      expect(handler.loads, [song, b]);
      expect(api.requests.where((s) => s == 'C'), isEmpty);
    },
  );

  test('no estimated end while ready or buffering in final 750ms', () async {
    await setup();
    handler.audioPlayer.emitNative(
      ProcessingState.ready,
      position: const Duration(milliseconds: 99750),
    );
    handler.audioPlayer.positions.add(const Duration(seconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    handler.audioPlayer.emitNative(
      ProcessingState.buffering,
      position: const Duration(seconds: 100),
    );
    await drain();
    expect(handler.loads, [song]);
    complete();
    await drain();
    expect(handler.loads, [song, b]);
  });

  test(
    'recorded 20:18 response timeline does not commit before native end',
    () async {
      await setup();
      final response = Completer<PlayUrl>();
      api.responses['B'] = response;
      handler.audioPlayer.emitNative(
        ProcessingState.ready,
        position: const Duration(seconds: 80),
        time: DateTime(2026, 1, 1, 20, 18, 27, 231),
      );
      handler.audioPlayer.positions.add(const Duration(seconds: 80));
      await drain();
      final generation = controller.normalizationGeneration;
      response.complete(
        const PlayUrl(
          url: 'https://example.invalid/b',
          hash: 'B',
          loudness: LoudnessData(lufs: -6),
        ),
      );
      handler.audioPlayer.emitNative(
        ProcessingState.ready,
        position: const Duration(seconds: 87),
        time: DateTime(2026, 1, 1, 20, 18, 34, 236),
      );
      await drain();
      handler.audioPlayer.emitNative(
        ProcessingState.ready,
        position: const Duration(seconds: 99),
        time: DateTime(2026, 1, 1, 20, 18, 49, 384),
      );
      handler.audioPlayer.positions.add(const Duration(seconds: 99));
      await drain();
      expect(handler.loads, [song]);
      expect(handler.media, [song]);
      expect(controller.normalizationGeneration, generation);
      handler.audioPlayer.emitNative(
        ProcessingState.completed,
        position: const Duration(seconds: 100),
        time: DateTime(2026, 1, 1, 20, 18, 50),
      );
      await drain();
      expect(handler.loads, [song, b]);
    },
  );

  for (final action in [
    'seek',
    'next',
    'previous',
    'pause',
    'queue',
    'quality',
  ]) {
    test('late prefetch remains harmless after $action', () async {
      await setup();
      final response = Completer<PlayUrl>();
      api.responses['B'] = response;
      tail();
      await drain();
      if (action == 'seek') {
        controller.previewSeek(const Duration(seconds: 100));
        complete();
        await controller.seek(const Duration(seconds: 10));
      } else if (action == 'next') {
        api.responses.remove('B');
        await controller.next();
      } else if (action == 'previous') {
        await controller.previous();
      } else if (action == 'pause') {
        await handler.pause();
        controller.isPlaying = false;
      } else if (action == 'queue') {
        await controller.replaceQueue([song, c, d]);
      } else {
        await controller.setAudioQuality(
          AudioQuality.high,
          reloadCurrent: true,
        );
      }
      await drain();
      final entry = controller.currentEntryId;
      final plays = handler.plays;
      response.complete(
        const PlayUrl(url: 'https://example.invalid/late', hash: 'B'),
      );
      await drain();
      expect(controller.currentEntryId, entry);
      expect(handler.plays, plays);
      expect(handler.appends, 0);
      expect(handler.removals, 0);
      if (action == 'pause') {
        complete();
        await drain();
        expect(handler.plays, plays);
        api.responses.remove('B');
        controller.isPlaying = true;
        handler.audioPlayer.playing = true;
        await controller.next();
        await drain();
        expect(
          api.requests.where((s) => s == 'B'),
          hasLength(1),
          reason: 'pause preserves cached candidate',
        );
      }
    });
  }

  test(
    'single loop and repeated queue entries get distinct playback identities',
    () async {
      await setup();
      await controller.playSong(song, queue: [song, song, b]);
      final first = controller.currentEntryId;
      complete();
      await drain();
      expect(controller.currentSong, song);
      expect(controller.currentIndex, 1);
      expect(controller.currentEntryId, isNot(first));
      complete();
      await drain();
      expect(controller.currentSong, b);
      controller.playbackMode = PlaybackMode.singleLoop;
      final before = controller.currentEntryId;
      complete();
      await drain();
      expect(controller.currentSong, b);
      expect(controller.currentEntryId, isNot(before));
    },
  );

  test(
    'shuffle prefetch fixes one candidate and consumes it exactly once',
    () async {
      await setup();
      controller.playbackMode = PlaybackMode.shuffle;
      tail();
      await drain();
      final selected = api.requests.last;
      for (var i = 0; i < 10; i++) {
        tail();
        await drain();
      }
      expect(api.requests, hasLength(2));
      complete();
      complete();
      await drain();
      expect(controller.currentSong?.hash, selected);
      expect(handler.loads, hasLength(2));
      expect(api.requests, hasLength(2));
    },
  );

  test(
    'load ack is the single UI metadata lyrics and gain commit boundary',
    () async {
      await setup();
      handler.loadGate = Completer<void>();
      final generation = controller.normalizationGeneration;
      final pending = controller.playSong(b);
      await drain();
      expect(controller.currentSong, song);
      expect(handler.media, [song]);
      expect(controller.normalizationGeneration, generation);
      handler.loadGate!.complete();
      await pending;
      await drain();
      expect(controller.currentSong, b);
      expect(handler.media, [song, b]);
      expect(controller.normalizationGeneration, generation + 1);
    },
  );

  test('pause during load prevents stale commit and playback', () async {
    await setup();
    handler.loadGate = Completer<void>();
    final pending = controller.playSong(b);
    await drain();
    await handler.pause();
    handler.loadGate!.complete();
    await pending;
    await drain();
    expect(handler.media, [song]);
    expect(handler.plays, 1);
    expect(controller.currentSong, song);
  });

  test(
    'prepared URL load failure falls back without premature UI commit',
    () async {
      await setup();
      tail();
      await drain();
      handler.failLoad = true;
      await controller.next();
      await drain();
      expect(controller.errorMessage, isNull);
      expect(handler.media, [song, b]);
      expect(handler.loads, [song, b]);
      expect(api.requests.where((s) => s == 'B'), hasLength(2));
    },
  );

  test(
    'manual next preserves shuffle choice while prefetch is still pending',
    () async {
      await setup();
      controller.playbackMode = PlaybackMode.shuffle;
      final responses = {
        for (final key in ['B', 'C', 'D']) key: Completer<PlayUrl>(),
      };
      api.responses.addAll(responses);
      tail();
      await drain();
      final selected = api.requests.last;
      // A new explicit load resolves separately, but must keep the chosen song.
      api.responses.clear();
      await controller.next();
      await drain();
      expect(controller.currentSong?.hash, selected);
      for (final item in responses.entries) {
        item.value.complete(
          PlayUrl(url: 'https://example.invalid/late', hash: item.key),
        );
      }
      await drain();
      expect(handler.loads, hasLength(2));
    },
  );

  test(
    'canceled completion lookup cannot block completion of a newer entry',
    () async {
      await setup();
      final late = Completer<PlayUrl>();
      api.responses['B'] = late;
      complete();
      await drain();
      await controller.playSong(c);
      await drain();
      complete();
      await drain();
      expect(controller.currentSong, d);
      late.complete(
        const PlayUrl(url: 'https://example.invalid/late', hash: 'B'),
      );
      await drain();
      expect(handler.media, [song, c, d]);
    },
  );

  test(
    'queue replacement cancels a next URL lookup already in progress',
    () async {
      await setup();
      final late = Completer<PlayUrl>();
      api.responses['B'] = late;
      final pending = controller.next();
      await drain();
      await controller.replaceQueue([song, c]);
      late.complete(
        const PlayUrl(url: 'https://example.invalid/late', hash: 'B'),
      );
      await pending;
      await drain();
      expect(handler.media, [song]);
      await controller.next();
      await drain();
      expect(handler.media, [song, c]);
    },
  );

  test(
    'a late native snapshot older than load acknowledgement is rejected',
    () async {
      await setup();
      complete();
      final oldEnd = handler.audioPlayer.playbackEvent;
      await drain();
      handler.audioPlayer.playbackEvent = oldEnd;
      handler.audioPlayer.processingState = ProcessingState.completed;
      handler.audioPlayer.events.add(oldEnd);
      await drain();
      expect(handler.media, [song, b]);
    },
  );

  for (final seconds in [7, 15]) {
    test(
      '$seconds-second API response is cache-only until native completion',
      () async {
        await setup();
        final response = Completer<PlayUrl>();
        api.responses['B'] = response;
        final generation = controller.normalizationGeneration;
        tail();
        await drain();
        for (var i = 0; i < seconds; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          handler.audioPlayer.emitNative(
            ProcessingState.ready,
            position: Duration(seconds: 80 + i),
          );
          handler.audioPlayer.positions.add(Duration(seconds: 80 + i));
          expect(handler.media, [song]);
        }
        response.complete(
          const PlayUrl(url: 'https://example.invalid/b', hash: 'B'),
        );
        await drain();
        expect(controller.normalizationGeneration, generation);
        expect(handler.loads, [song]);
        complete();
        await drain();
        expect(handler.media, [song, b]);
      },
    );
  }

  test('out-of-order lyrics only update the committed entry', () async {
    await setup(realLyrics: true);
    final aLyrics = Completer<List<LyricLine>>();
    api.lyricResponses['A'] = aLyrics;
    final oldRequest = controller.loadLyrics(song, force: true);
    final bLyrics = Completer<List<LyricLine>>();
    api.lyricResponses['B'] = bLyrics;
    await controller.playSong(b);
    bLyrics.complete(const [LyricLine(time: Duration.zero, text: 'B lyrics')]);
    await drain();
    aLyrics.complete(const [LyricLine(time: Duration.zero, text: 'old A')]);
    await oldRequest;
    await drain();
    expect(controller.lyrics.single.text, 'B lyrics');
    expect(controller.currentSong, b);
  });

  // ===== 换歌单"点两次才播放"的回归测试（见
  // diagnostics/playlist-switch-two-tap-fix-plan.md 第 6 节） =====

  Song copyOf(Song other) => Song(
    id: other.id,
    title: other.title,
    artist: other.artist,
    hash: other.hash,
    source: other.source,
  );

  PlayUrl urlFor(String hash) => PlayUrl(
    url: 'https://example.invalid/${hash.toLowerCase()}',
    hash: hash,
    loudness: LoudnessData(lufs: -8),
  );

  test('a second tap while the first is resolving commits only the newest', () async {
    await setup();
    final entry = controller.currentEntryId;
    final gate = Completer<PlayUrl>();
    api.responses['B'] = gate;
    final first = controller.playSong(b, queue: [song, b, c]);
    await drain();
    // 第一次点击仍在 resolve：播放器没有被暂停，也没有被替换。
    expect(handler.audioPlayer.playing, isTrue);
    expect(handler.replacements, 1, reason: '只有 setup 那次原生替换');
    expect(handler.loads, [song]);
    expect(controller.currentEntryId, entry);
    expect(controller.isPreparingSong(b), isTrue);

    final second = controller.playSong(c, queue: [song, b, c]);
    await second;
    await drain();
    expect(controller.currentSong, c);
    expect(handler.loads, [song, c]);
    expect(handler.replacements, 2);
    expect(controller.isPreparing, isFalse);

    // 过期的第一次点击恢复后必须在 cp1 退出：不提交、不碰播放器。
    gate.complete(urlFor('B'));
    await first;
    await drain();
    expect(controller.currentSong, c);
    expect(handler.loads, [song, c], reason: '被取代的点击不再执行原生替换');
    expect(handler.replacements, 2);
    expect(handler.media, [song, c]);
    expect(api.requests.where((s) => s == 'B'), hasLength(1),
        reason: '被取代的点击不会重复请求');
  });

  test('rapid taps A to B to C commit only C once', () async {
    await setup();
    final bGate = Completer<PlayUrl>();
    final cGate = Completer<PlayUrl>();
    api.responses['B'] = bGate;
    api.responses['C'] = cGate;
    final first = controller.playSong(b, queue: [song, b, c, d]);
    await drain();
    final second = controller.playSong(c, queue: [song, b, c, d]);
    await drain();
    final third = controller.playSong(d, queue: [song, b, c, d]);
    await third;
    await drain();
    bGate.complete(urlFor('B'));
    cGate.complete(urlFor('C'));
    await first;
    await second;
    await drain();
    expect(controller.currentSong, d);
    expect(handler.loads, [song, d]);
    expect(handler.replacements, 2, reason: '只有最后一次点击替换了音源');
    expect(handler.plays, 2, reason: '只请求一次播放');
    expect(handler.media, [song, d], reason: '通知栏只写一次');
    expect(controller.isPreparing, isFalse);
    expect(controller.isPreparingSong(d), isFalse);
    expect(controller.errorMessage, isNull);
  });

  test('a failed replace rolls back to the previous entry and its position', () async {
    await setup();
    handler.audioPlayer.emitNative(
      ProcessingState.ready,
      position: const Duration(seconds: 42),
    );
    await drain();
    expect(controller.position, const Duration(seconds: 42));
    final entry = controller.currentEntryId;
    handler.failingHashes.add('B');

    await controller.playSong(b, queue: [song, b, c]);
    await drain();
    // 回滚：重新加载上一有效条目并恢复进度，错误可见且不自动重试。
    expect(controller.errorMessage, isNotNull);
    expect(controller.currentSong, song);
    expect(controller.position, const Duration(seconds: 42));
    expect(handler.loads, [song, song]);
    expect(handler.media, [song, song]);
    expect(handler.audioPlayer.playing, isTrue);
    expect(controller.currentEntryId, isNot(entry));
    expect(handler.failingHashes, hasLength(1));
  });

  test('tapping the playing song from another queue reloads it', () async {
    await setup();
    final entry = controller.currentEntryId;
    final other = copyOf(song);
    final otherQueue = [other, c];
    await controller.playSong(other, queue: otherQueue);
    await drain();
    expect(handler.loads, [song, other], reason: '跨歌单同一首歌按新播放处理');
    expect(handler.replacements, 2);
    expect(controller.currentSong, other);
    expect(controller.currentEntryId, isNot(entry));
    expect(controller.isPreparing, isFalse);
    expect(controller.errorMessage, isNull);
  });

  test('a queue refresh during a pending resolve keeps the tap alive', () async {
    await setup();
    final gate = Completer<PlayUrl>();
    api.responses['B'] = gate;
    final pending = controller.playSong(b, queue: [song, b, c]);
    await drain();
    // 歌单页打开后会在后台补拉整张歌单并 replaceQueue；
    // 这只是队列上下文刷新，绝不能吞掉用户刚发出的点击。
    await controller.replaceQueue([song, b, c, d]);
    await drain();
    gate.complete(urlFor('B'));
    await pending;
    await drain();
    expect(controller.currentSong, b);
    expect(controller.isPreparing, isFalse);
    expect(controller.errorMessage, isNull);
    expect(handler.loads, [song, b]);
    expect(handler.replacements, 2);
    expect(handler.audioPlayer.playing, isTrue);
  });

  test('a queue edit that drops the pending song cancels that load', () async {
    await setup();
    final gate = Completer<PlayUrl>();
    api.responses['B'] = gate;
    final pending = controller.playSong(b, queue: [song, b, c]);
    await drain();
    final entry = controller.currentEntryId;
    await controller.replaceQueue([song, c]);
    await drain();
    gate.complete(urlFor('B'));
    await pending;
    await drain();
    expect(controller.currentSong, song);
    expect(controller.currentEntryId, entry);
    expect(handler.loads, [song]);
    expect(handler.replacements, 1);
  });

  test('queue edits keep the current entry without reloading it', () async {
    await setup();
    final entry = controller.currentEntryId;
    final loads = handler.loads.length;
    final replacements = handler.replacements;
    await controller.updateQueueContext([song, c]);
    await drain();
    expect(handler.loads, hasLength(loads));
    expect(handler.replacements, replacements);
    expect(controller.currentEntryId, entry);
    expect(controller.currentSong, song);
    expect(controller.queue, [song, c]);
    expect(controller.isPreparing, isFalse);
    expect(controller.isPreparingSong(song), isFalse);
  });

  test('a seek during a pending load cannot pause the player', () async {
    await setup();
    final gate = Completer<PlayUrl>();
    api.responses['B'] = gate;
    final pending = controller.playSong(b, queue: [song, b, c]);
    await drain();
    await controller.seek(const Duration(seconds: 10));
    await drain();
    expect(handler.audioPlayer.playing, isTrue);
    expect(handler.replacements, 1);
    expect(controller.currentSong, song);
    gate.complete(urlFor('B'));
    await pending;
    await drain();
    // seek 作废了这次加载，播放器保持原条目。
    expect(controller.currentSong, song);
    expect(handler.loads, [song]);
    expect(handler.replacements, 1);
  });

  test('invariant: no native replace without a committed entry', () async {
    await setup();
    final violations = <String>[];
    handler.onNativeReplace = (replaced, start) {
      if (controller.currentEntryId == null) {
        violations.add(replaced.hash);
      }
    };
    final gate = Completer<PlayUrl>();
    api.responses['B'] = gate;
    final first = controller.playSong(b, queue: [song, b, c]);
    await drain();
    final second = controller.playSong(c, queue: [song, b, c]);
    await second;
    await drain();
    gate.complete(urlFor('B'));
    await first;
    await drain();
    expect(violations, isEmpty, reason: '不得出现"已暂停且无提交条目"');
    expect(controller.currentSong, c);
    expect(controller.currentEntryId, isNotNull);
    expect(handler.audioPlayer.playing, isTrue);
  });
}
