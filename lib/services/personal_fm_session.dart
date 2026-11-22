import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/personal_fm_models.dart';
import 'music_api.dart';

/// 下一首歌来自哪里。决定回听栈与前进栈怎么移动。
enum PersonalFmTrackSource {
  /// 从待播候选池取出。
  candidate,

  /// 回听：从历史栈弹回。
  history,

  /// 再次前进：从「回听时暂存」的前进栈取回。
  restored,

  /// 用户临时插播，播完继续推荐。
  manual,
}

/// 一条待播来源。[isFromHistory] 为真表示它是回听后暂存的前进项，
/// 播完这一批就会重新消耗候选。
class PersonalFmUpcomingEntry {
  const PersonalFmUpcomingEntry({
    required this.track,
    required this.isFromHistory,
  });

  final PersonalFmTrack track;
  final bool isFromHistory;
}

/// 首播的三种结果，供页面区分空曲库与失败。
enum PersonalFmStartOutcome { started, empty, failed, cancelled }

/// 一次私人 FM 会话。
///
/// 职责边界：本类只管理**推荐数据与反馈**（候选、回听历史、去重、不喜欢、
/// 在途请求与同步状态），绝不触碰播放器。切歌、完成与媒体控制仍由
/// PlayerController 驱动，它按 [peekNext] / [ensureNextTrack] / [commit] 的
/// 次序把推荐接进既有播放状态机。
///
/// 预留在本类之外完成：调用方先取候选（不消耗），真正提交时才调用 [commit]。
/// 这样「预解析失败」「意图被新点播取代」都不会白掉一首歌。
class PersonalFmSession extends ChangeNotifier {
  PersonalFmSession(
    this._api, {
    required this.ownerKey,
    required this.launchId,
  });

  final MusicApi _api;

  /// 会话归属：账号 + API 来源。变化时必须整体作废，避免迟到响应污染新账号。
  final String ownerKey;

  /// 本次启动标识，只用于诊断。
  final String launchId;

  /// 首版固定：红心、推荐池 0。
  static const PersonalFmMode mode = PersonalFmMode.normal;
  static const int songPoolId = 0;

  /// 待播候选上限。
  static const int maxCandidates = 10;
  static const int refillThreshold = 4;

  /// 回听历史上限。
  static const int maxHistory = 20;

  /// 近期去重记录上限：挡掉「刚播过又被推回来」的歌。
  static const int recentLimit = 120;

  final List<PersonalFmTrack> _candidates = [];
  final List<PersonalFmTrack> _back = [];
  final List<PersonalFmTrack> _forward = [];
  final Set<String> _disliked = <String>{};
  final List<String> _recent = <String>[];

  PersonalFmTrack? _current;
  bool _active = false;
  bool _disposed = false;
  String? _lastError;
  PersonalFmFeedbackState _feedbackState = PersonalFmFeedbackState.idle;
  Future<bool>? _refill;
  Future<void>? _feedback;
  int _refillEpoch = 0;
  int _blockedEpoch = -1;
  int _requestCount = 0;

  /// 当前正在播放的推荐。
  PersonalFmTrack? get current => _current;

  /// 会话是否已启动。仅用户主动开播或重试后为真。
  bool get isActive => _active;

  /// 待播候选数量（已排除不喜欢与近期播过的歌）。
  int get pendingCount =>
      _candidates.where((track) => !_isExcluded(track)).length;

  /// 可回听的条数。
  int get backCount => _back.length;

  /// 是否有可前进的历史（回听后再次点下一首）。
  bool get canGoForward => _forward.isNotEmpty;

  bool get isLoadingRecommendations => _refill != null || _feedback != null;

  /// 按实际播放顺序列出待播来源：先是回听暂存的前进栈，再是候选池。
  ///
  /// 回听项与候选项在界面上要分开表达（「回听」标记、数量边界），所以这里
  /// 一并给出区分它们的 [PersonalFmUpcomingEntry]，而不是只给歌曲。
  Iterable<PersonalFmUpcomingEntry> get upcomingEntries sync* {
    for (final track in _forward.reversed) {
      yield PersonalFmUpcomingEntry(track: track, isFromHistory: true);
    }
    for (final track in _candidates) {
      if (_isExcluded(track)) continue;
      yield PersonalFmUpcomingEntry(track: track, isFromHistory: false);
    }
  }

  /// 候选池中实际可播的曲目（不含回听暂存项）。
  Iterable<PersonalFmTrack> get upcoming sync* {
    for (final entry in upcomingEntries) {
      yield entry.track;
    }
  }

  /// 最近一次请求的错误描述，供页面显示。
  String? get lastError => _lastError;

  /// 离曲反馈的同步状态。
  PersonalFmFeedbackState get feedbackState => _feedbackState;

  /// 本轮累计发出的 FM 请求数，仅用于诊断与功耗核对。
  int get requestCount => _requestCount;

  /// 是否处于「候选耗尽、需要用户重试」的状态。
  bool get isExhausted =>
      _active && peekNext() == null && !isLoadingRecommendations;

  bool _isExcluded(PersonalFmTrack track) {
    final key = track.dedupeKey;
    return _disliked.contains(key) ||
        _recent.contains(key) ||
        track.song.hash.isEmpty;
  }

  /// 不消耗候选地下一次「下一首」会播什么。
  PersonalFmTrack? peekNext() {
    if (!_active) return null;
    return upcoming.firstOrNull;
  }

  /// 下一次「上一首」会回到哪一首；空表示历史用尽。
  PersonalFmTrack? peekPrevious() {
    if (!_active || _back.isEmpty) return null;
    return _back.last;
  }

  /// 取下一首；候选为空时最多补池一次，失败后进入退避直到状态变化。
  ///
  /// [allowRefill] 为 false 时只做纯查询，用于「不想为一次预解析付出请求」
  /// 的场景。
  Future<PersonalFmTrack?> ensureNextTrack({bool allowRefill = true}) async {
    if (!_active) return null;
    final peeked = peekNext();
    if (peeked != null) return peeked;
    if (!allowRefill) return null;
    for (var feedback = _feedback; feedback != null; feedback = _feedback) {
      await feedback;
      if (!_active || _disposed) return null;
      final next = peekNext();
      if (next != null) return next;
    }
    if (_blockedEpoch == _refillEpoch) return null;
    final ok = await _refillCandidates();
    if (!ok) return null;
    return peekNext();
  }

  /// 首次开播：请求首批推荐并选定第一首。
  Future<PersonalFmStartOutcome> start() async {
    if (_disposed) return PersonalFmStartOutcome.failed;
    if (_active) return PersonalFmStartOutcome.started;
    _lastError = null;
    final ok = await _refillCandidates();
    if (_disposed) return PersonalFmStartOutcome.failed;
    if (!ok) {
      final error = _lastError;
      return error == null
          ? PersonalFmStartOutcome.empty
          : PersonalFmStartOutcome.failed;
    }
    // 先激活再取首曲：peekNext 以 isActive 为前提，反过来会永远取到 null。
    _active = true;
    final first = peekNext();
    if (first == null) {
      _active = false;
      return PersonalFmStartOutcome.empty;
    }
    _notify();
    return PersonalFmStartOutcome.started;
  }

  /// 提交一次真正生效的切歌。只有提交过的候选才会离开候选池。
  void commit(PersonalFmTrack track, PersonalFmTrackSource source) {
    final outgoing = _current;
    switch (source) {
      case PersonalFmTrackSource.candidate:
        if (outgoing != null &&
            !identical(outgoing, track) &&
            !_disliked.contains(outgoing.dedupeKey)) {
          _pushBack(outgoing);
        }
        _forward.clear();
        _candidates.removeWhere((item) => item.dedupeKey == track.dedupeKey);
        _remember(track);
      case PersonalFmTrackSource.history:
        if (_back.isNotEmpty && identical(_back.last, track)) {
          _back.removeLast();
        }
        if (outgoing != null &&
            !identical(outgoing, track) &&
            !_disliked.contains(outgoing.dedupeKey)) {
          _forward.add(outgoing);
        }
      case PersonalFmTrackSource.restored:
        if (_forward.isNotEmpty && identical(_forward.last, track)) {
          _forward.removeLast();
        }
        if (outgoing != null &&
            !identical(outgoing, track) &&
            !_disliked.contains(outgoing.dedupeKey)) {
          _pushBack(outgoing);
        }
      case PersonalFmTrackSource.manual:
        if (outgoing != null && !_disliked.contains(outgoing.dedupeKey)) {
          _pushBack(outgoing);
        }
        final key = track.dedupeKey;
        _candidates.removeWhere((candidate) => candidate.dedupeKey == key);
        _forward.removeWhere((candidate) => candidate.dedupeKey == key);
    }
    _current = track;
    // 任何一次有效切歌都解除补池退避：下一位听众（或同一用户下一首）值得
    // 重新尝试，而不是被上一次失败永久卡住。
    _blockedEpoch = -1;
    _notify();
  }

  /// 把当前曲目标记为不喜欢，并从本条会话的候选与回听路径排除。
  ///
  /// 只做本机排除；是否已同步到酷狗由离曲反馈的 [feedbackState] 表示。
  void dislikeCurrent() {
    final current = _current;
    if (current == null) return;
    _disliked.add(current.dedupeKey);
    _candidates.removeWhere((track) => track.dedupeKey == current.dedupeKey);
    _back.removeWhere((track) => track.dedupeKey == current.dedupeKey);
    _forward.removeWhere((track) => track.dedupeKey == current.dedupeKey);
    _notify();
  }

  /// 上报一次离曲。
  ///
  /// [track] 是被离开的那一首（不是刚提交的新曲）。请求带副作用，因此
  /// 不重试、不改参数重发；失败只标记同步状态，不回滚已发生的播放。
  Future<void> reportDeparture(
    PersonalFmTrack track, {
    required PersonalFmAction action,
    required int playtimeSeconds,
    required bool isOverplay,
    bool Function()? canRefill,
  }) {
    if (_disposed || !_active) return Future<void>.value();
    final pending = _feedback ?? _refill;
    late final Future<void> request;
    request =
        Future<void>.sync(() async {
          if (pending != null) await pending;
          if (_disposed || !_active) return;
          await _reportDeparture(
            track,
            action: action,
            playtimeSeconds: playtimeSeconds,
            isOverplay: isOverplay,
          );
          if (!_disposed &&
              _active &&
              canRefill?.call() == true &&
              pendingCount < refillThreshold &&
              peekNext() != null) {
            await _refillCandidates();
          }
        }).whenComplete(() {
          if (identical(_feedback, request)) {
            _feedback = null;
            _notify();
          }
        });
    _feedback = request;
    return request;
  }

  Future<void> _reportDeparture(
    PersonalFmTrack track, {
    required PersonalFmAction action,
    required int playtimeSeconds,
    required bool isOverplay,
  }) async {
    final playtime = playtimeSeconds < 0 ? 0 : playtimeSeconds;
    _feedbackState = PersonalFmFeedbackState.syncing;
    _notify();
    try {
      _requestCount++;
      final batch = await _api.personalFmFeedback(
        action: action,
        hash: track.song.hash,
        songId: track.songId,
        playtimeSeconds: playtime,
        remainSongCount: pendingCount,
        isOverplay: isOverplay,
        mode: mode,
        songPoolId: songPoolId,
      );
      if (_disposed || !_active) return;
      if (batch.ok) {
        _merge(batch.tracks);
        _feedbackState = PersonalFmFeedbackState.synced;
        _lastError = null;
      } else {
        _feedbackState = PersonalFmFeedbackState.failed;
        _lastError = '反馈未确认（status=${batch.status}）';
      }
    } on TimeoutException {
      // 请求已发出、结果未知：不重发，继续用当前缓冲。
      if (_disposed) return;
      _feedbackState = PersonalFmFeedbackState.unknown;
      _lastError = '反馈结果未知';
    } catch (error) {
      if (_disposed) return;
      _feedbackState = PersonalFmFeedbackState.unknown;
      _lastError = error.toString();
    } finally {
      _notify();
    }
  }

  /// 用户主动重试：清空退避与错误后重新补池。
  Future<bool> retry() async {
    if (_disposed) return false;
    _blockedEpoch = -1;
    _lastError = null;
    for (var feedback = _feedback; feedback != null; feedback = _feedback) {
      await feedback;
      if (!_active || _disposed) return false;
      if (peekNext() != null) return true;
    }
    final ok = await _refillCandidates();
    return ok && peekNext() != null;
  }

  /// 结束会话并清空本次会话的全部缓冲。
  ///
  /// 账号 / API 切换与用户手动结束电台都会走到这里。
  void stop() {
    if (_disposed) return;
    _active = false;
    _current = null;
    _candidates.clear();
    _back.clear();
    _forward.clear();
    _recent.clear();
    _disliked.clear();
    _feedbackState = PersonalFmFeedbackState.idle;
    _lastError = null;
    _blockedEpoch = -1;
    _notify();
  }

  /// 单飞补池：并发调用共享同一次请求。
  Future<bool> _refillCandidates() {
    final inFlight = _refill;
    if (inFlight != null) return inFlight;
    final future = _runRefill();
    _refill = future;
    _notify();
    return future.whenComplete(() {
      if (identical(_refill, future)) {
        _refill = null;
        _notify();
      }
    });
  }

  Future<bool> _runRefill() async {
    if (_disposed) return false;
    _refillEpoch++;
    final epoch = _refillEpoch;
    try {
      _requestCount++;
      final batch = await _api.personalFm(
        mode: mode,
        songPoolId: songPoolId,
        remainSongCount: 0,
      );
      if (_disposed) return false;
      if (!batch.ok) {
        _lastError = '推荐暂不可用（status=${batch.status}）';
        _blockedEpoch = epoch;
        _notify();
        return false;
      }
      _merge(batch.tracks);
      if (upcoming.isEmpty) _blockedEpoch = epoch;
      _lastError = null;
      _notify();
      return true;
    } on TimeoutException {
      if (_disposed) return false;
      _lastError = '推荐请求超时';
      _blockedEpoch = epoch;
      _notify();
      return false;
    } catch (error) {
      if (_disposed) return false;
      _lastError = error.toString();
      _blockedEpoch = epoch;
      _notify();
      return false;
    }
  }

  void _merge(List<PersonalFmTrack> incoming) {
    if (incoming.isEmpty) return;
    final known = <String>{
      for (final track in _candidates) track.dedupeKey,
      if (_current != null) _current!.dedupeKey,
      ..._recent,
      ..._disliked,
    };
    for (final track in incoming) {
      if (_candidates.length >= maxCandidates) break;
      final key = track.dedupeKey;
      if (known.contains(key)) continue;
      known.add(key);
      _candidates.add(track);
    }
  }

  void _pushBack(PersonalFmTrack track) {
    _back.add(track);
    if (_back.length > maxHistory) {
      _back.removeRange(0, _back.length - maxHistory);
    }
  }

  void _remember(PersonalFmTrack track) {
    final key = track.dedupeKey;
    _recent.remove(key);
    _recent.add(key);
    if (_recent.length > recentLimit) {
      _recent.removeRange(0, _recent.length - recentLimit);
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
