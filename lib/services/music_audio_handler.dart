import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/music_models.dart';
import 'audio_focus_gate.dart';

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
    await audioPlayer.setAudioSources(
      [_audioSourceFor(song, url)],
      // initialPosition 由加载本身完成定位，省掉一次额外的播放器往返。
      initialPosition: start > Duration.zero ? start : null,
    );
  }

  /// Only the controller commit publishes the current media identity.
  void setCurrentMediaItem(Song song) {
    mediaItem.add(_mediaItemFor(song));
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
