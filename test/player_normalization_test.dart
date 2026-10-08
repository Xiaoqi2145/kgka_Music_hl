import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/models/loudness_data.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/download_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:kgka_music_hl/services/playback_phase.dart';

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
  final errors = StreamController<PlayerException>.broadcast(sync: true);
  @override
  Stream<PlayerException> get errorStream => errors.stream;
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

  /// 每次武装追加的地址：本地缓存命中时应是文件路径而不是 http 地址。
  final appendedUrls = <String>[];
  int removals = 0;
  Completer<void>? loadGate;
  bool failLoad = false;

  /// 原生替换次数（模拟真实 handler 里"暂停 + setAudioSources"的原子操作）。
  int replacements = 0;

  /// 每次原生替换发生时的已提交条目，用于校验不变量 1。
  final commitAtReplace = <int?>[];

  /// 按歌曲 hash 持续失败，用于替换失败回滚测试。
  final Set<String> failingHashes = <String>{};

  /// 让非 http 地址（本地文件）加载失败，模拟缓存文件被清理/损坏。
  bool failLocalLoads = false;
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
    // 只让本地文件加载失败（模拟缓存文件被清理/损坏），网络地址仍可正常加载。
    if (failLocalLoads && !url.startsWith('http')) {
      throw StateError('local file missing');
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

  // ===== 无缝播放（原生边界交接）=====
  //
  // 显式实现，不能依赖 noSuchMethod 兜底：`boundaryStream` 若返回 null，
  // 控制器构造期订阅就会崩溃；而 noSuchMethod 对新增成员**不会编译报错**
  // （见 docx/06-质量保障/测试策略与现有用例.md §7 第 7 条）。

  final boundaries = StreamController<PositionDiscontinuity>.broadcast(
    sync: true,
  );

  @override
  Stream<PositionDiscontinuity> get boundaryStream => boundaries.stream;

  /// 构造一条「已过界」的 playback 事件（currentIndex = 1）。
  ///
  /// 真实语义：`PositionDiscontinuity(reason, previousEvent, event)` 里的
  /// `event` 是**新**事件，因此它自带的 currentIndex 一定是过界后的值。
  PlaybackEvent _advancedEvent() {
    final prev = audioPlayer.playbackEvent;
    final advanced = PlaybackEvent(
      processingState: ProcessingState.ready,
      updatePosition: Duration.zero,
      duration: prev.duration,
      currentIndex: 1,
      updateTime: DateTime(
        2026,
      ).add(Duration(milliseconds: ++audioPlayer.clock)),
    );
    audioPlayer.playbackEvent = advanced;
    return advanced;
  }

  /// 模拟原生过界（sequenceState 已先更新到 index 1，事件随后到达）。
  void emitNativeBoundary() {
    final sources = audioPlayer.sequenceState.sequence;
    if (sources.length < 2) return;
    final prev = audioPlayer.playbackEvent;
    audioPlayer.emitSequence(sources, 1);
    boundaries.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        prev,
        _advancedEvent(),
      ),
    );
  }

  /// 模拟原生过界的**真实时序**：不连续性事件先送达，此时
  /// `sequenceState.currentIndex` 仍是旧值 0（just_audio 的两处监听都挂在
  /// playbackEventStream 上，不连续性监听在 :287 先注册，currentIndex 监听在
  /// :324 后注册）。
  ///
  /// 这是实机复现的缺陷路径：早期实现按 `sequenceState.currentIndex != 1`
  /// 判定，会拒绝一次合法过界（实测 `boundary_rejected len=2 index=0`），
  /// 退化成 143ms 的显式重载。修复后必须只依据事件自带的索引。
  void emitNativeBoundaryBeforeSequenceUpdate() {
    final sources = audioPlayer.sequenceState.sequence;
    if (sources.length < 2) return;
    final prev = audioPlayer.playbackEvent;
    // sequenceState 故意保持 index 0（陈旧值），只发带新索引的事件。
    boundaries.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        prev,
        _advancedEvent(),
      ),
    );
  }

  @override
  Future<void> armNextSource({
    required Song song,
    required String url,
  }) async {
    appends++;
    appendedUrls.add(url);
    final sources = [
      ...audioPlayer.sequenceState.sequence,
      AudioSource.uri(Uri.parse(url), tag: song),
    ];
    audioPlayer.emitSequence(sources, 0);
  }

  @override
  Future<void> dropArmedNext() async {
    if (audioPlayer.sequenceState.sequence.length != 2) return;
    removals++;
    final sources = [...audioPlayer.sequenceState.sequence]..removeAt(1);
    audioPlayer.emitSequence(sources, 0);
  }

  @override
  Future<IndexedAudioSource?> promoteArmedNext() async {
    if (audioPlayer.sequenceState.sequence.length != 2) return null;
    removals++;
    final sources = [...audioPlayer.sequenceState.sequence]..removeAt(0);
    audioPlayer.emitSequence(sources, 0);
    return audioPlayer.sequenceState.currentSource;
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

  /// Hashes whose songUrl() rejects, for prefetch cooldown coverage.
  final failures = <String>{};
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
    if (failures.contains(song.hash)) {
      throw StateError('songUrl failed for ${song.hash}');
    }
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

/// Reports a local hit only for the listed song hashes.
///
/// This is the real-device shape: the *next* song has already been written to
/// the play cache (every song is cached 30s into playback), so it resolves
/// locally while the current song still comes from the network.
class _CachedDownloadController extends DownloadController {
  _CachedDownloadController(MusicApi api, this.cachedHashes)
    : super(DownloadService(), api);
  final Set<String> cachedHashes;

  /// 置 false 模拟「预解析之后、消费之前缓存索引条目消失」（文件仍在磁盘）。
  bool cacheAvailable = true;

  /// 被作废（判定损坏/已删除）的歌曲 hash，供回退断言。
  final invalidated = <String>[];

  /// 当前受 LRU 保护的路径（正在播放 + 已武装），供保护断言。
  String? activePath;
  String? armedPath;
  Set<String> get protectedPaths => {?activePath, ?armedPath};
  @override
  Future<void> initialize() async {}
  @override
  ({String path, LoudnessData? loudness})? localSourceFor(
    Song song,
    AudioQuality quality,
  ) => cacheAvailable && cachedHashes.contains(song.hash)
      ? (path: '/tmp/${song.hash}.flac', loudness: null)
      : null;
  @override
  Future<void> updateLocalLoudness(
    Song song,
    AudioQuality quality,
    LoudnessData? loudness,
  ) async {}
  @override
  void setActivePlaybackPath(String? path) {
    activePath = path;
  }

  @override
  void setArmedNextPath(String? path) {
    armedPath = path;
  }
  @override
  Future<bool> invalidateLocalSource(Song song, AudioQuality quality) async {
    invalidated.add(song.hash);
    cachedHashes.remove(song.hash);
    return true;
  }
}

/// Reports every song as a local hit, which is the only path that commits
/// without a network URL and therefore reaches loudness hydration.
class _LocalHitDownloadController extends DownloadController {
  _LocalHitDownloadController(MusicApi api) : super(DownloadService(), api);
  @override
  Future<void> initialize() async {}
  @override
  ({String path, LoudnessData? loudness})? localSourceFor(
    Song song,
    AudioQuality quality,
  ) => (path: '/tmp/${song.hash}.flac', loudness: null);
  @override
  Future<void> updateLocalLoudness(
    Song song,
    AudioQuality quality,
    LoudnessData? loudness,
  ) async {}
  @override
  void setActivePlaybackPath(String? path) {}
  @override
  Future<bool> invalidateLocalSource(Song song, AudioQuality quality) async =>
      false;
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

  test(
    'a second tap while the first is resolving commits only the newest',
    () async {
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
      expect(
        api.requests.where((s) => s == 'B'),
        hasLength(1),
        reason: '被取代的点击不会重复请求',
      );
    },
  );

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

  test(
    'a failed replace rolls back to the previous entry and its position',
    () async {
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
    },
  );

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

  test(
    'a queue refresh during a pending resolve keeps the tap alive',
    () async {
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
    },
  );

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

  test('leaving and re-entering the prefetch window asks only once', () async {
    await setup();
    tail();
    await drain();
    expect(api.requests.where((s) => s == 'B'), hasLength(1));
    // Leave the window: the candidate is cleared, but the resolved URL stays
    // cached in _loudnessLookup / responses, so re-entering must not re-ask.
    handler.audioPlayer.emitNative(
      ProcessingState.ready,
      position: const Duration(seconds: 10),
    );
    await drain();
    tail();
    await drain();
    expect(api.requests.where((s) => s == 'B'), hasLength(1));
  });

  test('a failed prefetch cools down before it is retried', () async {
    await setup();
    api.failures.add('B');
    tail();
    await drain();
    expect(api.requests.where((s) => s == 'B'), hasLength(1));
    // Still inside the 15s window: every position tick must stay silent.
    for (var i = 0; i < 5; i++) {
      tail();
      await drain();
    }
    expect(api.requests.where((s) => s == 'B'), hasLength(1));
  });

  test('an empty play URL cools down instead of storming every tick', () async {
    await setup();
    // The server answers, but without a usable address. This used to `return`
    // from inside the try block, skipping the cooldown entirely, so every
    // position tick (positionStream runs at 16-200ms) re-requested the song.
    api.responses['B'] = Completer<PlayUrl>()
      ..complete(const PlayUrl(url: '', hash: 'B'));
    tail();
    await drain();
    expect(api.requests.where((s) => s == 'B'), hasLength(1));
    for (var i = 0; i < 5; i++) {
      tail();
      await drain();
    }
    expect(
      api.requests.where((s) => s == 'B'),
      hasLength(1),
      reason: '空地址必须走失败冷却，不得按 position 刻度重复请求',
    );
  });

  test('a failed prefetch keeps its cooldown across unrelated resets', () async {
    await setup();
    api.failures.add('B');
    tail();
    await drain();
    expect(api.requests.where((s) => s == 'B'), hasLength(1));
    // Unrelated operations clear the prepared candidate. The cooldown is keyed
    // to the failing song, so it must survive them: otherwise the very next
    // position tick re-requests the same song the server already refused.
    // Both calls are mode-neutral, so the next song stays B deterministically.
    await controller.setAudioQuality(AudioQuality.high);
    await controller.replaceQueue([song, b, c, d]);
    await drain();
    tail();
    await drain();
    expect(
      api.requests.where((s) => s == 'B'),
      hasLength(1),
      reason: '与失败曲目无关的操作不得清空冷却',
    );
  });

  test('disabling gapless playback drops the in-flight candidate', () async {
    await setup();
    final response = Completer<PlayUrl>();
    api.responses['B'] = response;
    tail();
    await drain();
    await controller.setGaplessPlaybackEnabled(false);
    response.complete(
      const PlayUrl(url: 'https://example.invalid/late', hash: 'B'),
    );
    await drain();
    // The candidate was dropped, so a manual next must resolve on its own.
    api.responses.remove('B');
    await controller.next();
    await drain();
    expect(controller.currentSong, b);
    expect(api.requests.where((s) => s == 'B'), hasLength(2));
  });

  test('a song the server has no loudness for is only asked once', () async {
    await setup();
    // localSourceFor() must report a hit so _restoreLocalLoudness() takes the
    // hydration path (network playback commits the URL and never hydrates).
    controller.downloadController = _LocalHitDownloadController(api);
    controller.volumeNormalizationEnabled = true;
    // /song/url returns an empty loudness payload for B.
    api.responses['B'] = Completer<PlayUrl>()
      ..complete(
        const PlayUrl(url: 'https://example.invalid/b.mp3', hash: 'B'),
      );
    await controller.playSong(b, queue: [song, b, c]);
    await drain();
    final afterFirstLoad = api.requests.where((s) => s == 'B').length;
    expect(afterFirstLoad, 1, reason: '本地命中需要补一次响度');
    // Reload twice: each reload commits a new entry and bumps the generation.
    // This is the end-to-end guard (negative cache + short-circuit + dedup key
    // together); each mechanism is isolated in test/playback_loudness_test.dart.
    await controller.playSong(b, queue: [song, b, c]);
    await drain();
    await controller.playSong(b, queue: [song, b, c]);
    await drain();
    expect(
      api.requests.where((s) => s == 'B'),
      hasLength(1),
      reason: '已知无响度的歌曲不得重复补取',
    );
  });

  test('a natural end advances once and is counted as auto-advance', () async {
    await setup();
    expect(controller.nativeCompletions, 0);
    expect(controller.autoAdvanceSuccessRate, isNull);
    tail();
    await drain();
    complete();
    complete();
    await drain();
    expect(controller.currentSong, b);
    expect(controller.nativeCompletions, 1);
    expect(controller.autoAdvanceCommits, 1);
    expect(controller.autoAdvanceSuccessRate, 1.0);
    // The candidate consumed for the auto advance must not be reused.
    expect(controller.playbackSuccessRate, isNotNull);
  });

  test(
    'an unplayable next song is counted as an auto-advance failure',
    () async {
      await setup();
      api.failures.add('B');
      tail();
      await drain();
      complete();
      await drain();
      expect(controller.nativeCompletions, 1);
      expect(controller.autoAdvanceFailures, 1);
      expect(controller.autoAdvanceSuccessRate, 0.0);
    },
  );

  test(
    'the loudness generation is the coordinator generation, never a copy',
    () async {
      await setup();
      // Before any commit the coordinator has no entry, so no lease exists.
      expect(controller.currentEntryId, isNotNull);
      expect(
        controller.normalizationGeneration,
        controller.leaseGenerationForTest,
        reason: '响度代次必须直接来自过渡协调器，而不是各自维护的计数器',
      );
      await controller.setVolumeNormalizationEnabled(true);
      await drain();
      expect(
        controller.normalizationGeneration,
        controller.leaseGenerationForTest,
        reason: '重开响度窗口后两者仍必须一致',
      );
    },
  );

  test(
    'a stalled player is reported as a distinct phase',
    () async {
      await setup();
      expect(controller.playbackPhase, PlaybackPhase.playing);
      // Position stops advancing while the player still reports "playing".
      // The first tick only establishes the baseline; the next one arms the
      // watchdog, so the frozen value must be pushed twice before waiting.
      final frozen = controller.position;
      handler.audioPlayer.positions.add(frozen);
      await drain();
      handler.audioPlayer.positions.add(frozen);
      await drain();
      expect(controller.isStalled, isFalse);
      await Future<void>.delayed(const Duration(seconds: 6));
      handler.audioPlayer.positions.add(frozen);
      await drain();
      expect(controller.isStalled, isTrue);
      expect(controller.playbackPhase, PlaybackPhase.stalled);
      // Progress resumes: the stall flag clears on the next real advance.
      handler.audioPlayer.positions.add(frozen + const Duration(seconds: 1));
      await drain();
      expect(controller.isStalled, isFalse);
      expect(controller.playbackPhase, PlaybackPhase.playing);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('progress revision only advances with real position movement', () async {
    await setup();
    final revision = controller.progressRevision;
    // Diagnostic-only events must not advance the revision.
    handler.audioPlayer.durations.add(const Duration(seconds: 120));
    await drain();
    expect(controller.progressRevision, revision);
    handler.audioPlayer.positions.add(
      controller.position + const Duration(seconds: 1),
    );
    await drain();
    expect(controller.progressRevision, greaterThan(revision));
  });

  test('success-rate counters separate attempts from commits', () async {
    await setup();
    expect(controller.playbackAttempts, greaterThanOrEqualTo(1));
    expect(controller.playbackCommits, greaterThanOrEqualTo(1));
    expect(controller.playbackSuccessRate, isNotNull);
    final attempts = controller.playbackAttempts;
    final commits = controller.playbackCommits;
    // A failed resolve still counts as an attempt but not as a commit.
    api.failures.add('C');
    await controller.playSong(c, queue: [song, b, c]);
    await drain();
    expect(controller.playbackAttempts, attempts + 1);
    expect(controller.playbackCommits, commits);
    expect(controller.autoAdvanceSuccessRate, isNull);
  });

  // ===== 无缝播放（原生边界交接） =====

  /// 武装成功的公共前置：开启两个开关并推进到预解析窗口。
  Future<void> arm() async {
    await controller.setRealGaplessPlaybackEnabled(true);
    tail();
    await drain();
    tail();
    await drain();
  }

  int sourceCount() => handler.audioPlayer.sequenceState.sequence.length;

  test('arming appends a second source without committing', () async {
    await setup();
    final entry = controller.currentEntryId;
    await arm();
    expect(sourceCount(), 2, reason: '武装应追加第二子源');
    // 武装不提交：展示身份、歌词、历史、统计都不得变化。
    expect(controller.currentSong, song);
    expect(controller.currentEntryId, entry);
    expect(handler.media, [song]);
    expect(handler.loads, [song]);
  });

  test(
    'a cached next song still produces an armable candidate',
    () async {
      await setup();
      // 实机形状：下一曲已在播放缓存里（每首歌播满 30 秒就会被
      // _schedulePlaybackCache 写进缓存），当前曲仍走网络。
      // 早期实现在这里静默 `return`，`_preparedNext` 永远为 null，
      // 于是「下一曲已缓存」这一最常见情况永不武装 —— 实机症状就是
      // 零 prefetch_ready / 零 armed_next，过界全退化成显式重载。
      controller.downloadController = _CachedDownloadController(api, {'B'});
      // 关掉音量均衡，去掉「本地命中补取响度」这条元数据请求的噪声：
      // 剩下的任何 B 请求都只可能来自播放地址解析。
      await controller.setVolumeNormalizationEnabled(false);
      await arm();
      expect(
        api.requests.where((s) => s == 'B'),
        isEmpty,
        reason: '缓存命中不应再请求播放地址',
      );
      expect(sourceCount(), 2, reason: '缓存命中必须同样武装');
      expect(
        handler.appendedUrls.single,
        '/tmp/B.flac',
        reason: '应把本地文件路径追加为第二子源，而不是网络地址',
      );
      expect(controller.currentSong, song, reason: '武装仍然不提交');
    },
  );

  test(
    'a locally cached next song commits without re-caching its path',
    () async {
      await setup();
      controller.downloadController = _CachedDownloadController(api, {'B'});
      await controller.setVolumeNormalizationEnabled(false);
      await arm();
      expect(sourceCount(), 2);
      handler.emitNativeBoundary();
      await drain();
      expect(controller.currentSong, b);
      expect(sourceCount(), 1);
      // 本地候选提交时不得被当成网络地址再次进入播放缓存：那会把文件路径
      // 交给下载器，并且丢掉 LRU 对正在播放文件的保护。
      expect(api.requests.where((s) => s == 'B'), isEmpty);
      expect(handler.loads, [song], reason: '原生交接不应重新 setAudioSources');
      expect(controller.autoAdvanceCommits, 1);
      expect(
        controller.pendingPlayCacheSongForTest,
        isNot(same(b)),
        reason: '本地路径不得排入播放缓存（待定项仍是上一首，未被 B 覆盖）',
      );
    },
  );

  test(
    'a native boundary schedules the play cache for the committed song',
    () async {
      await setup();
      // 过界提交不走 _playSong。实机证据：显式加载的那首在 play_cache_index
      // 里，随后两首 native_auto_advance 提交的曲目都不在 —— 缓存只增不减的
      // 前提被破坏，而缓存命中与否正是本地分支的输入。
      await arm();
      expect(sourceCount(), 2);
      handler.emitNativeBoundary();
      await drain();
      expect(controller.currentSong, b);
      expect(
        controller.pendingPlayCacheSongForTest,
        same(b),
        reason: '过界提交必须为已提交的网络曲目排入播放缓存',
      );
      expect(
        controller.pendingPlayCacheUrlForTest,
        'https://example.invalid/song.mp3',
        reason: '排入缓存的必须是网络地址',
      );
    },
  );

  test(
    'a corrupt cached candidate falls back to the network instead of failing',
    () async {
      await setup();
      // 走的是显式加载（manual_next）而非过界：这条覆盖的是既有的
      // 「本地音源损坏 → 作废 → 改走网络」回退，只是现在本地候选由
      // 预解析产出，因此第一次解析就命中本地。
      //
      // 注意：命中时 `_resolveSource` 在更早的 `localSourceFor` 分支就返回了
      // （早于 `prepared` 分支），所以本用例**不**覆盖 `networkUrl` 那一行；
      // 那一行由 `a vanished cache entry still commits as local` 覆盖。
      final downloads = _CachedDownloadController(api, {'B'});
      controller.downloadController = downloads;
      await controller.setVolumeNormalizationEnabled(false);
      // 本地文件加载失败；随后应作废本地音源并改走网络。
      handler.failLocalLoads = true;
      await arm();
      expect(sourceCount(), 2, reason: '本地候选仍应武装');
      await controller.next();
      await drain();
      expect(controller.currentSong, b, reason: '损坏的本地候选必须回退到网络');
      expect(downloads.invalidated, contains('B'), reason: '损坏的本地音源应被作废');
      expect(api.requests.where((s) => s == 'B'), isNotEmpty, reason: '应回退到网络解析');
      expect(controller.errorMessage, isNull);
    },
  );

  test(
    'a corrupt armed local file recovers instead of stalling forever',
    () async {
      await setup();
      // 本地候选在武装后、过界前被清理/损坏（LRU 淘汰或用户清缓存）。
      // 原生准备失败会把状态推到 idle，`completed` 兜底永远不会命中，
      // `_armedNext` 一直非空——它同时挡住预解析与重新武装，表现为永久卡死。
      final downloads = _CachedDownloadController(api, {'B'});
      controller.downloadController = downloads;
      await controller.setVolumeNormalizationEnabled(false);
      handler.failLocalLoads = true;
      await arm();
      expect(sourceCount(), 2, reason: '本地候选应已武装');
      // 模拟原生在准备第二子源时失败并报错：ExoPlayer 转入 idle，
      // just_audio 的错误处理会 pause()（just_audio.dart:426）。
      handler.audioPlayer.emitNative(ProcessingState.idle);
      handler.audioPlayer.playing = false;
      handler.audioPlayer.errors.add(PlayerException(2, 'prepare failed', 1));
      await drain();
      // 恢复路径：撤销武装令牌 → 作废本地音源 → 按网络重新续播。
      expect(downloads.invalidated, contains('B'), reason: '损坏的本地音源应被作废');
      expect(
        api.requests.where((s) => s == 'B'),
        isNotEmpty,
        reason: '必须回退到网络解析',
      );
      expect(
        controller.currentSong,
        b,
        reason: '不得永久卡死：撤销武装后仍应续播到下一曲',
      );
      expect(sourceCount(), 1, reason: '不得残留第二子源');
    },
  );

  test('an armed local candidate is protected from LRU during the arm window', () async {
    await setup();
    final downloads = _CachedDownloadController(api, {'B'});
    controller.downloadController = downloads;
    await controller.setVolumeNormalizationEnabled(false);
    await arm();
    expect(sourceCount(), 2);
    // 武装即保护：当前曲来自网络（_activePlayCachePath 为 null），
    // 若不为已武装的 B 单独登记，它在 A 的 t=30s 缓存写入触发的 LRU
    // 清理中会被当作普通条目淘汰 —— 过界时文件已不存在。
    expect(
      downloads.protectedPaths,
      contains('/tmp/B.flac'),
      reason: '武装窗口内必须保护下一曲的本地文件',
    );
  });

  test(
    'a vanished cache entry still commits as local, never as a network URL',
    () async {
      await setup();
      // 关键：这条必须走 `_handleCompleted`（native_completed）而不是过界。
      // 过界提交直接复用 `armed` 字段、**不会**调用 `_resolveSource`；只有
      // 显式/自动续播的 `_playSong(prepared:)` 才会走到 `_resolveSource` 的
      // `prepared` 分支——也就是 `networkUrl: prepared.isLocal ? null : ...`
      // 那一行唯一可达的路径。故这里不开「无缝播放」。
      final downloads = _CachedDownloadController(api, {'B'});
      controller.downloadController = downloads;
      await controller.setVolumeNormalizationEnabled(false);
      // 预解析阶段缓存命中，产出本地候选。
      tail();
      await drain();
      tail();
      await drain();
      expect(sourceCount(), 1, reason: '未开启无缝播放时不应武装');
      // 消费候选之前索引条目消失（文件仍在磁盘）。
      downloads.cacheAvailable = false;
      complete();
      complete();
      await drain();
      expect(controller.currentSong, b, reason: '自动续播应提交下一曲');
      expect(
        controller.pendingPlayCacheSongForTest,
        isNot(same(b)),
        reason: '本地候选的路径不得被当成网络地址排入播放缓存',
      );
      expect(
        downloads.activePath,
        '/tmp/B.flac',
        reason: '提交后应保护该本地文件不被 LRU 删除',
      );
    },
  );

  test('a local-source song is armed from its own path', () async {
    await setup();
    // 本地音乐（SongSource.local）路径即地址：既不请求网络，也不查播放缓存。
    const localSong = Song(
      id: '/music/x.flac',
      title: 'local',
      artist: 'artist',
      hash: '/music/x.flac',
      source: SongSource.local,
    );
    await controller.replaceQueue([song, localSong]);
    await drain();
    final requestsBeforeArm = api.requests.length;
    await arm();
    expect(
      api.requests.length,
      requestsBeforeArm,
      reason: '本地音乐不得请求网络地址',
    );
    expect(sourceCount(), 2, reason: '本地音乐同样必须武装');
    expect(handler.appendedUrls.single, '/music/x.flac');
  });

  test('a native boundary commits once and returns to a single source', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    handler.emitNativeBoundary();
    await drain();
    expect(controller.currentSong, b, reason: '过界应提交下一曲');
    expect(sourceCount(), 1, reason: '提交后必须回到单子源');
    expect(handler.loads, [song], reason: '原生交接不应重新 setAudioSources');
    expect(controller.autoAdvanceCommits, 1);
    // 幂等：同一次过渡重复投递不得再次提交。此时已是单子源，
    // 重新投递同一事件必须被忽略（不得把当前曲再提交一次或误删音源）。
    handler.boundaries.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        handler.audioPlayer.playbackEvent,
        handler.audioPlayer.playbackEvent,
      ),
    );
    await drain();
    expect(sourceCount(), 1);
    expect(controller.currentSong, b);
  });

  test(
    'the boundary event arrives before sequenceState updates the index',
    () async {
      await setup();
      await arm();
      expect(sourceCount(), 2);
      // 实机时序：事件先到，sequenceState.currentIndex 仍是 0。
      // 按 sequenceState 判定会误拒合法过界（实测 boundary_rejected），
      // 退化成显式重载 —— 即失去无缝。必须只信事件自带的索引。
      handler.emitNativeBoundaryBeforeSequenceUpdate();
      await drain();
      expect(controller.currentSong, b, reason: '合法过界不得被误拒');
      expect(sourceCount(), 1, reason: '提交后必须回到单子源');
      expect(handler.loads, [song], reason: '不得退化成显式重载');
      expect(controller.autoAdvanceCommits, 1);
    },
  );

  test('disabling the gapless switch drops the armed source', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    await controller.setRealGaplessPlaybackEnabled(false);
    await drain();
    expect(sourceCount(), 1, reason: '关闭开关必须撤销武装');
  });

  test('the real-gapless switch is gated by preload', () async {
    await setup();
    await controller.setRealGaplessPlaybackEnabled(true);
    // 关闭「预加载歌曲」：无缝播放依赖预解析地址，必须同时失效。
    await controller.setGaplessPlaybackEnabled(false);
    await drain();
    expect(controller.realGaplessActive, isFalse);
    tail();
    await drain();
    expect(sourceCount(), 1, reason: '预加载关闭时不得武装');
  });

  test('a seek drops the armed source', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    await controller.seek(const Duration(seconds: 10));
    await drain();
    expect(sourceCount(), 1, reason: 'seek 窗口会吞掉过界事件，必须先撤销');
  });

  test('seeking out of the window must not re-arm', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    // Drive a real position tick at [position] (the arm path is reached from
    // the positionStream listener, so emitting native state alone is not enough).
    void tickAt(Duration position) {
      handler.audioPlayer.emitNative(ProcessingState.ready, position: position);
      handler.audioPlayer.positions.add(position);
    }

    // Seek back to the middle of the track: far outside the 3-30s window
    // (100s track at position 10s => remaining 90s). The cached candidate
    // survives a seek, so the arm path must re-check the window itself;
    // otherwise the next tick re-appends the next source with minutes of the
    // current track still to play. Found by real-device testing.
    await controller.seek(const Duration(seconds: 10));
    await drain();
    expect(sourceCount(), 1, reason: 'seek 应先撤销武装');
    for (var i = 0; i < 5; i++) {
      tickAt(const Duration(seconds: 10));
      await drain();
    }
    expect(
      sourceCount(),
      1,
      reason: '窗口外不得重新武装（不变量：武装只在 remaining ∈ [3s,30s]）',
    );
    // Re-entering the window legitimately re-arms.
    tickAt(const Duration(seconds: 80)); // remaining 20s
    await drain();
    expect(sourceCount(), 2, reason: '回到窗口内应重新武装');
  });

  test('a manual next drops the armed source instead of stacking a third', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    final removalsBefore = handler.removals;
    // 只在**替换发生前**断言才有判别力：setAudioSources([单个]) 本身就会把
    // 列表覆盖成 1 个，事后看 sourceCount 无论如何都是 1（旧断言因此是空的）。
    // 用 loadGate 卡住原生加载，观察替换前是否已显式撤销。
    handler.loadGate = Completer<void>();
    final pending = controller.next();
    await drain();
    expect(
      handler.removals,
      greaterThan(removalsBefore),
      reason: '替换发生前必须显式撤销已武装的第二子源',
    );
    expect(
      sourceCount(),
      1,
      reason: '撤销后到替换前，原生应已回到单子源',
    );
    handler.loadGate!.complete();
    handler.loadGate = null;
    await pending;
    await drain();
    expect(sourceCount(), 1, reason: '手动切歌不得残留子源');
    expect(controller.currentSong, b);
  });

  test('a queue replacement drops the armed source', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    await controller.replaceQueue([song, c, d]);
    await drain();
    expect(sourceCount(), 1, reason: '已武装的曲目可能已不在队列中');
  });

  test('position keeps advancing while armed', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    final before = controller.position;
    // 宽判据：武装窗口内进度不得冻结（否则进度条与桌面歌词停摆 30 秒）。
    handler.audioPlayer.emitNative(
      ProcessingState.ready,
      position: before + const Duration(seconds: 1),
    );
    await drain();
    expect(controller.position, greaterThan(before));
  });

  test('completion at index 0 while armed falls back instead of stalling', () async {
    await setup();
    await arm();
    expect(sourceCount(), 2);
    // 原生没有过界却报播完（平台不支持自动过渡 / 子源加载失败）。
    // 若不撤销武装并回落，会永久停在两子源：不提交，也不再续播。
    complete();
    await drain();
    expect(sourceCount(), 1, reason: '必须撤销武装并回落');
    expect(controller.currentSong, b, reason: '回落后仍应自动续播');
  });
}
