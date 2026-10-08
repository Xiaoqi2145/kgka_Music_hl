import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/music_models.dart';
import 'audio_focus_gate.dart';
import 'playlist_mutation_serializer.dart';

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  static const _queueWindowRadius = 25;

  MusicAudioHandler() {
    audioPlayer.playbackEventStream
        .map(_playbackStateForEvent)
        .pipe(playbackState);
  }

  // 关闭 just_audio 内置打断处理：其暂停/恢复/降音音量策略与
  // PlayerController 的打断设置（阻止打断/自动恢复）相互冲突，
  // 改由控制器在 interruptionEventStream 中统一实现完整策略。
  // 激活也由服务统一管理，不能依赖 just_audio.play 的 playing 短路入口。
  final AudioPlayer audioPlayer = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: false,
  );
  final AudioFocusGate _focus = AudioFocusGate(
    resetBeforeAcquire:
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
    setActive: (active) async =>
        (await AudioSession.instance).setActive(active),
  );
  int _transportGeneration = 0;
  void Function(bool playing)? onPlaybackIntent;

  void invalidatePendingPlay() {
    ++_transportGeneration;
    _focus.invalidate();
  }

  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;
  Future<void> Function(Duration)? _onSeek;
  int _queueIndex = 0;

  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    Future<void> Function(Duration)? onSeek,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
    _onSeek = onSeek;
  }

  void detachTransportControls() {
    _onNext = null;
    _onPrevious = null;
    _onSeek = null;
    onPlaybackIntent = null;
  }

  /// 播放列表变更串行链。
  ///
  /// **为什么必须有**：`dropArmedNext` / `promoteArmedNext` 的长度守卫读的是
  /// `sequenceState`，而 just_audio 的 `removeAt` 只在**自己的**锁内做
  /// `children.removeAt(index)`。若这两步之间有一次 `loadSong` →
  /// `setAudioSources([单个])` 抢先完成，`removeAt(0)` 就会作用在**刚加载的
  /// 唯一音源**上，把播放列表清空——比残留第三子源更严重：控制器随后
  /// `_activePlaylistSource = promoted`，`_ownsLoadedSource` 与
  /// `_ownsPlaybackWindow` 将永远为 false，进度条与歌词冻结到下一次加载。
  ///
  /// 这里把「检查长度 + 移除」整体放进同一条链，使其对其它变更原子。
  /// 逻辑本身在 [PlaylistMutationSerializer] 中，便于单测覆盖。
  final _playlistMutations = PlaylistMutationSerializer();

  Future<T> _serializePlaylist<T>(Future<T> Function() action) =>
      _playlistMutations.run(action);

  AudioSource _audioSourceFor(Song song, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return AudioSource.uri(Uri.parse(url), tag: song);
    }
    return AudioSource.file(url, tag: song);
  }

  /// 暂停与音源替换属于同一临界区：两者之间没有业务逻辑，
  /// 因此不存在“已暂停但没有新条目”的可被取代窗口。
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
    Duration start = Duration.zero,
    int? loadSerial,
  }) async {
    debugPrint(
      '[KA Music][transition] event=pause_for_load serial=$loadSerial '
      'startMs=${start.inMilliseconds}',
    );
    // setAudioSources 在 playing=true 时会自行出声；加载前暂停，等焦点批准后再播。
    await pauseForInterruption();
    // Stable mode: replace at the paused load boundary, never mutate a live
    // playlist. Media metadata is published by the controller's commit only.
    // 串行化：与 drop/promote 的长度守卫+移除构成原子区，避免把刚加载的
    // 唯一音源误删（见 _serializePlaylist）。
    await _serializePlaylist(
      () => audioPlayer.setAudioSources(
        [_audioSourceFor(song, url)],
        // initialPosition 由加载本身完成定位，省掉一次额外的播放器往返。
        initialPosition: start > Duration.zero ? start : null,
      ),
    );
  }

  /// Only the controller commit publishes the current media identity.
  void setCurrentMediaItem(Song song) {
    mediaItem.add(_mediaItemFor(song));
  }

  // ===== 无缝播放（原生边界交接） =====
  //
  // 与「预加载歌曲」的分工：预加载只解析 URL（纯缓存），这里把已解析的下一曲
  // 追加为**第二个原生子源**，由原生播放器在音频线程内完成过界，从而省掉
  // 「pause → setAudioSources([单个]) → play」这一必然产生可听间隙的替换。
  //
  // 注意：`useLazyPreparation` 保持 just_audio 默认值 `true`（构造期参数，
  // 见 `AudioPlayer` 构造）。默认值下平台**被允许**推迟准备追加的子源，
  // 因此「追加」不保证下一曲已预缓冲；接缝是否真无缝必须实机测量
  // （`AudioTrack` start/stop 时间戳）。本层只保证状态机正确、不产生子源泄漏。

  /// 原生过界信号。只转发 [PositionDiscontinuityReason.autoAdvance]：
  /// `seek` 由 just_audio 在每次 seek 时直接发出，与本功能无关。
  ///
  /// 该流是 `PublishSubject(sync: true)` 且内部用 `pairwise()` 比较，
  /// **第一个事件会被吞掉**，订阅必须尽早建立并常驻。
  Stream<PositionDiscontinuity> get boundaryStream =>
      audioPlayer.positionDiscontinuityStream.where(
        (event) => event.reason == PositionDiscontinuityReason.autoAdvance,
      );

  /// 把 [song] 追加为第二个子源（武装）。不提交任何业务状态。
  ///
  /// 仅允许在单子源时调用：`addAudioSource` 无去重、无重复防护，重复调用
  /// 会产生第 3 个子源。
  Future<void> armNextSource({required Song song, required String url}) async {
    await _serializePlaylist(() async {
      if (audioPlayer.sequenceState.sequence.length != 1) {
        throw StateError('armNextSource 要求当前为单子源');
      }
      await audioPlayer.addAudioSource(_audioSourceFor(song, url));
    });
  }

  /// 解除武装：移除已追加的第二个子源。
  ///
  /// 只在恰好 2 个子源时移除 index 1；其余情况视为无武装并静默返回，
  /// 绝不误删正在播放的唯一音源。
  Future<void> dropArmedNext() async {
    await _serializePlaylist(() async {
      if (audioPlayer.sequenceState.sequence.length != 2) return;
      await audioPlayer.removeAudioSourceAt(1);
    });
  }

  /// 过界后提升：移除 index 0（已播完的上一曲），回到单子源。
  ///
  /// 返回移除后的当前原生音源，供控制器重建 `_activePlaylistSource`。
  ///
  /// **必须在边界事件处理之后调用**：`removeAt` 会先广播缩短后的 sequence
  /// 再调原生（`just_audio.dart:3094-3100`），提前移除会让晚到的边界事件
  /// 因 `currentIndex` 越界而解析出 null 源、被静默丢弃。
  ///
  /// 长度检查与移除必须同处 [_serializePlaylist] 内：否则一次并发的
  /// `setAudioSources` 会让 `removeAt(0)` 删掉刚加载的唯一音源，把播放列表
  /// 清空（比残留第三子源更严重，见 [_serializePlaylist]）。
  Future<IndexedAudioSource?> promoteArmedNext() async {
    return _serializePlaylist(() async {
      if (audioPlayer.sequenceState.sequence.length != 2) return null;
      await audioPlayer.removeAudioSourceAt(0);
      return audioPlayer.sequenceState.currentSource;
    });
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(queue);
  }

  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    final window = _windowedQueue(queueSongs, queueIndex);
    _queueIndex = window.index;
    queue.add(window.songs.map(_mediaItemFor).toList(growable: false));
    if (currentSong != null) {
      mediaItem.add(_mediaItemFor(currentSong));
    }
  }

  /// Replace the service queue while a song is already playing.
  Future<void> replaceSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    final window = _windowedQueue(queueSongs, queueIndex);
    _queueIndex = window.index;
    queue.add(window.songs.map(_mediaItemFor).toList(growable: false));
    if (currentSong != null) {
      mediaItem.add(_mediaItemFor(currentSong));
    }
  }

  @override
  Future<void> play() => _play(userIntent: true);

  Future<void> reclaimAudioFocus() => _play(userIntent: false);

  Future<void> _play({required bool userIntent}) async {
    if (userIntent) onPlaybackIntent?.call(true);
    final generation = ++_transportGeneration;
    try {
      // 先放弃旧请求，确保临时失焦后也真正向系统申请，而非 native return true。
      final granted = await _focus.acquire();
      if (generation != _transportGeneration) return;
      if (!granted) {
        await audioPlayer.pause();
        return;
      }
    } catch (error) {
      debugPrint('[KA Music][audio focus] activation failed: $error');
      if (generation == _transportGeneration) await audioPlayer.pause();
      return;
    }
    await audioPlayer.play();
  }

  @override
  Future<void> pause() async {
    onPlaybackIntent?.call(false);
    invalidatePendingPlay();
    final generation = _transportGeneration;
    await audioPlayer.pause();
    if (generation == _transportGeneration) await _releaseFocus();
  }

  /// 临时中断保留焦点请求，以便接收 GAIN；不清除控制器的待恢复标记。
  Future<void> pauseForInterruption() async {
    invalidatePendingPlay();
    await audioPlayer.pause();
  }

  Future<void> _releaseFocus() async {
    try {
      await _focus.release();
    } catch (error) {
      debugPrint('[KA Music][audio focus] deactivation failed: $error');
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final onSeek = _onSeek;
    if (onSeek != null) {
      await onSeek(position);
    } else {
      await seekDirect(position);
    }
  }

  /// Controller-owned seeks (including load-position restore) avoid recursion.
  Future<void> seekDirect(Duration position) => audioPlayer.seek(position);

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> stop() async {
    onPlaybackIntent?.call(false);
    invalidatePendingPlay();
    final generation = _transportGeneration;
    await audioPlayer.stop();
    if (generation == _transportGeneration) await _releaseFocus();
  }

  Future<void> close() async {
    invalidatePendingPlay();
    await audioPlayer.dispose();
    await _releaseFocus();
  }

  ({List<Song> songs, int index}) _windowedQueue(
    List<Song> songs,
    int queueIndex,
  ) {
    if (songs.isEmpty) return (songs: const [], index: 0);
    final current = queueIndex.clamp(0, songs.length - 1);
    final start = (current - _queueWindowRadius).clamp(0, songs.length);
    final end = (current + _queueWindowRadius + 1).clamp(start, songs.length);
    return (songs: songs.sublist(start, end), index: current - start);
  }

  MediaItem _mediaItemFor(Song song) {
    return MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: song.duration,
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
      extras: {'hash': song.hash, 'songId': song.id},
    );
  }

  PlaybackState _playbackStateForEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[audioPlayer.processingState]!,
      playing: audioPlayer.playing,
      updatePosition: audioPlayer.position,
      bufferedPosition: audioPlayer.bufferedPosition,
      speed: audioPlayer.speed,
      queueIndex: _queueIndex,
    );
  }
}
