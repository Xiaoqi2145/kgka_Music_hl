import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/loudness_data.dart';
import '../models/music_models.dart';
import '../services/audio_effects_service.dart';
import '../services/cache_service.dart';
import '../services/desktop_lyrics_service.dart';
import '../services/music_api.dart';
import '../services/music_audio_handler.dart';
import '../services/playback_history_service.dart';
import '../services/playback_stats_service.dart';
import '../services/volume_normalization_service.dart';
import 'download_controller.dart';

enum PlaybackMode { playlistLoop, shuffle, singleLoop }

class AudioEffectPreset {
  const AudioEffectPreset({required this.name, required this.levels});

  final String name;
  final List<int> levels;
}

class PlayerController extends ChangeNotifier {
  static const _listenTimeSettingKey = 'settings.add_listening_time_enabled';
  static const _audioQualitySettingKey = 'settings.audio_quality';
  static const _equalizerEnabledSettingKey = 'settings.equalizer_enabled';
  static const _equalizerLevelsSettingKey = 'settings.equalizer_levels';
  static const _equalizerPresetSettingKey = 'settings.equalizer_preset';
  static const _bassBoostEnabledSettingKey = 'settings.bass_boost_enabled';
  static const _bassBoostStrengthSettingKey = 'settings.bass_boost_strength';
  static const _audioInterruptionEnabledSettingKey =
      'settings.audio_interruption_enabled';
  static const _autoResumeAfterInterruptionSettingKey =
      'settings.auto_resume_after_interruption';
  static const _autoPlayOnDeviceConnectedSettingKey =
      'settings.auto_play_on_device_connected';
  static const _playbackSpeedSettingKey = 'settings.playback_speed';
  static const _desktopLyricsEnabledSettingKey =
      'settings.desktop_lyrics_enabled';
  static const _desktopLyricsSettingsKey = 'settings.desktop_lyrics_settings';
  static const _smartQualitySettingKey = 'settings.smart_quality_enabled';
  static const _volumeNormEnabledSettingKey =
      'settings.volume_normalization_enabled';
  static const _volumeNormRefLufsSettingKey =
      'settings.volume_normalization_ref_lufs';
  static const _manualLyricCandidatesSettingKey =
      'settings.manual_lyric_candidates';
  static const _listenTimeReportInterval = Duration(minutes: 30);
  static const _listenTimeCheckInterval = Duration(minutes: 1);
  static const _defaultEqualizerLevels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  static const equalizerPresets = [
    AudioEffectPreset(name: '平直', levels: _defaultEqualizerLevels),
    AudioEffectPreset(
      name: '流行',
      levels: [0, 250, 450, 350, 100, -100, 50, 300, 450, 500],
    ),
    AudioEffectPreset(
      name: '摇滚',
      levels: [500, 350, 150, -100, -250, -150, 150, 350, 550, 650],
    ),
    AudioEffectPreset(
      name: '人声',
      levels: [-250, -150, 0, 250, 500, 550, 350, 100, -100, -200],
    ),
    AudioEffectPreset(
      name: '低音',
      levels: [750, 650, 500, 250, 0, -100, -150, -200, -250, -300],
    ),
    AudioEffectPreset(
      name: '古典',
      levels: [350, 250, 100, 0, 150, 250, 300, 350, 250, 100],
    ),
    AudioEffectPreset(
      name: '电子',
      levels: [650, 450, 120, -120, -180, 100, 350, 550, 650, 700],
    ),
  ];

  /// 下载控制器（由 main.dart 在创建后注入，供 UI 访问下载功能）。
  DownloadController? downloadController;

  /// 缓存服务（由 main.dart 在创建后注入，用于歌词等缓存）。
  CacheService? cacheService;

  PlayerController(this._api, this._audioHandler) {
    unawaited(_restoreSettings());
    _audioHandler.attachTransportControls(onNext: next, onPrevious: previous);
    _desktopLyrics.setVisibilityChangedHandler(_handleDesktopLyricsVisibility);
    _positionSub = audioPlayer.positionStream.listen((value) {
      if (!_isSeeking) {
        _setPositionBase(value, playing: isPlaying);
      }
      _maybeCompleteFromPosition(value);
      _maybeSyncDesktopLyricFromPosition();
      notifyListeners();
    });
    _durationSub = audioPlayer.durationStream.listen((value) {
      duration = value ?? Duration.zero;
      notifyListeners();
    });
    _stateSub = audioPlayer.playerStateStream.listen((value) {
      isPlaying = value.playing;
      isBuffering =
          value.processingState == ProcessingState.loading ||
          value.processingState == ProcessingState.buffering;
      if (!_isSeeking) {
        _setPositionBase(audioPlayer.position, playing: isPlaying);
      }
      _syncListeningTimeTracker();
      if (isPlaying) {
        _resumePendingPlaybackCache();
      } else {
        _pausePendingPlaybackCache();
      }
      _syncDesktopPlayState();
      notifyListeners();
    });
    _processingStateSub = audioPlayer.processingStateStream.distinct().listen((
      state,
    ) {
      if (state == ProcessingState.completed) {
        unawaited(_handleCompleted());
      }
    });
    _androidAudioSessionSub = audioPlayer.androidAudioSessionIdStream.listen((
      sessionId,
    ) {
      _androidAudioSessionId = sessionId;
      unawaited(_refreshEqualizerConfig());
      unawaited(_applyEqualizer());
      unawaited(_applyBassBoost());
      unawaited(_applyVolumeNormalization());
    });
    unawaited(_setupAudioSessionListeners());
  }

  final MusicApi _api;
  final MusicAudioHandler _audioHandler;
  final AudioEffectsService _audioEffects = AudioEffectsService();
  final DesktopLyricsService _desktopLyrics = DesktopLyricsService();
  final PlaybackHistoryService _historyService = PlaybackHistoryService();
  final PlaybackStatsService _statsService = PlaybackStatsService();

  AudioPlayer get audioPlayer => _audioHandler.audioPlayer;

  MusicApi get api => _api;

  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration?> _durationSub;
  late final StreamSubscription<PlayerState> _stateSub;
  late final StreamSubscription<ProcessingState> _processingStateSub;
  late final StreamSubscription<int?> _androidAudioSessionSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  /// 打断开始时是否正在播放：恢复播放只针对被系统打断的情况，
  /// 用户手动暂停后再被打断（其他 App 抢焦点）不自动恢复。
  bool _wasPlayingOnInterruptionBegin = false;
  StreamSubscription<AudioDevicesChangedEvent>? _devicesChangedSub;
  final Stopwatch _positionClock = Stopwatch();

  // ===== 播放会话持久化（接续播放） =====
  // 只记录队列与当前歌曲，不保存播放进度：会话仅在切歌/换队列/切模式时
  // 写入一次（脏标记防重复），显著降低磁盘 IO 与功耗。
  static const _playbackSessionCacheKey = 'cache_playback_session';
  static const _resumePlaybackSettingKey = 'settings.resume_playback_enabled';
  bool resumePlaybackEnabled = true;
  bool _playbackSessionRestored = false;
  bool _playbackSessionDirty = false;
  Timer? _sessionSaveTimer;
  final _random = math.Random();
  Timer? _completionFallbackTimer;
  Timer? _playCacheDelayTimer;
  Song? _pendingPlayCacheSong;
  AudioQuality? _pendingPlayCacheQuality;
  String? _pendingPlayCacheUrl;
  LoudnessData? _pendingPlayCacheLoudness;
  Timer? _listenTimeTimer;
  DateTime? _listenTimeStartedAt;
  Duration _pendingListenTime = Duration.zero;
  bool _isReportingListenTime = false;
  int _seekSerial = 0;
  bool _isSeeking = false;
  bool _isScrubbing = false;
  bool _isHandlingCompletion = false;
  String? _completedSongHash;
  bool _isAppForeground = true;
  bool _desktopLyricsPreviewVisible = false;

  Song? currentSong;
  List<Song> queue = const [];
  List<LyricLine> lyrics = const [];
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isPlaying = false;
  bool isBuffering = false;
  bool isPreparing = false;
  bool addListeningTimeEnabled = true;
  AudioQuality audioQuality = AudioQuality.standard;

  /// 是否开启音质智能切换（播放失败时自动降级重试）。
  bool smartQualityEnabled = false;
  double playbackSpeed = 1.0;
  bool equalizerEnabled = false;
  List<int> equalizerLevels = List<int>.of(_defaultEqualizerLevels);
  String equalizerPresetName = '平直';
  EqualizerConfig equalizerConfig = EqualizerConfig.fallback(
    _defaultEqualizerLevels,
  );
  bool bassBoostEnabled = false;
  double bassBoostStrength = 0.45;
  bool audioInterruptionEnabled = true;
  bool autoResumeAfterInterruption = false;
  bool autoPlayOnDeviceConnected = true;
  bool desktopLyricsEnabled = false;
  LyricDisplayMode lyricDisplayMode = LyricDisplayMode.lyricsWithTranslation;
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();

  /// 音量均衡（LUFS 响度标准化）。
  bool volumeNormalizationEnabled = false;
  double volumeNormalizationRefLufs = -14.0;
  final VolumeNormalizationService _volNormService =
      VolumeNormalizationService();
  Timer? _autoResumeTimer;
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  DateTime? _sleepTimerEnd;
  bool _sleepFinishCurrentSong = false;
  bool _sleepFinishCurrentSongOption = false;
  String? errorMessage;
  int seekRevision = 0;
  int? _androidAudioSessionId;
  int _volumeNormApplySerial = 0;
  int _queueRevision = 0;
  Future<void>? _queueExpansionFuture;
  final Map<String, LyricCandidate> _manualLyricCandidates = {};

  LyricCandidate? manualLyricCandidateFor(Song song) =>
      _manualLyricCandidates[song.hash];

  /// hidden 行（署名/水印/标题卡）不进入播放与展示链路：
  /// 解析层的翻译对齐已完成，展示层直接跳过这些行。
  static List<LyricLine> _visibleLyrics(List<LyricLine> lines) =>
      lines.where((line) => !line.hidden).toList(growable: false);

  int get queueRevision => _queueRevision;

  Future<List<LyricCandidate>> searchLyricCandidates(Song song) =>
      _api.searchLyricCandidates(song);

  Future<List<LyricLine>> previewLyricCandidate(LyricCandidate candidate) =>
      _api.lyricsFromCandidate(candidate);

  Future<bool> selectLyricCandidate(
    Song song,
    LyricCandidate candidate, {
    List<LyricLine>? preview,
  }) async {
    final selected = preview ?? await _api.lyricsFromCandidate(candidate);
    if (selected.isEmpty) return false;
    _manualLyricCandidates[song.hash] = candidate;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _manualLyricCandidatesSettingKey,
      jsonEncode({
        for (final entry in _manualLyricCandidates.entries)
          entry.key: entry.value.toJson(),
      }),
    );
    if (currentSong?.hash == song.hash) {
      lyrics = _visibleLyrics(selected);
      notifyListeners();
      _syncDesktopLyrics();
    }
    return true;
  }

  Future<void> restoreAutomaticLyrics(Song song) async {
    _manualLyricCandidates.remove(song.hash);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _manualLyricCandidatesSettingKey,
      jsonEncode({
        for (final entry in _manualLyricCandidates.entries)
          entry.key: entry.value.toJson(),
      }),
    );
    await loadLyrics(song, force: true);
  }

  Future<void> setLyricDisplayMode(LyricDisplayMode mode) async {
    lyricDisplayMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings.lyric_display_mode', mode.name);
    notifyListeners();
  }

  bool get isScrubbing => _isScrubbing;
  bool get isAudioEffectsSupported => _audioEffects.isAudioEffectsSupported;
  bool get isBassBoostSupported => _audioEffects.isBassBoostSupported;
  String get audioEffectsLabel {
    if (!isAudioEffectsSupported) {
      return '当前平台暂不支持';
    }
    if (equalizerEnabled) {
      return '均衡器：$equalizerPresetName';
    }
    if (bassBoostEnabled) {
      return 'Bass ${(bassBoostStrength * 100).round()}%';
    }
    return '关闭';
  }

  String get playbackSpeedLabel {
    if (playbackSpeed == playbackSpeed.roundToDouble()) {
      return '${playbackSpeed.round()}x';
    }
    return '${playbackSpeed}x';
  }

  Duration get smoothPosition {
    if (_isScrubbing) {
      return position;
    }
    if (!isPlaying) {
      return position;
    }
    final value = position + _positionClock.elapsed;
    if (duration > Duration.zero && value > duration) {
      return duration;
    }
    return value;
  }

  int get currentIndex {
    final song = currentSong;
    if (song == null) {
      return -1;
    }
    return queue.indexWhere((item) => item.hash == song.hash);
  }

  int get activeLyricIndex {
    if (lyrics.isEmpty) {
      return -1;
    }
    final target = smoothPosition;
    var low = 0;
    var high = lyrics.length - 1;
    var result = 0;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (target >= lyrics[middle].time) {
        result = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return result;
  }

  String get playbackModeLabel {
    return switch (playbackMode) {
      PlaybackMode.playlistLoop => '歌单循环',
      PlaybackMode.shuffle => '随机播放',
      PlaybackMode.singleLoop => '单曲循环',
    };
  }

  PlaybackMode cyclePlaybackMode() {
    playbackMode = switch (playbackMode) {
      PlaybackMode.playlistLoop => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.singleLoop,
      PlaybackMode.singleLoop => PlaybackMode.playlistLoop,
    };
    _scheduleSessionPersist();
    notifyListeners();
    return playbackMode;
  }

  Future<void> setAddListeningTimeEnabled(bool enabled) async {
    if (addListeningTimeEnabled == enabled) {
      return;
    }
    addListeningTimeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_listenTimeSettingKey, enabled);
    if (!enabled) {
      _resetListeningTimeTracker();
    } else {
      _syncListeningTimeTracker();
    }
    notifyListeners();
  }

  Future<void> playSong(Song song, {List<Song>? queue}) async {
    // 点击当前正在播放的歌曲：保持播放进度，仅同步队列上下文并继续播放。
    // 恢复会话后音源尚未加载（idle），走完整加载路径以消费接续进度。
    final current = currentSong;
    if (current != null &&
        errorMessage == null &&
        audioPlayer.processingState != ProcessingState.idle &&
        _songKey(song) == _songKey(current)) {
      if (queue != null && queue.isNotEmpty && !listEquals(queue, this.queue)) {
        this.queue = queue;
        _queueRevision++;
        _queueExpansionFuture = null;
        await _audioHandler.setSongQueue(
          queueSongs: this.queue,
          queueIndex: currentIndex,
          currentSong: current,
        );
        notifyListeners();
      }
      if (audioPlayer.processingState == ProcessingState.completed) {
        _completedSongHash = null;
        await _audioHandler.seek(Duration.zero);
      }
      await _audioHandler.play();
      _scheduleSessionPersist();
      return;
    }
    _cancelPendingPlaybackCache();
    _completionFallbackTimer?.cancel();
    _completedSongHash = null;
    isPreparing = true;
    errorMessage = null;
    currentSong = song;
    if (queue != null && queue.isNotEmpty) {
      this.queue = queue;
      _queueRevision++;
      _queueExpansionFuture = null;
    } else if (this.queue.isEmpty) {
      this.queue = [song];
    }
    lyrics = const [];
    _lastDesktopLyricIndex = -1;
    notifyListeners();
    unawaited(_syncDesktopLyricsVisibility());
    // 切歌即开始加载歌词（缓存命中立即显示，未命中走网络），
    // 与音源解析并行进行，不等音频就绪。
    unawaited(loadLyrics(song));

    try {
      String? networkUrl;
      var cacheQuality = audioQuality;
      LoudnessData? cacheLoudness;
      final local = downloadController?.localSourceFor(song, audioQuality);
      if (local != null) {
        try {
          _restoreLocalLoudness(song, audioQuality, local.loudness);
          await _loadAudioSource(song, local.path);
        } catch (error) {
          if (song.source == SongSource.local) rethrow;
          debugPrint(
            '[KA Music][playback] local source failed for ${song.hash}: $error',
          );
          await downloadController?.deletePlayCache(song, audioQuality);
          final loaded = await _loadNetworkSourceWithFallback(song);
          networkUrl = loaded.url;
          cacheQuality = loaded.quality;
          cacheLoudness = loaded.loudness;
        }
      } else if (song.source == SongSource.local) {
        await _loadAudioSource(song, song.id);
      } else {
        final loaded = await _loadNetworkSourceWithFallback(song);
        networkUrl = loaded.url;
        cacheQuality = loaded.quality;
        cacheLoudness = loaded.loudness;
      }
      isPreparing = false;
      notifyListeners();
      await _audioHandler.play();
      _scheduleSessionPersist();
      // 切歌后应用音量均衡
      await _applyVolumeNormalization();
      // 记录播放历史与本地播放统计（后台执行，不阻塞播放）
      unawaited(_historyService.record(song));
      unawaited(_statsService.recordPlay(song));
      // 连续稳定播放 30 秒后再缓存，避免快速切歌产生无效网络与磁盘 IO。
      if (networkUrl != null) {
        _schedulePlaybackCache(
          song,
          cacheQuality,
          networkUrl,
          loudness: cacheLoudness,
        );
      }
    } catch (error) {
      errorMessage = error.toString();
      isPreparing = false;
      notifyListeners();
    } finally {
      if (isPreparing) {
        isPreparing = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadAudioSource(Song song, String url) {
    return _audioHandler.loadSong(
      song: song,
      url: url,
      queueSongs: queue,
      queueIndex: currentIndex,
    );
  }

  void _restoreLocalLoudness(
    Song song,
    AudioQuality quality,
    LoudnessData? loudness,
  ) {
    if (loudness?.canNormalize == true) {
      _volNormService.cacheLoudness(song.hash, loudness);
      return;
    }
    if (volumeNormalizationEnabled) {
      unawaited(_hydrateLocalLoudness(song, quality));
    }
  }

  Future<void> _hydrateLocalLoudness(Song song, AudioQuality quality) async {
    if (song.source == SongSource.local || song.source == SongSource.netease) {
      return;
    }
    try {
      final playUrl = song.isCloudDrive
          ? await _api.cloudSongUrl(song)
          : await _api.songUrl(song, quality: quality);
      final loudness = playUrl.loudness;
      if (loudness == null || !loudness.canNormalize) return;

      _volNormService.cacheLoudness(song.hash, loudness);
      await downloadController?.updateLocalLoudness(song, quality, loudness);
      if (currentSong?.hash == song.hash && audioQuality == quality) {
        await _applyVolumeNormalization();
      }
    } catch (error) {
      debugPrint(
        '[KA Music][volume-norm] failed to restore cached loudness for '
        '${song.hash}: $error',
      );
    }
  }

  /// 获取并实际加载网络播放源。播放器拒绝 URL 时也会降级音质重试。
  Future<({String url, AudioQuality quality, LoudnessData? loudness})>
  _loadNetworkSourceWithFallback(Song song) async {
    if (song.isCloudDrive) {
      final playUrl = await _api.cloudSongUrl(song);
      if (playUrl.url.isEmpty) {
        throw Exception('云盘歌曲暂时没有可播放地址');
      }
      await _loadAudioSource(song, playUrl.url);
      _volNormService.cacheLoudness(song.hash, playUrl.loudness);
      return (
        url: playUrl.url,
        quality: audioQuality,
        loudness: playUrl.loudness,
      );
    }
    if (song.source == SongSource.netease) {
      final url =
          'https://music.163.com/song/media/outer/url?id=${song.id}.mp3';
      await _loadAudioSource(song, url);
      return (url: url, quality: audioQuality, loudness: null);
    }

    final qualities = <AudioQuality>[audioQuality];
    if (smartQualityEnabled) {
      var quality = _nextLowerQuality(audioQuality);
      while (quality != null) {
        qualities.add(quality);
        quality = _nextLowerQuality(quality);
      }
    }

    Object? lastError;
    StackTrace? lastStackTrace;
    for (final quality in qualities) {
      try {
        final playUrl = await _api.songUrl(song, quality: quality);
        if (playUrl.url.isEmpty) {
          throw Exception('${quality.badge} 暂时没有可播放地址');
        }
        await _loadAudioSource(song, playUrl.url);
        _volNormService.cacheLoudness(song.hash, playUrl.loudness);
        if (quality != audioQuality) {
          debugPrint(
            '[KA Music][smart-quality] ${audioQuality.badge} source failed; '
            'using ${quality.badge}',
          );
        }
        return (url: playUrl.url, quality: quality, loudness: playUrl.loudness);
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        debugPrint(
          '[KA Music][playback] ${quality.badge} source failed for '
          '${song.hash}: $error',
        );
        await audioPlayer.stop();
      }
    }

    Error.throwWithStackTrace(
      lastError ?? Exception('这首歌暂时没有可播放地址'),
      lastStackTrace ?? StackTrace.current,
    );
  }

  /// 返回更低一档的音质；已是最低档时返回 null。
  AudioQuality? _nextLowerQuality(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.lossless:
        return AudioQuality.high;
      case AudioQuality.high:
        return AudioQuality.standard;
      case AudioQuality.standard:
        return null;
    }
  }

  Future<bool> addToQueue(Song song) async {
    final songKey = song.hash.isNotEmpty ? song.hash : song.id;
    final currentSongKey = currentSong == null
        ? ''
        : (currentSong!.hash.isNotEmpty ? currentSong!.hash : currentSong!.id);
    if (songKey.isNotEmpty && songKey == currentSongKey) {
      return false;
    }

    final nextQueue = List<Song>.of(queue);
    final existingIndex = nextQueue.indexWhere((item) {
      final itemKey = item.hash.isNotEmpty ? item.hash : item.id;
      return itemKey.isNotEmpty && itemKey == songKey;
    });
    if (existingIndex >= 0) {
      nextQueue.removeAt(existingIndex);
    }

    if (nextQueue.isEmpty) {
      nextQueue.add(song);
    } else {
      final index = currentIndex;
      final insertIndex = index < 0
          ? 0
          : (index + 1).clamp(0, nextQueue.length);
      nextQueue.insert(insertIndex, song);
    }

    queue = nextQueue;
    await _audioHandler.setSongQueue(
      queueSongs: queue,
      queueIndex: currentIndex,
      currentSong: currentSong,
    );
    notifyListeners();
    return true;
  }

  Future<bool> replaceQueue(List<Song> songs, {int? expectedRevision}) async {
    if (expectedRevision != null && expectedRevision != _queueRevision) {
      return false;
    }
    if (songs.isEmpty) return false;
    final current = currentSong;
    final currentKey = current == null ? '' : _songKey(current);
    final updated = <Song>[];
    final seen = <String>{};
    for (final song in songs) {
      final key = _songKey(song);
      if (key.isNotEmpty && seen.add(key)) updated.add(song);
    }
    if (updated.isEmpty) return false;
    queue = updated;
    if (current != null &&
        currentKey.isNotEmpty &&
        !queue.any((song) => _songKey(song) == currentKey)) {
      queue.insert(0, current);
    }
    await _audioHandler.replaceSongQueue(
      queueSongs: queue,
      queueIndex: currentIndex,
      currentSong: current,
    );
    _queueRevision++;
    notifyListeners();
    return true;
  }

  void registerQueueExpansion(Future<void> future, int expectedRevision) {
    if (expectedRevision != _queueRevision) return;
    _queueExpansionFuture = future;
    future.whenComplete(() {
      if (identical(_queueExpansionFuture, future)) {
        _queueExpansionFuture = null;
      }
    });
  }

  void _schedulePlaybackCache(
    Song song,
    AudioQuality quality,
    String url, {
    LoudnessData? loudness,
  }) {
    _pendingPlayCacheSong = song;
    _pendingPlayCacheQuality = quality;
    _pendingPlayCacheUrl = url;
    _pendingPlayCacheLoudness = loudness;
    _playCacheDelayTimer = Timer(const Duration(seconds: 30), () {
      _playCacheDelayTimer = null;
      if (!isPlaying || currentSong?.hash != song.hash) return;
      final controller = downloadController;
      if (controller == null) return;
      unawaited(
        controller
            .cacheForPlayback(song, quality, url, loudness: loudness)
            .whenComplete(() {
              if (_pendingPlayCacheSong?.hash == song.hash) {
                _pendingPlayCacheSong = null;
                _pendingPlayCacheQuality = null;
                _pendingPlayCacheUrl = null;
                _pendingPlayCacheLoudness = null;
              }
            }),
      );
    });
  }

  void _cancelPendingPlaybackCache() {
    _playCacheDelayTimer?.cancel();
    _playCacheDelayTimer = null;
    final song = _pendingPlayCacheSong;
    final quality = _pendingPlayCacheQuality;
    _pendingPlayCacheSong = null;
    _pendingPlayCacheQuality = null;
    _pendingPlayCacheUrl = null;
    _pendingPlayCacheLoudness = null;
    if (song != null && quality != null) {
      unawaited(downloadController?.cancelPlaybackCache(song, quality));
    }
  }

  void _pausePendingPlaybackCache() {
    _playCacheDelayTimer?.cancel();
    _playCacheDelayTimer = null;
    final song = _pendingPlayCacheSong;
    final quality = _pendingPlayCacheQuality;
    if (song != null && quality != null) {
      unawaited(downloadController?.cancelPlaybackCache(song, quality));
    }
  }

  void _resumePendingPlaybackCache() {
    if (_playCacheDelayTimer != null) return;
    final song = _pendingPlayCacheSong;
    final quality = _pendingPlayCacheQuality;
    final url = _pendingPlayCacheUrl;
    final loudness = _pendingPlayCacheLoudness;
    if (song == null || quality == null || url == null) return;
    if (currentSong?.hash != song.hash) return;
    _schedulePlaybackCache(song, quality, url, loudness: loudness);
  }

  String _songKey(Song song) => song.hash.isNotEmpty ? song.hash : song.id;

  // ===== 播放会话持久化 =====

  /// 防抖保存播放会话（队列 + 当前歌曲 + 播放模式，不含进度）。
  void _scheduleSessionPersist() {
    if (!resumePlaybackEnabled || currentSong == null) return;
    _playbackSessionDirty = true;
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_persistPlaybackSession());
    });
  }

  Future<void> _persistPlaybackSession() async {
    // 脏标记：会话内容未变化时不写盘，避免切后台等场景产生无谓 IO。
    if (!_playbackSessionDirty) return;
    final song = currentSong;
    final cache = cacheService;
    if (song == null || cache == null || !resumePlaybackEnabled) return;
    final songs = queue.isEmpty ? <Song>[song] : queue;
    var index = songs.indexWhere((item) => _songKey(item) == _songKey(song));
    if (index < 0) index = 0;
    try {
      await cache.write(_playbackSessionCacheKey, {
        'queue': songs.map((item) => item.toCache()).toList(),
        'currentIndex': index,
        'playbackMode': playbackMode.name,
      });
      _playbackSessionDirty = false;
    } catch (_) {}
  }

  /// 恢复上次退出时的播放会话：队列、当前歌曲与播放模式。
  /// 不自动播放，用户点击播放后从头播放当前歌曲。
  Future<void> restorePlaybackSession() async {
    if (_playbackSessionRestored || currentSong != null) return;
    _playbackSessionRestored = true;
    try {
      // 直接读偏好，避免与 _restoreSettings 的异步加载产生先后竞争。
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_resumePlaybackSettingKey) ?? true)) return;
      final cache = cacheService;
      if (cache == null) return;
      final cached = await cache.read<Map<String, dynamic>>(
        _playbackSessionCacheKey,
        decode: (json) => json,
        ttl: const Duration(days: 3650),
      );
      final payload = cached?.data;
      if (payload == null) return;
      final songs = asList(payload['queue'])
          .whereType<Map<String, dynamic>>()
          .map(Song.fromCache)
          .toList();
      if (songs.isEmpty) return;
      final index = (asInt(payload['currentIndex']) ?? 0)
          .clamp(0, songs.length - 1)
          .toInt();
      final song = songs[index];
      queue = songs;
      currentSong = song;
      playbackMode = PlaybackMode.values.firstWhere(
        (mode) => mode.name == payload['playbackMode'],
        orElse: () => PlaybackMode.playlistLoop,
      );
      // 同步通知栏队列与媒体元数据；processingState 仍为 idle，
      // audio_service 不会因此显示通知或开始播放。
      await _audioHandler.setSongQueue(
        queueSongs: queue,
        queueIndex: index,
        currentSong: song,
      );
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setResumePlaybackEnabled(bool enabled) async {
    if (resumePlaybackEnabled == enabled) return;
    resumePlaybackEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_resumePlaybackSettingKey, enabled);
    if (!enabled) {
      _sessionSaveTimer?.cancel();
      _playbackSessionDirty = false;
      // 清除已保存的会话，避免之后重新开启时恢复到很旧的状态。
      final cache = cacheService;
      if (cache != null) {
        try {
          await cache.remove(_playbackSessionCacheKey);
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<void> setAudioQuality(
    AudioQuality quality, {
    bool reloadCurrent = false,
  }) async {
    final sameQuality = audioQuality == quality;
    if (sameQuality && !reloadCurrent) {
      return;
    }

    audioQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_audioQualitySettingKey, quality.apiValue);
    notifyListeners();

    if (reloadCurrent && currentSong != null && !sameQuality) {
      await _reloadCurrentSongForQuality();
    }
  }

  /// 开关音质智能切换（播放失败时自动降级重试）。
  Future<void> setSmartQualityEnabled(bool enabled) async {
    if (smartQualityEnabled == enabled) return;
    smartQualityEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smartQualitySettingKey, enabled);
    notifyListeners();
  }

  /// 读取本地播放统计。
  Future<PlaybackStats> getPlaybackStats() => _statsService.getStats();

  /// 清空本地播放统计。
  Future<void> clearPlaybackStats() => _statsService.clear();

  /// 读取播放历史。
  Future<List<Song>> getPlaybackHistory({int limit = 100}) =>
      _historyService.getHistory(limit: limit);

  /// 清空播放历史。
  Future<void> clearPlaybackHistory() => _historyService.clear();

  Future<void> setPlaybackSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 3.0);
    if ((playbackSpeed - clamped).abs() < 0.001) {
      return;
    }
    playbackSpeed = clamped;
    await audioPlayer.setSpeed(clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_playbackSpeedSettingKey, clamped);
    notifyListeners();
  }

  Future<void> setBassBoostEnabled(bool enabled) async {
    if (bassBoostEnabled == enabled) {
      return;
    }
    bassBoostEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bassBoostEnabledSettingKey, enabled);
    await _applyBassBoost();
    notifyListeners();
  }

  Future<void> setBassBoostStrength(
    double strength, {
    bool persist = true,
  }) async {
    final nextStrength = strength.clamp(0.0, 1.0);
    if ((bassBoostStrength - nextStrength).abs() < 0.001) {
      return;
    }
    bassBoostStrength = nextStrength;
    if (bassBoostEnabled) {
      unawaited(_applyBassBoost());
    }
    notifyListeners();

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_bassBoostStrengthSettingKey, nextStrength);
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async {
    if (equalizerEnabled == enabled) {
      return;
    }
    equalizerEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, enabled);
    await _applyEqualizer();
    notifyListeners();
  }

  Future<void> setEqualizerBandLevel(
    int index,
    int levelMillibels, {
    bool persist = true,
  }) async {
    if (index < 0 || index >= equalizerLevels.length) {
      return;
    }
    final clamped = levelMillibels.clamp(
      equalizerConfig.minMillibels,
      equalizerConfig.maxMillibels,
    );
    if (equalizerLevels[index] == clamped) {
      return;
    }
    equalizerLevels = List<int>.of(equalizerLevels)..[index] = clamped;
    equalizerPresetName = '自定义';
    if (equalizerEnabled) {
      unawaited(_applyEqualizer());
    }
    notifyListeners();

    if (persist) {
      await _persistEqualizer();
    }
  }

  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    equalizerPresetName = preset.name;
    equalizerLevels = _levelsForBandCount(
      preset.levels,
      equalizerLevels.length,
    );
    await _persistEqualizer();
    if (equalizerEnabled) {
      await _applyEqualizer();
    }
    notifyListeners();
  }

  Future<void> resetEqualizer() async {
    await applyEqualizerPreset(equalizerPresets.first);
  }

  Future<void> loadLyrics(Song song, {bool force = false}) async {
    final cache = cacheService;
    // v6：hidden 行改为保留在解析结果中、展示层过滤，旧缓存无 hidden 标记。
    final cacheKey = 'cache_lyric_v6_${song.hash}';

    if (song.source == SongSource.local) {
      try {
        final songFile = File(song.id);
        final dotIndex = songFile.path.lastIndexOf('.');
        final lrcPath =
            '${dotIndex != -1 ? songFile.path.substring(0, dotIndex) : songFile.path}.lrc';
        final file = File(lrcPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          String content;
          try {
            content = utf8.decode(bytes);
          } catch (_) {
            content = utf8.decode(bytes, allowMalformed: true);
          }
          final lines = _visibleLyrics(parseLyrics(content));
          if (currentSong?.hash == song.hash) {
            lyrics = lines;
            notifyListeners();
            _syncDesktopLyrics();
          }
          return;
        }
      } catch (e) {
        debugPrint('Failed to load local lyrics: $e');
      }
      if (currentSong?.hash == song.hash) {
        lyrics = const [];
        notifyListeners();
        _syncDesktopLyrics();
      }
      return;
    }

    // 1. 先读缓存，命中则立即显示（无感）
    if (cache != null && !force) {
      try {
        final cached = await cache.read<List<LyricLine>>(
          cacheKey,
          decode: (json) => (json['lines'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LyricLine.fromCache)
              .toList(),
          ttl: const Duration(days: 30),
        );
        final cachedVisible = cached == null
            ? const <LyricLine>[]
            : _visibleLyrics(cached.data);
        if (cached != null &&
            !listEquals(lyrics, cachedVisible) &&
            currentSong?.hash == song.hash) {
          lyrics = cachedVisible;
          notifyListeners();
          _syncDesktopLyrics();
        }
      } catch (_) {}
    }

    // 2. 后台静默刷新
    try {
      final manual = _manualLyricCandidates[song.hash];
      final fresh = manual != null
          ? await _api.lyricsFromCandidate(manual)
          : await _api.lyrics(song);
      if (currentSong?.hash != song.hash) return; // 已切歌，丢弃
      final freshVisible = _visibleLyrics(fresh);
      if (!listEquals(lyrics, freshVisible)) {
        lyrics = freshVisible;
        notifyListeners();
      }
      // 写缓存（缓存完整解析结果含 hidden 行，空歌词也缓存，避免重复请求）
      if (cache != null) {
        unawaited(
          cache.write(cacheKey, {
            'lines': fresh.map((l) => l.toCache()).toList(),
          }),
        );
      }
    } catch (_) {
      if (currentSong?.hash == song.hash && lyrics.isEmpty) {
        lyrics = const [];
        notifyListeners();
      }
    }
    if (currentSong?.hash == song.hash) {
      _syncDesktopLyrics();
    }
  }

  Future<void> togglePlay() async {
    if (audioPlayer.playing) {
      await _audioHandler.pause();
      return;
    }
    // 接续播放恢复的歌曲尚未加载音源：走完整 playSong 从头播放。
    if (audioPlayer.processingState == ProcessingState.idle &&
        currentSong != null) {
      await playSong(currentSong!);
      return;
    }
    if (audioPlayer.processingState == ProcessingState.completed) {
      await _audioHandler.seek(Duration.zero);
    }
    await _audioHandler.play();
  }

  void previewSeek(Duration position) {
    _isScrubbing = true;
    _isSeeking = true;
    _setPositionBase(position, playing: false);
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    final serial = ++_seekSerial;
    final target = _clampPosition(position);
    seekRevision++;
    _isScrubbing = false;
    _isSeeking = true;
    _setPositionBase(target, playing: isPlaying);
    notifyListeners();

    try {
      await _audioHandler.seek(target);
      if (serial != _seekSerial) {
        return;
      }
      _setPositionBase(target, playing: isPlaying);
      _lastDesktopLyricIndex = -1;
      _maybeSyncDesktopLyricFromPosition();
      notifyListeners();
    } finally {
      if (serial == _seekSerial) {
        _isSeeking = false;
        _isScrubbing = false;
      }
    }
  }

  Future<void> next() async {
    final nextSong = await _nextSong();
    if (nextSong == null) return;
    // 队列只有当前一首歌时，"下一曲"语义为从头重播而不是保持进度。
    final current = currentSong;
    if (current != null && _songKey(nextSong) == _songKey(current)) {
      await seek(Duration.zero);
      await _audioHandler.play();
      return;
    }
    await playSong(nextSong, queue: queue);
  }

  Future<void> previous() async {
    final index = currentIndex;
    if (index > 0) {
      await playSong(queue[index - 1], queue: queue);
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> _handleCompleted() async {
    if (_isHandlingCompletion || currentSong == null) return;
    if (_completedSongHash == currentSong!.hash) return;
    _isHandlingCompletion = true;
    _completionFallbackTimer?.cancel();
    _completedSongHash = currentSong!.hash;

    try {
      if (_sleepFinishCurrentSong) {
        _sleepFinishCurrentSong = false;
        _sleepFinishCurrentSongOption = false;
        sleepTimerRemaining = null;
        notifyListeners();
        unawaited(_audioHandler.pause());
        return;
      }

      if (playbackMode == PlaybackMode.singleLoop) {
        _completedSongHash = null;
        await _audioHandler.seek(Duration.zero);
        await _audioHandler.play();
        return;
      }

      final nextSong = await _nextSong();
      if (nextSong == null) {
        await _audioHandler.seek(Duration.zero);
        return;
      }
      await playSong(nextSong, queue: queue);
    } finally {
      _isHandlingCompletion = false;
    }
  }

  void _maybeCompleteFromPosition(Duration value) {
    if (_isSeeking || _isScrubbing || !isPlaying || duration <= Duration.zero) {
      return;
    }
    if (audioPlayer.processingState == ProcessingState.completed) {
      return;
    }

    final remaining = duration - value;
    if (remaining.inMilliseconds <= 750 &&
        (_completionFallbackTimer?.isActive != true)) {
      final delay =
          (remaining > Duration.zero ? remaining : Duration.zero) +
          const Duration(milliseconds: 180);
      _completionFallbackTimer = Timer(delay, () {
        if (!isPlaying || _isSeeking || _isScrubbing) return;
        final currentPosition = audioPlayer.position;
        if (duration > Duration.zero &&
            duration - currentPosition <= const Duration(milliseconds: 220)) {
          unawaited(_handleCompleted());
        }
      });
    }
  }

  Future<void> _reloadCurrentSongForQuality() async {
    final song = currentSong;
    if (song == null) {
      return;
    }

    final resumePlayback = isPlaying;
    final targetPosition = smoothPosition;
    isPreparing = true;
    errorMessage = null;
    notifyListeners();

    try {
      String url;
      String? networkUrl;
      LoudnessData? loudness;
      final local = downloadController?.localSourceFor(song, audioQuality);
      if (local != null) {
        url = local.path;
        loudness = local.loudness;
        _restoreLocalLoudness(song, audioQuality, loudness);
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final PlayUrl playUrl;
        if (song.isCloudDrive) {
          playUrl = await _api.cloudSongUrl(song);
        } else if (song.source == SongSource.netease) {
          playUrl = PlayUrl(
            url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
            hash: song.hash,
          );
        } else {
          playUrl = await _api.songUrl(song, quality: audioQuality);
        }
        if (playUrl.url.isEmpty) {
          throw Exception('当前音质暂时没有可播放地址');
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
        loudness = playUrl.loudness;
        _volNormService.cacheLoudness(song.hash, playUrl.loudness);
      }
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: queue,
        queueIndex: currentIndex,
      );
      if (targetPosition > Duration.zero) {
        await _audioHandler.seek(_clampPosition(targetPosition));
      }
      if (resumePlayback) {
        await _audioHandler.play();
      }
      // 切音质后后台缓存
      if (networkUrl != null) {
        _cancelPendingPlaybackCache();
        _schedulePlaybackCache(
          song,
          audioQuality,
          networkUrl,
          loudness: loudness,
        );
      }
      // 音质切换后重新应用音量均衡
      await _applyVolumeNormalization();
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isPreparing = false;
      notifyListeners();
    }
  }

  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
      // just_audio 内置打断处理已关闭（handleInterruptions: false），
      // 暂停/恢复策略由本监听统一实现：
      // - begin(duck)：系统仅压低音量，忽略；
      // - begin(pause/unknown)：记录打断时是否在播放并暂停；
      //   阻止打断模式则不暂停，立即重新请求焦点抢回，
      //   请求被拒（来电等系统级打断）时让位暂停；
      // - end(pause/unknown)：焦点已随 GAIN 归还，立即恢复播放，
      //   仅当打断时在播放且（自动恢复开启或阻止打断模式）；
      // - 拔耳机（becomingNoisy）：固定暂停，不自动恢复，避免扬声器外放。
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.type == AudioInterruptionType.duck) {
          return;
        }
        if (event.begin) {
          _wasPlayingOnInterruptionBegin = isPlaying;
          if (!_wasPlayingOnInterruptionBegin || currentSong == null) {
            return;
          }
          if (!audioInterruptionEnabled) {
            unawaited(_reclaimAudioFocus());
          } else {
            unawaited(_audioHandler.pause());
          }
        } else {
          final shouldResume = _wasPlayingOnInterruptionBegin &&
              (autoResumeAfterInterruption || !audioInterruptionEnabled);
          _wasPlayingOnInterruptionBegin = false;
          if (!shouldResume || currentSong == null) {
            return;
          }
          if (!isPlaying && !isPreparing) {
            unawaited(_audioHandler.play());
          }
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        _autoResumeTimer?.cancel();
        _wasPlayingOnInterruptionBegin = false;
        if (isPlaying) {
          unawaited(_audioHandler.pause());
        }
      });
      _devicesChangedSub = session.devicesChangedEventStream.listen((event) {
        if (!autoPlayOnDeviceConnected || currentSong == null) {
          return;
        }
        if (!event.devicesAdded.any(_isExternalOutputAudioDevice)) {
          return;
        }
        _autoResumeTimer?.cancel();
        _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
          if (!isPlaying && !isPreparing && currentSong != null) {
            unawaited(_audioHandler.play());
          }
        });
      });
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  /// 阻止打断模式：焦点被抢后立即重新请求，成功则播放全程不中断；
  /// 被拒（来电等系统级打断）时让位暂停，结束后由 end 事件恢复。
  Future<void> _reclaimAudioFocus() async {
    try {
      final session = await AudioSession.instance;
      final granted = await session.setActive(true);
      if (!granted && isPlaying) {
        await _audioHandler.pause();
      }
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  bool _isExternalOutputAudioDevice(AudioDevice device) {
    if (!device.isOutput) return false;
    return const {
      'wiredHeadset',
      'wiredHeadphones',
      'bluetoothSco',
      'bluetoothA2dp',
      'bluetoothLe',
      'usbAudio',
      'dock',
      'airPlay',
      'hdmi',
      'hdmiArc',
      'displayPort',
      'carAudio',
      'auxLine',
      'thunderbolt',
    }.contains(device.type.name);
  }

  /// 根据打断设置生成 AudioSessionConfiguration。
  ///
  /// 两种模式都不声明 willPauseWhenDucked（导航播报等降音打断不暂停，
  /// 由系统压低音量、结束后自动还原，app 侧不介入音量）。
  /// 暂停/恢复策略全部由 [_setupAudioSessionListeners] 实现。
  AudioSessionConfiguration get _audioSessionConfiguration {
    if (audioInterruptionEnabled) {
      return const AudioSessionConfiguration.music();
    }
    // 阻止打断模式：声明需要独占音频焦点，不因降音暂停
    return const AudioSessionConfiguration(
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // 不因其他 App 降音而暂停
      androidWillPauseWhenDucked: false,
    );
  }

  Future<void> setAudioInterruptionEnabled(bool enabled) async {
    if (audioInterruptionEnabled == enabled) return;
    audioInterruptionEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioInterruptionEnabledSettingKey, enabled);
    // 设置变更后立即重新配置 AudioSession，使新策略生效
    unawaited(_reconfigureAudioSession());
    notifyListeners();
  }

  /// 重新配置 AudioSession 以应用最新的打断策略。
  Future<void> _reconfigureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  Future<void> setAutoResumeAfterInterruption(bool enabled) async {
    if (autoResumeAfterInterruption == enabled) return;
    autoResumeAfterInterruption = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoResumeAfterInterruptionSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setAutoPlayOnDeviceConnected(bool enabled) async {
    if (autoPlayOnDeviceConnected == enabled) return;
    autoPlayOnDeviceConnected = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayOnDeviceConnectedSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    if (desktopLyricsEnabled == enabled) return;
    desktopLyricsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, enabled);
    notifyListeners();

    if (enabled) {
      final hasPermission = await _desktopLyrics.checkPermission();
      if (!hasPermission) {
        desktopLyricsEnabled = false;
        await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
        notifyListeners();
        await _desktopLyrics.requestPermission();
        return;
      }
      final song = currentSong;
      if (song != null) {
        await _syncDesktopLyricsVisibility();
      }
    } else {
      await _desktopLyrics.hide();
    }
  }

  bool get _shouldShowDesktopLyrics {
    return desktopLyricsEnabled &&
        currentSong != null &&
        (!_isAppForeground || _desktopLyricsPreviewVisible);
  }

  Future<void> _syncDesktopLyricsVisibility() async {
    if (!_shouldShowDesktopLyrics) {
      await _desktopLyrics.hide();
      return;
    }

    final song = currentSong;
    if (song == null) return;
    final shown = await _desktopLyrics.show(
      title: song.title,
      artist: song.artist,
    );
    if (shown) {
      _syncDesktopLyrics();
      _syncDesktopPlayState();
      _syncDesktopKaraokeProgress();
    }
  }

  void _syncDesktopLyrics() {
    if (!_shouldShowDesktopLyrics) return;
    final index = activeLyricIndex;
    if (lyrics.isEmpty) {
      _desktopLyrics.updateLyrics(current: '', next: '');
      return;
    }
    final current = lyrics[index.clamp(0, lyrics.length - 1)].text;
    final nextIndex = index + 1;
    final next = nextIndex < lyrics.length ? lyrics[nextIndex].text : '';
    _desktopLyrics.updateLyrics(current: current, next: next);
  }

  void _syncDesktopPlayState() {
    if (!_shouldShowDesktopLyrics) return;
    _desktopLyrics.updatePlayState(isPlaying: isPlaying);
  }

  int _lastDesktopLyricIndex = -1;

  void _maybeSyncDesktopLyricFromPosition() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    if (index != _lastDesktopLyricIndex) {
      _lastDesktopLyricIndex = index;
      _syncDesktopLyrics();
      _syncDesktopKaraokeProgress();
    }
  }

  void _syncDesktopKaraokeProgress() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    final position = smoothPosition;
    final lineDuration = line.duration ?? _estimatedLineDuration(index);

    if (line.words.isEmpty) {
      // No word-level data: estimate progress from line duration
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      } else {
        _desktopLyrics.updateKaraokeProgress(
          progress: 1.0,
          lineDuration: null,
          isPlaying: isPlaying,
        );
      }
    } else {
      // Word-level: find active word and compute progress
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      }
    }
  }

  Duration? _estimatedLineDuration(int index) {
    if (index < 0 || index >= lyrics.length) {
      return null;
    }
    final explicit = lyrics[index].duration;
    if (explicit != null && explicit > Duration.zero) {
      return explicit;
    }
    if (index + 1 < lyrics.length) {
      final nextDuration = lyrics[index + 1].time - lyrics[index].time;
      if (nextDuration > Duration.zero) {
        return nextDuration;
      }
    }
    if (duration > lyrics[index].time) {
      final tailDuration = duration - lyrics[index].time;
      if (tailDuration > Duration.zero) {
        return tailDuration;
      }
    }
    return null;
  }

  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _desktopLyricsSettingsKey,
      jsonEncode(settings.toMap()),
    );
    notifyListeners();
    await _desktopLyrics.updateSettings(settings);
  }

  bool get isDesktopLyricsSupported => DesktopLyricsService.isSupportedPlatform;

  void setAppForeground(bool isForeground) {
    if (_isAppForeground == isForeground) return;
    _isAppForeground = isForeground;
    if (desktopLyricsEnabled) {
      _desktopLyrics.setAppForeground(isForeground: isForeground);
      unawaited(_syncDesktopLyricsVisibility());
    }
  }

  Future<void> flushPersistence() async {
    await Future.wait([
      _historyService.flush(),
      _statsService.flush(),
      if (downloadController case final downloads?) downloads.flush(),
      // 退出/切后台时立即落盘播放会话。
      _persistPlaybackSession(),
    ]);
  }

  Future<void> setDesktopLyricsPreviewVisible(bool visible) async {
    if (_desktopLyricsPreviewVisible == visible) return;
    _desktopLyricsPreviewVisible = visible;
    await _syncDesktopLyricsVisibility();
  }

  Future<void> _handleDesktopLyricsVisibility({
    required bool visible,
    required bool userClosed,
  }) async {
    if (!userClosed || !desktopLyricsEnabled) {
      return;
    }
    desktopLyricsEnabled = false;
    _desktopLyricsPreviewVisible = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
    notifyListeners();
  }

  Future<bool> checkDesktopLyricsPermission() =>
      _desktopLyrics.checkPermission();

  Future<void> requestDesktopLyricsPermission() =>
      _desktopLyrics.requestPermission();

  bool get isSleepTimerActive =>
      sleepTimerRemaining != null && sleepTimerRemaining! > Duration.zero;

  bool get isSleepFinishCurrentSong => _sleepFinishCurrentSong;
  bool get sleepFinishCurrentSongOption => _sleepFinishCurrentSongOption;

  /// Set a sleep timer that pauses playback immediately or after current song finishes when it expires.
  void setSleepTimer(Duration duration, {bool finishCurrentSong = false}) {
    _sleepFinishCurrentSongOption = finishCurrentSong;
    _sleepFinishCurrentSong = false;
    _sleepTimer?.cancel();
    _sleepTimerEnd = DateTime.now().add(duration);
    sleepTimerRemaining = duration;
    notifyListeners();

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _sleepTimerEnd;
      if (end == null) return;
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        if (_sleepFinishCurrentSongOption) {
          _sleepTimer?.cancel();
          _sleepTimer = null;
          _sleepTimerEnd = null;
          _sleepFinishCurrentSong = true;
          notifyListeners();
        } else {
          _executeSleepTimer();
        }
      } else {
        sleepTimerRemaining = remaining;
        notifyListeners();
      }
    });
  }

  /// Set a sleep timer that finishes the current song, then stops.
  void setSleepTimerFinishSong(Duration duration) {
    setSleepTimer(duration, finishCurrentSong: true);
  }

  /// Update the sleep timer finish song option dynamically.
  void updateSleepTimerOption(bool finishCurrentSong) {
    if (_sleepTimer != null || _sleepFinishCurrentSong) {
      _sleepFinishCurrentSongOption = finishCurrentSong;
      // If the timer has already expired and is waiting for song to finish,
      // and they turn it OFF, we should stop immediately.
      if (!finishCurrentSong && _sleepFinishCurrentSong) {
        _executeSleepTimer();
      } else {
        notifyListeners();
      }
    }
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
  }

  void _executeSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
    unawaited(_audioHandler.pause());
  }

  // ── 音量均衡 ──

  /// 为当前曲目应用音量均衡增益。
  Future<void> _applyVolumeNormalization({
    bool retryIfSessionPending = true,
  }) async {
    final serial = ++_volumeNormApplySerial;
    final song = currentSong;
    if (song == null) return;

    final loudness = _volNormService.getCachedLoudness(song.hash);
    final sessionId =
        _androidAudioSessionId ?? audioPlayer.androidAudioSessionId;
    final gainDb = loudness == null
        ? null
        : _volNormService.computeGainDb(loudness);

    final gainLinear = await _volNormService.applyForTrack(
      audioSessionId: sessionId,
      loudness: loudness,
    );
    if (serial != _volumeNormApplySerial || currentSong?.hash != song.hash) {
      return;
    }

    // 衰减路径（gain < 1.0）通过 just_audio 音量处理；提升路径交给原生增强器。
    await audioPlayer.setVolume(
      _volNormService.enabled && loudness != null && gainLinear < 1.0
          ? gainLinear
          : 1.0,
    );

    if (retryIfSessionPending &&
        _volNormService.enabled &&
        loudness != null &&
        gainDb != null &&
        gainDb > 0.5 &&
        (sessionId == null || sessionId <= 0)) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250)).then((_) async {
          if (currentSong?.hash == song.hash) {
            await _applyVolumeNormalization(retryIfSessionPending: false);
          }
        }),
      );
    }
  }

  /// 切换音量均衡开关。
  Future<void> setVolumeNormalizationEnabled(bool enabled) async {
    if (volumeNormalizationEnabled == enabled) return;
    volumeNormalizationEnabled = enabled;
    _volNormService.enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_volumeNormEnabledSettingKey, enabled);
    notifyListeners();

    if (enabled) {
      final song = currentSong;
      if (song != null) {
        final local = downloadController?.localSourceFor(song, audioQuality);
        if (local != null) {
          _restoreLocalLoudness(song, audioQuality, local.loudness);
        }
      }
    }
    await _applyVolumeNormalization();
  }

  /// 设置参考响度（-16 ~ -6 LUFS）。
  Future<void> setVolumeNormalizationRefLufs(double value) async {
    final clamped = value.clamp(-16.0, -6.0);
    if ((volumeNormalizationRefLufs - clamped).abs() < 0.1) return;
    volumeNormalizationRefLufs = clamped;
    _volNormService.referenceLufs = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeNormRefLufsSettingKey, clamped);
    notifyListeners();

    // 如果正在播放且均衡已启用，重新应用
    if (_volNormService.enabled && currentSong != null) {
      await _applyVolumeNormalization();
    }
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    addListeningTimeEnabled =
        prefs.getBool(_listenTimeSettingKey) ?? addListeningTimeEnabled;
    audioQuality = AudioQuality.fromApiValue(
      prefs.getString(_audioQualitySettingKey),
    );
    smartQualityEnabled =
        prefs.getBool(_smartQualitySettingKey) ?? smartQualityEnabled;
    equalizerEnabled =
        prefs.getBool(_equalizerEnabledSettingKey) ?? equalizerEnabled;
    equalizerPresetName =
        prefs.getString(_equalizerPresetSettingKey) ?? equalizerPresetName;
    equalizerLevels = _restoreEqualizerLevels(
      prefs.getString(_equalizerLevelsSettingKey),
    );
    equalizerConfig = EqualizerConfig.fallback(equalizerLevels);
    bassBoostEnabled =
        prefs.getBool(_bassBoostEnabledSettingKey) ?? bassBoostEnabled;
    bassBoostStrength =
        prefs.getDouble(_bassBoostStrengthSettingKey) ?? bassBoostStrength;
    audioInterruptionEnabled =
        prefs.getBool(_audioInterruptionEnabledSettingKey) ??
        audioInterruptionEnabled;
    autoResumeAfterInterruption =
        prefs.getBool(_autoResumeAfterInterruptionSettingKey) ??
        autoResumeAfterInterruption;
    autoPlayOnDeviceConnected =
        prefs.getBool(_autoPlayOnDeviceConnectedSettingKey) ??
        autoPlayOnDeviceConnected;
    resumePlaybackEnabled =
        prefs.getBool(_resumePlaybackSettingKey) ?? resumePlaybackEnabled;
    playbackSpeed = prefs.getDouble(_playbackSpeedSettingKey) ?? playbackSpeed;
    desktopLyricsEnabled =
        prefs.getBool(_desktopLyricsEnabledSettingKey) ?? desktopLyricsEnabled;
    volumeNormalizationEnabled =
        prefs.getBool(_volumeNormEnabledSettingKey) ??
        volumeNormalizationEnabled;
    volumeNormalizationRefLufs =
        prefs.getDouble(_volumeNormRefLufsSettingKey) ??
        volumeNormalizationRefLufs;
    final lyricMode = prefs.getString('settings.lyric_display_mode');
    lyricDisplayMode = LyricDisplayMode.values.firstWhere(
      (mode) => mode.name == lyricMode,
      orElse: () => lyricDisplayMode,
    );
    final manualLyricsRaw = prefs.getString(_manualLyricCandidatesSettingKey);
    if (manualLyricsRaw != null) {
      try {
        final decoded = jsonDecode(manualLyricsRaw);
        if (decoded is Map) {
          _manualLyricCandidates
            ..clear()
            ..addAll({
              for (final entry in decoded.entries)
                if (entry.value is Map)
                  entry.key.toString(): LyricCandidate.fromJson(
                    asMap(entry.value),
                  ),
            });
        }
      } catch (_) {}
    }
    _volNormService.enabled = volumeNormalizationEnabled;
    _volNormService.referenceLufs = volumeNormalizationRefLufs;
    final dlSettingsRaw = prefs.getString(_desktopLyricsSettingsKey);
    if (dlSettingsRaw != null && dlSettingsRaw.isNotEmpty) {
      try {
        final map = jsonDecode(dlSettingsRaw);
        if (map is Map<String, dynamic>) {
          desktopLyricsSettings = DesktopLyricsSettings.fromMap(map);
        }
      } catch (_) {}
    }
    unawaited(audioPlayer.setSpeed(playbackSpeed));
    if (desktopLyricsEnabled) {
      unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
    }
    _syncListeningTimeTracker();
    unawaited(_refreshEqualizerConfig());
    unawaited(_applyEqualizer());
    unawaited(_applyBassBoost());
    notifyListeners();
  }

  List<int> _restoreEqualizerLevels(String? raw) {
    if (raw == null || raw.isEmpty) {
      return List<int>.of(_defaultEqualizerLevels);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final levels = decoded
            .whereType<num>()
            .map((value) => value.round())
            .toList();
        if (levels.isNotEmpty) {
          return _levelsForBandCount(levels, _defaultEqualizerLevels.length);
        }
      }
    } catch (_) {}
    return List<int>.of(_defaultEqualizerLevels);
  }

  Future<void> _persistEqualizer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, equalizerEnabled);
    await prefs.setString(_equalizerPresetSettingKey, equalizerPresetName);
    await prefs.setString(
      _equalizerLevelsSettingKey,
      jsonEncode(equalizerLevels),
    );
  }

  Future<void> _refreshEqualizerConfig() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    final config = await _audioEffects.equalizerConfig(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
    );
    if (config == null || config.bands.isEmpty) {
      return;
    }
    equalizerConfig = config;
    if (equalizerLevels.length != config.bands.length) {
      equalizerLevels = _levelsForBandCount(
        equalizerLevels,
        config.bands.length,
      );
      unawaited(_persistEqualizer());
    }
    notifyListeners();
  }

  Future<void> _applyEqualizer() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    await _audioEffects.configureEqualizer(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: equalizerEnabled,
      levels: equalizerLevels,
    );
  }

  Future<void> _applyBassBoost() async {
    if (!isBassBoostSupported) {
      return;
    }

    await _audioEffects.configureBassBoost(
      audioSessionId:
          _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
      enabled: bassBoostEnabled,
      strength: bassBoostStrength,
    );
  }

  void _syncListeningTimeTracker() {
    final shouldTrack =
        addListeningTimeEnabled && isPlaying && currentSong != null;
    if (shouldTrack) {
      _listenTimeStartedAt ??= DateTime.now();
      _listenTimeTimer ??= Timer.periodic(
        _listenTimeCheckInterval,
        (_) => unawaited(_maybeReportListeningTime()),
      );
      return;
    }

    _pauseListeningTimeTracker();
  }

  void _pauseListeningTimeTracker() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt != null) {
      _pendingListenTime += DateTime.now().difference(startedAt);
      _listenTimeStartedAt = null;
    }
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  void _resetListeningTimeTracker() {
    _listenTimeStartedAt = null;
    _pendingListenTime = Duration.zero;
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  Duration _trackedListeningTime() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt == null) {
      return _pendingListenTime;
    }
    return _pendingListenTime + DateTime.now().difference(startedAt);
  }

  Future<void> _maybeReportListeningTime() async {
    if (_isReportingListenTime || !addListeningTimeEnabled) {
      return;
    }
    if (_trackedListeningTime() < _listenTimeReportInterval) {
      return;
    }

    _isReportingListenTime = true;
    try {
      await _api.addListeningTime();
      // 上报成功，同步记录本地统计的听歌时长
      unawaited(_statsService.addListenTime(_listenTimeReportInterval));
      final stillPlaying = isPlaying && currentSong != null;
      final remainder = _trackedListeningTime() - _listenTimeReportInterval;
      _pendingListenTime = remainder > Duration.zero
          ? remainder
          : Duration.zero;
      _listenTimeStartedAt = stillPlaying ? DateTime.now() : null;
      if (!stillPlaying) {
        _listenTimeTimer?.cancel();
        _listenTimeTimer = null;
      }
    } catch (error) {
      debugPrint('[KA Music][listen-time] report failed: $error');
    } finally {
      _isReportingListenTime = false;
    }
  }

  Future<Song?> _nextSong() async {
    if (playbackMode == PlaybackMode.shuffle) {
      await _queueExpansionFuture;
    }
    if (queue.isEmpty) {
      return currentSong;
    }

    final index = currentIndex;
    if (playbackMode == PlaybackMode.shuffle) {
      if (queue.length == 1) return queue.first;

      var nextIndex = _random.nextInt(queue.length);
      if (index >= 0) {
        while (nextIndex == index) {
          nextIndex = _random.nextInt(queue.length);
        }
      }
      return queue[nextIndex];
    }

    if (index >= 0 && index < queue.length - 1) {
      return queue[index + 1];
    }

    return queue.first;
  }

  @override
  void dispose() {
    unawaited(flushPersistence());
    _pauseListeningTimeTracker();
    _cancelPendingPlaybackCache();
    _autoResumeTimer?.cancel();
    _sessionSaveTimer?.cancel();
    _sleepTimer?.cancel();
    _positionSub.cancel();
    _durationSub.cancel();
    _stateSub.cancel();
    _processingStateSub.cancel();
    _androidAudioSessionSub.cancel();
    _interruptionSub?.cancel();
    _becomingNoisySub?.cancel();
    _devicesChangedSub?.cancel();
    _completionFallbackTimer?.cancel();
    unawaited(_volNormService.dispose());
    unawaited(
      _audioEffects.configureEqualizer(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        levels: equalizerLevels,
      ),
    );
    unawaited(
      _audioEffects.configureBassBoost(
        audioSessionId:
            _androidAudioSessionId ?? audioPlayer.androidAudioSessionId,
        enabled: false,
        strength: bassBoostStrength,
      ),
    );
    _audioHandler.detachTransportControls();
    _desktopLyrics.setVisibilityChangedHandler(null);
    unawaited(_audioHandler.close());
    unawaited(_desktopLyrics.hide());
    super.dispose();
  }

  void _setPositionBase(Duration value, {required bool playing}) {
    position = _clampPosition(value);
    _positionClock
      ..stop()
      ..reset();
    if (playing) {
      _positionClock.start();
    }
  }

  Duration _clampPosition(Duration value) {
    if (value < Duration.zero) {
      return Duration.zero;
    }
    if (duration > Duration.zero && value > duration) {
      return duration;
    }
    return value;
  }

  List<int> _levelsForBandCount(List<int> source, int count) {
    if (count <= 0) {
      return const [];
    }
    if (source.length == count) {
      return List<int>.of(source);
    }
    if (source.length == 1) {
      return List<int>.filled(count, source.first);
    }

    return [
      for (var index = 0; index < count; index++)
        source[((index / math.max(1, count - 1)) * (source.length - 1))
            .round()],
    ];
  }
}
