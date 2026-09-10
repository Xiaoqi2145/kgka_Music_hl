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
import '../services/playback_loudness.dart';
import '../services/playback_stats_service.dart';
import '../services/volume_normalization_service.dart';
import 'download_controller.dart';

/// 预解析好的下一曲播放源（无缝播放）。
class _PreparedNextSource {
  const _PreparedNextSource({
    required this.song,
    required this.songKey,
    required this.url,
    required this.quality,
    this.loudness,
  });

  final Song song;
  final String songKey;
  final String url;
  final AudioQuality quality;
  final LoudnessData? loudness;
}

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
    _audioHandler.onPlaybackIntent = (playing) {
      _cancelAutomaticResume();
      if (!playing) {
        // 暂停也撤销尚在解析/加载中的播放，防止加载完成后反手拉起。
        ++_playRequestGeneration;
        isPreparing = false;
      }
    };
    _desktopLyrics.setVisibilityChangedHandler(_handleDesktopLyricsVisibility);
    _positionSub = audioPlayer.positionStream.listen((value) {
      if (!_isSeeking) {
        _setPositionBase(value, playing: isPlaying);
      }
      _maybeCompleteFromPosition(value);
      _maybeSyncDesktopLyricFromPosition();
      // 无缝播放：临近结束（≤30s）时后台预解析下一曲播放地址。
      if (isPlaying && !_isSeeking) {
        unawaited(_prepareNextSourceIfNeeded());
      }
      // 位置高频更新通过 positionListenable 发送，避免触发全局 ChangeNotifier。
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
      if (!isPreparing &&
          isPlaying &&
          value.processingState == ProcessingState.ready) {
        _playbackLoudness.startPlayback();
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
      unawaited(_applyVolumeNormalization(reason: 'session'));
    });
    _playlistSequenceSub = audioPlayer.sequenceStateStream.listen((state) {
      unawaited(_onPlaylistSequenceChanged(state));
    });
    // 预载子源在过渡瞬间加载失败等运行时错误：自动重载当前曲恢复，
    // 避免播放静默停止。playSong 内部的加载错误由 isPreparing 守卫忽略。
    _playerErrorSub = audioPlayer.errorStream.listen((error) {
      debugPrint(
        '[KA Music][playback] player error ${error.code}: ${error.message}',
      );
      if (_isHandlingPlayerError || isPreparing || _isHandlingCompletion) {
        return;
      }
      final song = currentSong;
      if (song == null) return;
      _isHandlingPlayerError = true;
      unawaited(
        playSong(song, queue: queue).whenComplete(() {
          _isHandlingPlayerError = false;
        }),
      );
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
  bool _isDucked = false;
  double _normalizationVolume = 1.0;

  void _cancelAutomaticResume() {
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _wasPlayingOnInterruptionBegin = false;
    _setDucked(false);
  }

  void _setDucked(bool ducked) {
    if (_isDucked == ducked) return;
    _isDucked = ducked;
    unawaited(_applyPlaybackVolume());
  }

  Future<void> _applyPlaybackVolume() =>
      audioPlayer.setVolume(_normalizationVolume * (_isDucked ? 0.5 : 1.0));
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

  // ===== 无缝播放（下一曲预解析） =====
  static const _gaplessPlaybackSettingKey = 'settings.gapless_playback_enabled';
  bool gaplessPlaybackEnabled = true;
  _PreparedNextSource? _preparedNext;
  bool _preparingNextSource = false;
  int _prepareNextSerial = 0;

  /// 预解析失败后的冷却期，避免在 30 秒窗口内每个 position 刻度都重试。
  DateTime _prepareNextCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放器播放列表（ConcatenatingAudioSource）的镜像：
  /// 与 audioPlayer.currentIndex 一一对应，用于无缝过渡与窗口维护。
  List<Song> _playlistSongs = const [];
  List<String> _playlistUrls = const [];
  StreamSubscription<SequenceState>? _playlistSequenceSub;
  IndexedAudioSource? _activePlaylistSource;
  int _playlistLoadRevision = 0;
  StreamSubscription<PlayerException>? _playerErrorSub;
  bool _isHandlingPlayerError = false;
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

  /// 歌词正在异步加载；不应复用音频准备状态阻塞播放器。
  bool isLoadingLyrics = false;
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
  final _loudnessLookup = LoudnessLookup();
  final _hydratingLoudness = <String, Future<void>>{};
  final _playbackLoudness = PlaybackLoudness();
  AudioQuality? _normalizationQuality;
  bool _disposed = false;
  int _queueRevision = 0;
  Future<void>? _queueExpansionFuture;
  final Map<String, LyricCandidate> _manualLyricCandidates = {};
  int _lyricsLoadGeneration = 0;
  final _lyricMemory = <String, List<LyricLine>>{};
  final _lyricRequests = <String, Future<List<LyricLine>>>{};
  String? _metadataPrefetchKey;
  Song? _metadataPrevious;
  Song? _metadataCurrent;
  Song? _metadataNext;
  final _metadataQualities = <String, AudioQuality>{};
  Set<String> _retainedLyricKeys = {};
  Song? _shuffleNext;
  String? _shuffleContext;
  int _playRequestGeneration = 0;

  /// 高频位置更新只通知进度/歌词组件，不触发整个播放器树重建。
  final ValueNotifier<Duration> positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  LyricCandidate? manualLyricCandidateFor(Song song) =>
      _manualLyricCandidates[song.hash];

  /// 署名/水印隐藏，歌名/歌手标题卡保留展示；二者都保留在解析结果中
  /// 以维持翻译轨的原始行号对齐。
  static List<LyricLine> _visibleLyrics(List<LyricLine> lines) => lines
      .where((line) => !line.hidden || line.titleCard)
      .toList(growable: false);

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
    // 手动选择优先于任何尚未返回的自动歌词请求。
    final requestGeneration = ++_lyricsLoadGeneration;
    final selected = preview ?? await _api.lyricsFromCandidate(candidate);
    if (requestGeneration != _lyricsLoadGeneration ||
        currentSong?.hash != song.hash) {
      return false;
    }
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
    if (requestGeneration == _lyricsLoadGeneration &&
        currentSong?.hash == song.hash) {
      lyrics = _visibleLyrics(selected);
      notifyListeners();
      _syncDesktopLyrics();
    }
    return true;
  }

  Future<void> restoreAutomaticLyrics(Song song) async {
    // 立即使正在进行的自动请求失效，避免它在偏好写入期间回填旧结果。
    ++_lyricsLoadGeneration;
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
    // 模式决定下一曲的选法，预选作废。
    _clearPreparedNext();
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
    _cancelAutomaticResume();
    _audioHandler.invalidatePendingPlay();
    final requestGeneration = ++_playRequestGeneration;
    bool isCurrentRequest() => requestGeneration == _playRequestGeneration;

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
        // 队列上下文变了，预选的下一曲可能不再有效。
        _clearPreparedNext();
        await _audioHandler.setSongQueue(
          queueSongs: this.queue,
          queueIndex: currentIndex,
          currentSong: current,
        );
        if (!isCurrentRequest()) return;
        notifyListeners();
      }
      if (audioPlayer.processingState == ProcessingState.completed) {
        _completedSongHash = null;
        await _audioHandler.seek(Duration.zero);
        if (!isCurrentRequest()) return;
        _selectNormalizationSource(
          song,
          _normalizationQuality ?? audioQuality,
          force: true,
        );
        unawaited(_applyVolumeNormalization());
      }
      if (!isCurrentRequest()) return;
      unawaited(
        _audioHandler.play().catchError((Object error, StackTrace stackTrace) {
          if (!isCurrentRequest()) return;
          errorMessage = error.toString();
          isPreparing = false;
          notifyListeners();
        }),
      );
      _scheduleSessionPersist();
      return;
    }
    _cancelPendingPlaybackCache();
    _completionFallbackTimer?.cancel();
    _completedSongHash = null;
    isPreparing = true;
    errorMessage = null;
    currentSong = song;
    _selectNormalizationSource(song, audioQuality, force: true);
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
          if (!isCurrentRequest()) return;
        } catch (error) {
          if (!isCurrentRequest()) return;
          if (song.source == SongSource.local) rethrow;
          debugPrint(
            '[KA Music][playback] local source failed for ${song.hash}: $error',
          );
          await downloadController?.invalidateLocalSource(song, audioQuality);
          final loaded = await _loadNetworkSourceWithFallback(
            song,
            prepared: _consumePreparedNext(song),
          );
          if (!isCurrentRequest()) return;
          networkUrl = loaded.url;
          cacheQuality = loaded.quality;
          cacheLoudness = loaded.loudness;
        }
      } else if (song.source == SongSource.local) {
        await _loadAudioSource(song, song.id);
        if (!isCurrentRequest()) return;
      } else {
        final loaded = await _loadNetworkSourceWithFallback(
          song,
          prepared: _consumePreparedNext(song),
        );
        if (!isCurrentRequest()) return;
        networkUrl = loaded.url;
        cacheQuality = loaded.quality;
        cacheLoudness = loaded.loudness;
      }
      // 主路径播放后，未消费的预解析已随 _loadAudioSource 作废。
      if (!isCurrentRequest()) return;
      isPreparing = false;
      notifyListeners();
      unawaited(
        _audioHandler.play().catchError((Object error, StackTrace stackTrace) {
          if (!isCurrentRequest()) return;
          errorMessage = error.toString();
          isPreparing = false;
          notifyListeners();
        }),
      );
      if (!isCurrentRequest()) return;
      _scheduleSessionPersist();
      // 切歌后立即独立应用音量均衡；不得占用播放/拖拽主流程。
      unawaited(_applyVolumeNormalization());
      if (!isCurrentRequest()) return;
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
      if (!isCurrentRequest()) return;
      errorMessage = error.toString();
      isPreparing = false;
      notifyListeners();
    } finally {
      if (isCurrentRequest() && isPreparing) {
        isPreparing = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadAudioSource(Song song, String url) async {
    ++_playlistLoadRevision;
    _activePlaylistSource = null;
    // 在开始加载时冻结歌单和目标下标，避免异步期间 currentSong 改变导致偏移。
    final queueSnapshot = List<Song>.of(queue);
    final foundIndex = queueSnapshot.indexWhere(
      (item) => _songKey(item) == _songKey(song),
    );
    final queueIndex = foundIndex < 0 ? 0 : foundIndex;
    _playlistSongs = [song];
    _playlistUrls = [url];
    _preparedNext = null;
    await _audioHandler.loadSong(
      song: song,
      url: url,
      queueSongs: queueSnapshot,
      queueIndex: queueIndex,
    );
  }

  String _metadataSongKey(Song song) => '${song.source.name}:${_songKey(song)}';

  void _retainMetadataWindow() {
    final songs = <Song>[?_metadataPrevious, ?_metadataCurrent, ?_metadataNext];
    final identities = songs.map(_metadataSongKey).toSet();
    _metadataQualities.removeWhere((key, _) => !identities.contains(key));
    _retainedLyricKeys = songs.map(_lyricKey).toSet();
    _lyricMemory.removeWhere((key, _) => !_retainedLyricKeys.contains(key));
    _loudnessLookup.retainKeys(
      songs
          .map(
            (song) => _loudnessKey(
              song,
              _metadataQualities[_metadataSongKey(song)] ?? audioQuality,
            ),
          )
          .toSet(),
    );
  }

  String _loudnessKey(Song song, AudioQuality quality) =>
      '${song.source.name}:${_songKey(song)}:${quality.apiValue}';

  void _selectNormalizationSource(
    Song song,
    AudioQuality quality, {
    bool force = false,
  }) {
    if (_metadataCurrent == null ||
        _metadataSongKey(_metadataCurrent!) != _metadataSongKey(song)) {
      _metadataPrevious = _metadataCurrent;
      _metadataCurrent = song;
      _metadataNext = null;
    }
    _metadataQualities[_metadataSongKey(song)] = quality;
    _retainMetadataWindow();
    final key = _loudnessKey(song, quality);
    if (!force && _playbackLoudness.key == key) return;
    ++_volumeNormApplySerial;
    _volNormService.invalidatePending();
    _normalizationQuality = quality;
    _playbackLoudness.begin(key, _loudnessLookup.get(key));
    debugPrint(
      '[KA Music][volume-norm] source key=$key generation=${_playbackLoudness.generation}',
    );
  }

  void _rememberLoudness(Song song, AudioQuality quality, LoudnessData? data) {
    final key = _loudnessKey(song, quality);
    _loudnessLookup.put(key, data);
    _playbackLoudness.accept(key, _playbackLoudness.generation, data);
  }

  void _restoreLocalLoudness(
    Song song,
    AudioQuality quality,
    LoudnessData? loudness,
  ) {
    final key = _loudnessKey(song, quality);
    final available = loudness?.canNormalize == true
        ? loudness
        : _loudnessLookup.get(key);
    if (available != null) {
      _rememberLoudness(song, quality, available);
      return;
    }
    if (volumeNormalizationEnabled) {
      unawaited(_hydrateLocalLoudness(song, quality));
    }
  }

  Future<void> _hydrateLocalLoudness(Song song, AudioQuality quality) {
    final key =
        '${_loudnessKey(song, quality)}:${_playbackLoudness.generation}';
    return _hydratingLoudness.putIfAbsent(
      key,
      () => _hydrateLocalLoudnessOnce(song, quality).whenComplete(() {
        _hydratingLoudness.remove(key);
      }),
    );
  }

  Future<void> _hydrateLocalLoudnessOnce(
    Song song,
    AudioQuality quality,
  ) async {
    if (song.source == SongSource.local) {
      return;
    }
    final key = _loudnessKey(song, quality);
    final generation = _playbackLoudness.generation;
    try {
      final loudness = await _loudnessLookup.resolve(key, () async {
        final playUrl = song.isCloudDrive
            ? await _api.cloudSongUrl(song)
            : await _api.songUrl(song, quality: quality);
        return playUrl.loudness;
      });
      if (loudness == null || _disposed) return;
      if (_playbackLoudness.accept(key, generation, loudness)) {
        unawaited(_applyVolumeNormalization(reason: 'metadata'));
      } else {
        debugPrint('[KA Music][volume-norm] metadata cached for later: $key');
      }
      // Persist independently: slow storage must never delay gain application.
      await downloadController?.updateLocalLoudness(song, quality, loudness);
    } catch (error) {
      debugPrint(
        '[KA Music][volume-norm] loudness lookup/persist failed: $error',
      );
    }
  }

  /// 获取并实际加载网络播放源。播放器拒绝 URL 时也会降级音质重试。
  Future<({String url, AudioQuality quality, LoudnessData? loudness})>
  _loadNetworkSourceWithFallback(
    Song song, {
    _PreparedNextSource? prepared,
  }) async {
    final generation = _playRequestGeneration;
    void checkCurrent() {
      if (generation != _playRequestGeneration) {
        throw StateError('Superseded playback source');
      }
    }

    // 预解析的源作为首选尝试；加载失败让位后回退完整解析（含音质降级）。
    if (prepared != null) {
      try {
        checkCurrent();
        _selectNormalizationSource(song, prepared.quality);
        _rememberLoudness(song, prepared.quality, prepared.loudness);
        await _loadAudioSource(song, prepared.url);
        return (
          url: prepared.url,
          quality: prepared.quality,
          loudness: prepared.loudness,
        );
      } catch (_) {
        checkCurrent();
        await audioPlayer.stop();
      }
    }
    if (song.isCloudDrive) {
      final playUrl = await _api.cloudSongUrl(song);
      if (playUrl.url.isEmpty) {
        throw Exception('云盘歌曲暂时没有可播放地址');
      }
      checkCurrent();
      _rememberLoudness(song, audioQuality, playUrl.loudness);
      await _loadAudioSource(song, playUrl.url);
      return (
        url: playUrl.url,
        quality: audioQuality,
        loudness: playUrl.loudness,
      );
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
        checkCurrent();
        _selectNormalizationSource(song, quality);
        _rememberLoudness(song, quality, playUrl.loudness);
        await _loadAudioSource(song, playUrl.url);
        if (quality != audioQuality) {
          debugPrint(
            '[KA Music][smart-quality] ${audioQuality.badge} source failed; '
            'using ${quality.badge}',
          );
        }
        return (url: playUrl.url, quality: quality, loudness: playUrl.loudness);
      } catch (error, stackTrace) {
        checkCurrent();
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
    // 插播改变了"下一曲"，预选作废。
    _clearPreparedNext();
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
    // 队列被替换，预选的下一曲可能已不在队列中。
    _clearPreparedNext();
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
      // 队列扩充完成，之前预选的下一曲可能来自旧队列。
      _clearPreparedNext();
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

  // ===== 无缝播放 =====

  void _clearPreparedNext() {
    _prepareNextSerial++;
    _metadataPrefetchKey = null;
    _metadataNext = null;
    _retainMetadataWindow();
    _shuffleNext = null;
    _shuffleContext = null;
    _preparingNextSource = false;
    _preparedNext = null;
    _dropPlaylistTail();
  }

  /// 移除播放列表中当前条目之后的所有子源（预载的下一曲失效时）。
  /// 从后往前移除，保持前面的下标稳定；不动当前条目，不打断播放。
  void _dropPlaylistTail() {
    final state = audioPlayer.sequenceState;
    final current = state.currentIndex;
    if (current == null) return;
    unawaited(
      _removeUpcomingSources(
        state.sequence.skip(current + 1).toList().reversed.toList(),
        _playlistLoadRevision,
      ),
    );
  }

  Future<void> _removeUpcomingSources(
    List<IndexedAudioSource> sources,
    int revision,
  ) async {
    for (final source in sources) {
      if (_disposed || revision != _playlistLoadRevision) return;
      final state = audioPlayer.sequenceState;
      final index = state.sequence.indexOf(source);
      if (index <= (state.currentIndex ?? -1)) continue;
      try {
        await _audioHandler.removePlaylistEntryAt(index);
      } catch (error) {
        debugPrint('[KA Music][playlist] remove tail failed: $error');
        return;
      }
      if (!_disposed && revision == _playlistLoadRevision) {
        _syncPlaylistSnapshot(audioPlayer.sequenceState);
      }
    }
  }

  bool _hasPreloadedNextChild() {
    final index = audioPlayer.currentIndex ?? 0;
    return index + 1 < _playlistSongs.length;
  }

  /// 播放器过渡到播放列表的下一曲（无缝切换，或手动跳转到预载项）：
  /// 音源已就绪无需重新加载，仅切换状态并补齐切歌副作用。
  Future<void> _onPlaylistSequenceChanged(SequenceState state) async {
    if (_disposed) return;
    // Never resolve an index against a separately updated mirror. Removing A
    // from [A,B] may emit B/index=0 before removeAudioSourceAt completes.
    if (!identical(state, audioPlayer.sequenceState)) return;
    final source = state.currentSource;
    final song = source?.tag;
    if (song is! Song || source is! UriAudioSource) return;
    if (isPreparing) {
      // Explicit loads already select their normalization source. Old sources
      // can still emit while pause/load is in flight.
      if (currentSong != null &&
          _metadataSongKey(song) == _metadataSongKey(currentSong!)) {
        _activePlaylistSource = source;
      }
      return;
    }
    _syncPlaylistSnapshot(state);
    if (identical(source, _activePlaylistSource)) return;
    final firstSnapshot = _activePlaylistSource == null;
    _activePlaylistSource = source;
    final index = state.currentIndex!;
    final current = currentSong;
    // A first snapshot after an explicit load only attaches the source identity.
    if (firstSnapshot &&
        current != null &&
        _metadataSongKey(song) == _metadataSongKey(current) &&
        index == 0) {
      return;
    }
    errorMessage = null;
    currentSong = song;
    final prepared = _preparedNext;
    final quality = prepared?.songKey == _songKey(song)
        ? prepared!.quality
        : (_metadataQualities[_metadataSongKey(song)] ?? audioQuality);
    _selectNormalizationSource(song, quality, force: true);
    _playbackLoudness.startPlayback();
    lyrics = const [];
    _lastDesktopLyricIndex = -1;
    _setPositionBase(Duration.zero, playing: isPlaying);
    notifyListeners();
    unawaited(_syncDesktopLyricsVisibility());
    unawaited(loadLyrics(song));
    // Apply only for a new source, never for an index-only renumbering.
    unawaited(_applyVolumeNormalization(reason: 'transition'));
    unawaited(_historyService.record(song));
    unawaited(_statsService.recordPlay(song));
    _scheduleSessionPersist();
    // 预载子源的地址已知，边播边缓存照常调度。
    _cancelPendingPlaybackCache();
    if (index < _playlistUrls.length) {
      final url = _playlistUrls[index];
      if (url.startsWith('http://') || url.startsWith('https://')) {
        _schedulePlaybackCache(
          song,
          quality,
          url,
          loudness: _playbackLoudness.data,
        );
      }
    }
    _preparedNext = null;
    _audioHandler.setCurrentMediaItem(song);
    // 收缩窗口：移除当前条目之前的已播子源。
    await _trimPlaylistBefore(source);
  }

  void _syncPlaylistSnapshot(SequenceState state) {
    if (state.sequence.any(
      (source) => source.tag is! Song || source is! UriAudioSource,
    )) {
      return;
    }
    _playlistSongs = [for (final source in state.sequence) source.tag as Song];
    _playlistUrls = [
      for (final source in state.sequence)
        (source as UriAudioSource).uri.toString(),
    ];
  }

  Future<void> _trimPlaylistBefore(IndexedAudioSource currentSource) async {
    final revision = _playlistLoadRevision;
    while (!_disposed && revision == _playlistLoadRevision) {
      final state = audioPlayer.sequenceState;
      if (!identical(state.currentSource, currentSource) ||
          (state.currentIndex ?? 0) <= 0) {
        return;
      }
      final first = state.sequence.first;
      try {
        await _audioHandler.removePlaylistEntryAt(0);
      } catch (error) {
        debugPrint('[KA Music][playlist] trim failed: $error');
        return;
      }
      if (revision != _playlistLoadRevision || _disposed) return;
      final latest = audioPlayer.sequenceState;
      _syncPlaylistSnapshot(latest);
      // No progress: do not spin or repeatedly remove an unexpected source.
      if (latest.sequence.isNotEmpty &&
          identical(latest.sequence.first, first)) {
        return;
      }
    }
  }

  /// 无缝播放：剩余时长进入 30 秒窗口后，后台解析下一曲的播放地址，
  /// 自动切歌时直接使用，省去一次网络往返。解析失败静默忽略，
  /// 切歌走正常解析路径（含音质降级），不影响正常播放。
  Future<void> _prepareNextSourceIfNeeded() async {
    if (_disposed ||
        _preparedNext != null ||
        _preparingNextSource ||
        _hasPreloadedNextChild() ||
        playbackMode == PlaybackMode.singleLoop ||
        !isPlaying ||
        isPreparing ||
        currentSong == null) {
      return;
    }
    if (DateTime.now().isBefore(_prepareNextCooldownUntil)) {
      return;
    }
    if (duration <= Duration.zero) {
      return;
    }
    final remaining = duration - position;
    if (remaining > const Duration(seconds: 30) ||
        remaining < const Duration(seconds: 3)) {
      return;
    }

    _preparingNextSource = true;
    final serial = ++_prepareNextSerial;
    try {
      final next = await _nextSong();
      if (serial != _prepareNextSerial || next == null || currentSong == null) {
        return;
      }
      final nextKey = _songKey(next);
      if (nextKey == _songKey(currentSong!)) {
        return;
      }
      _metadataNext = next;
      _metadataQualities[_metadataSongKey(next)] = audioQuality;
      _retainMetadataWindow();
      final metadataKey =
          '${_playbackLoudness.generation}:$_queueRevision:${_lyricKey(next)}:${audioQuality.name}:$volumeNormalizationEnabled';
      if (_metadataPrefetchKey != metadataKey) {
        _metadataPrefetchKey = metadataKey;
        unawaited(
          _fetchLyrics(next).then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              debugPrint('[KA Music][prefetch] lyrics failed: $error');
            },
          ),
        );
        if (!gaplessPlaybackEnabled && volumeNormalizationEnabled) {
          final local = downloadController?.localSourceFor(next, audioQuality);
          _restoreLocalLoudness(next, audioQuality, local?.loudness);
        }
      }
      if (!gaplessPlaybackEnabled) return;
      // 本地文件/播放缓存命中的歌加载本身已近乎无缝，无需预解析网络地址。
      if (next.source == SongSource.local) {
        return;
      }
      final quality = audioQuality;
      final local = downloadController?.localSourceFor(next, quality);
      if (local != null) {
        // Cached audio still needs metadata prefetch for older cache indexes.
        _restoreLocalLoudness(next, quality, local.loudness);
        return;
      }

      String url;
      LoudnessData? loudness;
      if (next.isCloudDrive) {
        final playUrl = await _api.cloudSongUrl(next);
        if (playUrl.url.isEmpty) return;
        url = playUrl.url;
        loudness = playUrl.loudness;
      } else {
        final playUrl = await _api.songUrl(next, quality: quality);
        if (playUrl.url.isEmpty) return;
        url = playUrl.url;
        loudness = playUrl.loudness;
      }
      if (serial != _prepareNextSerial || !gaplessPlaybackEnabled) {
        return;
      }
      _loudnessLookup.put(_loudnessKey(next, quality), loudness);
      // 播列化：追加为预载子源，ExoPlayer 在当前曲末尾自动预载缓冲，
      // 过渡由播放器原生完成（样本级无缝）。
      final loadRevision = _playlistLoadRevision;
      final beforeAppend = audioPlayer.sequenceState.sequence.toSet();
      try {
        await _audioHandler.appendPlaylistEntry(next, url);
      } catch (_) {
        _prepareNextCooldownUntil = DateTime.now().add(
          const Duration(seconds: 15),
        );
        return;
      }
      if (loadRevision != _playlistLoadRevision || _disposed) return;
      if (serial != _prepareNextSerial) {
        final added = audioPlayer.sequenceState.sequence
            .where(
              (source) =>
                  !beforeAppend.contains(source) && identical(source.tag, next),
            )
            .toList();
        await _removeUpcomingSources(added, loadRevision);
        return;
      }
      _syncPlaylistSnapshot(audioPlayer.sequenceState);
      // Transition may already have consumed the appended source before ack.
      if (_metadataSongKey(currentSong!) == _metadataSongKey(next)) return;
      _preparedNext = _PreparedNextSource(
        song: next,
        songKey: nextKey,
        url: url,
        quality: quality,
        loudness: loudness,
      );
    } catch (_) {
      // 预解析失败：冷却 15 秒后重试，避免窗口内每个刻度都重试。
      _prepareNextCooldownUntil = DateTime.now().add(
        const Duration(seconds: 15),
      );
    } finally {
      if (serial == _prepareNextSerial) {
        _preparingNextSource = false;
      }
    }
  }

  /// 取出与 [song] 匹配的预解析源；无论是否匹配都清空预解析状态
  /// （任何主路径播放都会使旧的预解析失效）。
  _PreparedNextSource? _consumePreparedNext(Song song) {
    final prepared = _preparedNext;
    if (prepared == null) return null;
    _preparedNext = null;
    return prepared.songKey == _songKey(song) ? prepared : null;
  }

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
      final songs = asList(
        payload['queue'],
      ).whereType<Map<String, dynamic>>().map(Song.fromCache).toList();
      if (songs.isEmpty) return;
      final index = (asInt(payload['currentIndex']) ?? 0)
          .clamp(0, songs.length - 1)
          .toInt();
      final song = songs[index];
      queue = songs;
      currentSong = song;
      _selectNormalizationSource(song, audioQuality, force: true);
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

  Future<void> setGaplessPlaybackEnabled(bool enabled) async {
    if (gaplessPlaybackEnabled == enabled) return;
    gaplessPlaybackEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_gaplessPlaybackSettingKey, enabled);
    if (!enabled) {
      // 丢弃已预解析的下一曲与在途解析。
      _clearPreparedNext();
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
    // 播放地址与音质绑定，音质变化后预解析的下一曲地址作废。
    _clearPreparedNext();
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

  String _lyricKey(Song song) =>
      '${song.source.name}:${_songKey(song)}:${jsonEncode(_manualLyricCandidates[song.hash]?.toJson())}';

  Future<List<LyricLine>> _fetchLyrics(Song song, {bool force = false}) {
    _retainMetadataWindow();
    final key = _lyricKey(song);
    if (!force) {
      final cached = _lyricMemory[key];
      if (cached != null) return Future.value(cached);
      final pending = _lyricRequests[key];
      if (pending != null) return pending;
    }
    late final Future<List<LyricLine>> request;
    request = _readLyrics(song, force: force)
        .then((lines) {
          if (!_disposed && identical(_lyricRequests[key], request)) {
            if (_retainedLyricKeys.contains(key)) {
              _lyricMemory[key] = List<LyricLine>.unmodifiable(lines);
            }
          }
          return lines;
        })
        .whenComplete(() {
          if (identical(_lyricRequests[key], request)) {
            _lyricRequests.remove(key);
          }
        });
    _lyricRequests[key] = request;
    return request;
  }

  Future<List<LyricLine>> _readLyrics(Song song, {required bool force}) async {
    if (song.source == SongSource.local) {
      final dot = song.id.lastIndexOf('.');
      final path = dot < 0 ? song.id : song.id.substring(0, dot);
      final file = File('$path.lrc');
      if (!await file.exists()) return const [];
      return parseLyrics(
        utf8.decode(await file.readAsBytes(), allowMalformed: true),
      );
    }
    final cache = cacheService;
    final key = 'cache_lyric_v9_${Uri.encodeComponent(_lyricKey(song))}';
    if (!force && cache != null) {
      try {
        final cached = await cache.read<List<LyricLine>>(
          key,
          decode: (json) => (json['lines'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LyricLine.fromCache)
              .toList(),
          ttl: null,
        );
        if (cached != null && cached.data.isNotEmpty) return cached.data;
      } catch (_) {}
    }
    final manual = _manualLyricCandidates[song.hash];
    final lines = manual != null
        ? await _api.lyricsFromCandidate(manual)
        : await _api.lyrics(song, isCancelled: () => _disposed);
    if (!_disposed && cache != null && lines.isNotEmpty) {
      unawaited(
        cache
            .write(key, {'lines': lines.map((l) => l.toCache()).toList()})
            .catchError((Object error, StackTrace stack) {
              debugPrint(
                '[KA Music][prefetch] lyric cache write failed: $error',
              );
            }),
      );
    }
    return lines;
  }

  Future<void> loadLyrics(Song song, {bool force = false}) async {
    final generation = ++_lyricsLoadGeneration;
    final key = _lyricKey(song);
    bool current() =>
        !_disposed &&
        generation == _lyricsLoadGeneration &&
        currentSong != null &&
        _lyricKey(currentSong!) == key;
    if (!current()) return;
    isLoadingLyrics = true;
    notifyListeners();
    try {
      final lines = await _fetchLyrics(song, force: force);
      if (!current()) return;
      lyrics = _visibleLyrics(lines);
    } catch (error) {
      debugPrint('[KA Music][lyrics] load failed: $error');
    } finally {
      if (current()) {
        isLoadingLyrics = false;
        notifyListeners();
        _syncDesktopLyrics();
      }
    }
  }

  Future<void> togglePlay() async {
    // 手动操作优先于自动恢复。
    _cancelAutomaticResume();
    if (audioPlayer.playing) {
      await _audioHandler.pause();
      return;
    }
    final generation = _playRequestGeneration;
    // 接续播放恢复的歌曲尚未加载音源：走完整 playSong 从头播放。
    if (audioPlayer.processingState == ProcessingState.idle &&
        currentSong != null) {
      await playSong(currentSong!);
      return;
    }
    if (audioPlayer.processingState == ProcessingState.completed) {
      await _audioHandler.seek(Duration.zero);
    }
    if (generation != _playRequestGeneration) return;
    await _audioHandler.play();
  }

  void previewSeek(Duration position) {
    _isScrubbing = true;
    _isSeeking = true;
    // 拖拽预览只更新进度/歌词监听器，避免每个 pointer move 重建整个播放器。
    _setPositionBase(position, playing: false);
  }

  Future<void> seek(Duration position) async {
    final serial = ++_seekSerial;
    final target = _clampPosition(position);
    seekRevision++;
    _isScrubbing = false;
    _isSeeking = true;
    _setPositionBase(target, playing: isPlaying);
    notifyListeners();

    // 提交 seek 后不等待平台完成：位置、进度条和歌词立即以目标时间继续，
    // 原生播放器的异步确认只负责在完成后解除 position stream 的抑制。
    unawaited(
      _audioHandler
          .seek(target)
          .whenComplete(() {
            if (serial != _seekSerial) return;
            _setPositionBase(target, playing: isPlaying);
            _lastDesktopLyricIndex = -1;
            _maybeSyncDesktopLyricFromPosition();
            _isSeeking = false;
            _isScrubbing = false;
            // 只在一次 seek 最终完成时发送语义状态更新。
            notifyListeners();
          })
          .catchError((Object error, StackTrace stackTrace) {
            if (serial != _seekSerial) return;
            _isSeeking = false;
            _isScrubbing = false;
          }),
    );
  }

  Future<void> next() async {
    _cancelAutomaticResume();
    _audioHandler.invalidatePendingPlay();
    final generation = ++_playRequestGeneration;
    // 预载的下一曲已就绪：直接跳转，瞬时切换（无需重新解析加载）。
    final playlistIndex = audioPlayer.currentIndex ?? -1;
    if (playlistIndex >= 0 && playlistIndex + 1 < _playlistSongs.length) {
      await audioPlayer.seek(Duration.zero, index: playlistIndex + 1);
      if (generation != _playRequestGeneration) return;
      unawaited(_audioHandler.play());
      return;
    }
    final nextSong = await _nextSong();
    if (generation != _playRequestGeneration || nextSong == null) return;
    // 队列只有当前一首歌时，"下一曲"语义为从头重播而不是保持进度。
    final current = currentSong;
    if (current != null && _songKey(nextSong) == _songKey(current)) {
      await seek(Duration.zero);
      if (generation != _playRequestGeneration) return;
      await _audioHandler.play();
      return;
    }
    await playSong(nextSong, queue: queue);
  }

  Future<void> previous() async {
    _cancelAutomaticResume();
    _audioHandler.invalidatePendingPlay();
    ++_playRequestGeneration;
    final index = currentIndex;
    if (index > 0) {
      await playSong(queue[index - 1], queue: queue);
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> _handleCompleted() async {
    if (_isHandlingCompletion || currentSong == null || !audioPlayer.playing) {
      return;
    }
    if (_completedSongHash == currentSong!.hash) return;
    _cancelAutomaticResume();
    final generation = _playRequestGeneration;
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
        if (generation != _playRequestGeneration) return;
        await _audioHandler.play();
        return;
      }

      // 无缝播放：优先使用预解析时选定的下一曲（随机模式下同样成立，
      // 预选在歌曲开始时已定，随机性等价）。
      final preparedSong = _preparedNext?.song;
      final nextSong = preparedSong ?? await _nextSong();
      if (generation != _playRequestGeneration) return;
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
    // 预载的下一曲存在时，过渡由播放器无缝完成，不做完成兜底。
    if (_hasPreloadedNextChild()) {
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
        // 预载子源在兜底等待期间就绪时，过渡交给播放器完成。
        if (_hasPreloadedNextChild()) return;
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
    final generation = ++_playRequestGeneration;
    final quality = audioQuality;
    bool isCurrent() => !_disposed && generation == _playRequestGeneration;
    _audioHandler.invalidatePendingPlay();
    _selectNormalizationSource(song, quality, force: true);
    final targetPosition = smoothPosition;
    isPreparing = true;
    errorMessage = null;
    notifyListeners();

    try {
      String url;
      String? networkUrl;
      LoudnessData? loudness;
      final local = downloadController?.localSourceFor(song, quality);
      if (local != null) {
        url = local.path;
        loudness = local.loudness;
        _restoreLocalLoudness(song, quality, loudness);
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final PlayUrl playUrl;
        if (song.isCloudDrive) {
          playUrl = await _api.cloudSongUrl(song);
        } else {
          playUrl = await _api.songUrl(song, quality: quality);
        }
        if (playUrl.url.isEmpty) {
          throw Exception('当前音质暂时没有可播放地址');
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
        loudness = playUrl.loudness;
        if (!isCurrent()) return;
        _rememberLoudness(song, quality, playUrl.loudness);
      }
      if (!isCurrent()) return;
      await _loadAudioSource(song, url);
      if (!isCurrent()) return;
      if (targetPosition > Duration.zero) {
        await _audioHandler.seek(_clampPosition(targetPosition));
      }
      if (!isCurrent()) return;
      isPreparing = false;
      if (resumePlayback) {
        unawaited(
          _audioHandler.play().catchError((Object error, StackTrace stack) {
            if (!isCurrent()) return;
            errorMessage = error.toString();
            notifyListeners();
          }),
        );
      }
      // play() completes on pause/end, not on startup. Never await it here.
      unawaited(_applyVolumeNormalization());
      // 切音质后后台缓存
      if (networkUrl != null) {
        _cancelPendingPlaybackCache();
        _schedulePlaybackCache(song, quality, networkUrl, loudness: loudness);
      }
    } catch (error) {
      if (!isCurrent()) return;
      errorMessage = error.toString();
    } finally {
      if (isCurrent()) {
        isPreparing = false;
        notifyListeners();
      }
    }
  }

  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
      // just_audio 内置打断处理已关闭（handleInterruptions: false），
      // 暂停/恢复策略由本监听统一实现：
      // - begin/end(duck)：收到回调时由应用降音/恢复；系统自动 duck 无需回调；
      // - begin(pause/unknown)：记录打断时是否在播放并暂停；
      //   阻止打断模式则不暂停，立即重新请求焦点抢回，
      //   请求被拒（来电等系统级打断）时让位暂停；
      // - end(pause/unknown)：焦点已随 GAIN 归还，立即恢复播放，
      //   仅当打断时在播放且（自动恢复开启或阻止打断模式）；
      // - 拔耳机（becomingNoisy）：固定暂停，不自动恢复，避免扬声器外放。
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.type == AudioInterruptionType.duck) {
          _setDucked(event.begin);
          return;
        }
        _setDucked(false);
        if (event.begin) {
          _autoResumeTimer?.cancel();
          _wasPlayingOnInterruptionBegin =
              _wasPlayingOnInterruptionBegin ||
              audioPlayer.playing ||
              isPreparing;
          ++_playRequestGeneration;
          isPreparing = false;
          _audioHandler.invalidatePendingPlay();
          if (!_wasPlayingOnInterruptionBegin || currentSong == null) {
            return;
          }
          if (!audioInterruptionEnabled) {
            unawaited(_reclaimAudioFocus());
          } else {
            unawaited(_audioHandler.pauseForInterruption());
          }
        } else {
          final shouldResume =
              _wasPlayingOnInterruptionBegin &&
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
        // 即使正在加载或等候焦点，也必须撤销播放意图。
        unawaited(_audioHandler.pause());
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
      // 与通知栏/手动播放共用串行焦点入口，避免旧 native 请求假成功。
      await _audioHandler.reclaimAudioFocus();
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
  /// 导航播报不暂停：支持自动 duck 的 Android 由系统处理，
  /// 其他情况下在 duck 回调中按音量均衡后的基础音量降音/恢复。
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
    if (!enabled) _autoResumeTimer?.cancel();
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
          // 丢弃预载的下一曲，让当前曲自然播完并触发完成暂停逻辑。
          _clearPreparedNext();
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
    _cancelAutomaticResume();
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
    String reason = 'request',
  }) async {
    if (_disposed || isPreparing) return;
    final serial = ++_volumeNormApplySerial;
    final generation = _playbackLoudness.generation;
    final sourceKey = _playbackLoudness.key;
    final watch = Stopwatch()..start();
    final song = currentSong;
    if (song == null) return;
    bool isCurrent() =>
        !_disposed &&
        serial == _volumeNormApplySerial &&
        generation == _playbackLoudness.generation;
    if (isPlaying && audioPlayer.processingState == ProcessingState.ready) {
      _playbackLoudness.startPlayback();
    }
    // Only admitted metadata, never the cache directly: late responses must
    // not sneak in via session callbacks after the startup window closes.
    final loudness = _playbackLoudness.applicableData;
    final sessionId =
        _androidAudioSessionId ?? audioPlayer.androidAudioSessionId;
    final gainDb = loudness == null
        ? null
        : _volNormService.computeGainDb(loudness);

    debugPrint(
      '[KA Music][volume-norm] request key=$sourceKey generation=$generation serial=$serial reason=$reason session=$sessionId lufs=${loudness?.lufs}',
    );
    final gainLinear = await _volNormService.applyForTrack(
      audioSessionId: sessionId,
      loudness: loudness,
      isCurrent: () =>
          isCurrent() &&
          (loudness == null ||
              identical(_playbackLoudness.applicableData, loudness)),
    );
    if (!isCurrent()) {
      debugPrint(
        '[KA Music][volume-norm] stale key=$sourceKey generation=$generation serial=$serial',
      );
      return;
    }
    if (loudness != null && _playbackLoudness.applicableData == null) {
      // The native queue may have outlived the admission window. Reconcile to
      // bypass, including clearing any enhancer left by the previous source.
      unawaited(_applyVolumeNormalization(retryIfSessionPending: false));
      return;
    }

    // 衰减路径（gain < 1.0）通过 just_audio 音量处理；提升路径交给原生增强器。
    _normalizationVolume =
        _volNormService.enabled && loudness != null && gainLinear < 1.0
        ? gainLinear
        : 1.0;
    try {
      debugPrint(
        '[KA Music][volume-norm] volume_requested key=$sourceKey generation=$generation serial=$serial gain=$_normalizationVolume elapsedMs=${watch.elapsedMilliseconds}',
      );
      await _applyPlaybackVolume();
      if (isCurrent()) {
        debugPrint(
          '[KA Music][volume-norm] volume_ack key=$sourceKey generation=$generation serial=$serial gain=$_normalizationVolume elapsedMs=${watch.elapsedMilliseconds}',
        );
      }
      if (isCurrent() && loudness != null && gainLinear != 1.0) {
        _playbackLoudness.markApplied(generation);
      }
    } catch (error) {
      debugPrint('[KA Music][volume-norm] volume apply failed: $error');
    }

    if (retryIfSessionPending &&
        _volNormService.enabled &&
        loudness != null &&
        gainDb != null &&
        gainDb > 0.5 &&
        (sessionId == null || sessionId <= 0)) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250)).then((_) async {
          if (isCurrent()) {
            await _applyVolumeNormalization(retryIfSessionPending: false);
          }
        }),
      );
    }
  }

  void _reopenNormalizationWindow() {
    ++_volumeNormApplySerial;
    _volNormService.invalidatePending();
    final key = _playbackLoudness.key;
    _playbackLoudness.reopen(key == null ? null : _loudnessLookup.get(key));
    final song = currentSong;
    if (_volNormService.enabled && song != null) {
      final quality = _normalizationQuality ?? audioQuality;
      final local = downloadController?.localSourceFor(song, quality);
      if (local != null) {
        _restoreLocalLoudness(song, quality, local.loudness);
      }
    }
    unawaited(_applyVolumeNormalization());
  }

  /// 切换音量均衡开关；立即调度应用，不等待设置持久化。
  Future<void> setVolumeNormalizationEnabled(bool enabled) async {
    if (volumeNormalizationEnabled == enabled) return;
    volumeNormalizationEnabled = enabled;
    _volNormService.enabled = enabled;
    _reopenNormalizationWindow();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_volumeNormEnabledSettingKey, enabled);
  }

  /// 设置参考响度（-16 ~ -6 LUFS）。
  Future<void> setVolumeNormalizationRefLufs(double value) async {
    final clamped = value.clamp(-16.0, -6.0);
    if ((volumeNormalizationRefLufs - clamped).abs() < 0.1) return;
    volumeNormalizationRefLufs = clamped;
    _volNormService.referenceLufs = clamped;
    _reopenNormalizationWindow();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeNormRefLufsSettingKey, clamped);
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
    gaplessPlaybackEnabled =
        prefs.getBool(_gaplessPlaybackSettingKey) ?? gaplessPlaybackEnabled;
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

      final context =
          '${currentSong?.source.name}:${currentSong == null ? '' : _songKey(currentSong!)}:$_queueRevision';
      if (_shuffleContext == context &&
          _shuffleNext != null &&
          queue.contains(_shuffleNext)) {
        return _shuffleNext;
      }
      var nextIndex = _random.nextInt(queue.length);
      if (index >= 0) {
        while (nextIndex == index) {
          nextIndex = _random.nextInt(queue.length);
        }
      }
      _shuffleContext = context;
      _shuffleNext = queue[nextIndex];
      return _shuffleNext;
    }

    if (index >= 0 && index < queue.length - 1) {
      return queue[index + 1];
    }

    return queue.first;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_volumeNormApplySerial;
    _volNormService.invalidatePending();
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
    _playlistSequenceSub?.cancel();
    _playerErrorSub?.cancel();
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
    positionListenable.dispose();
    unawaited(_audioHandler.close());
    unawaited(_desktopLyrics.hide());
    super.dispose();
  }

  void _setPositionBase(Duration value, {required bool playing}) {
    position = _clampPosition(value);
    if (positionListenable.value != position) {
      positionListenable.value = position;
    }
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
