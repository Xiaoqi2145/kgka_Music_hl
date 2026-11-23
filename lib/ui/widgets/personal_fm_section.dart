import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../models/personal_fm_models.dart';
import '../../services/personal_fm_session.dart';
import '../adaptive_layout.dart';
import 'artwork.dart';
import 'cached_artwork_image.dart';
import 'toast.dart';

/// 红心电台卡片底色。与首页 Banner 同一套规则：未开背景图返回原色，
/// 开启后做半透明，让自定义背景透出来。
@visibleForTesting
Color personalFmCardColor(ColorScheme scheme, {required bool frosted}) {
  if (!frosted) return scheme.surfaceContainer;
  final dark = scheme.brightness == Brightness.dark;
  return scheme.surfaceContainer.withValues(alpha: dark ? .68 : .72);
}

/// 自定义背景是否生效，判据与首页 Banner、「我的」页保持一致。
@visibleForTesting
bool personalFmFrostedActive(ThemeController theme) =>
    theme.backgroundEnabled && theme.backgroundImagePath != null;

/// 首页「电台」标签的内容：酷狗账号驱动的私人 FM。
///
/// 首版固定红心模式。页面只负责展示与发起操作；推荐、候选、历史与反馈
/// 归属都在 [PersonalFmSession] 与播放器里，因此离开页面后电台继续播放。
///
/// 进入页面时若候选为空会自动请求一批推荐——**只准备候选，不自动开播**。
class PersonalFmSection extends StatefulWidget {
  const PersonalFmSection({
    super.key,
    required this.auth,
    required this.player,
    required this.visible,
    this.theme,
  });

  final AuthController auth;
  final PlayerController player;

  /// 标签是否可见。不可见时停止重绘，但**不停播**。
  final bool visible;

  /// 用于判断是否启用半透明卡片；为空时按不透明处理。
  final ThemeController? theme;

  @override
  State<PersonalFmSection> createState() => _PersonalFmSectionState();
}

class _PersonalFmSectionState extends State<PersonalFmSection> {
  static const _wideCoverLimit = 4;
  static const _wideCoverEdgePadding = 5.0;
  static const _wideCoverVerticalStep = 4.0;

  PersonalFmSession? _session;
  bool _starting = false;
  bool _liking = false;
  String? _startError;

  /// 页面进入时自动准备候选的请求是否在途。
  ///
  /// 与会话自己的在途请求分开记录：页面只需要一个「正在获取」的指示，
  /// 真正的单飞与退避仍由会话负责。
  bool _preparingRecommendations = false;
  String? _recommendError;

  /// 本次页面生命周期内是否已经自动取过一次候选。
  ///
  /// 自动取候选只发生在「首次进入且候选为空」；之后切标签再回来只复用
  /// 会话与候选，不重新请求。用户点「重新获取 / 重试」不受此限制。
  bool _autoRequested = false;

  /// 会话归属：账号 + API 来源。切换后旧响应不得进入新会话。
  String get _ownerKey =>
      '${AppConfig.effectiveBaseUrl}|'
      '${widget.auth.session?.userId ?? 'anonymous'}';

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_playerChanged);
    widget.auth.addListener(_changed);
    // 卡片材质跟随「是否启用背景图」，主题变化时要重新取色。
    widget.theme?.addListener(_changed);
    _observeSession();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首次进入（含从其它 Home 标签切回）时按会话状态决定是否取候选。
    if (widget.visible) _ensureRecommendations(notify: false);
  }

  @override
  void didUpdateWidget(PersonalFmSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级重建后本组件紧接着会 build，这里只需要改状态、不用 setState。
    if (widget.visible && !oldWidget.visible) {
      _ensureRecommendations(notify: false);
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_playerChanged);
    widget.auth.removeListener(_changed);
    widget.theme?.removeListener(_changed);
    _session?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted && widget.visible) setState(() {});
  }

  void _playerChanged() {
    _observeSession();
    _changed();
  }

  /// 会话对象会在开播 / 退出 / 换账号时整体替换，监听必须跟着换。
  void _observeSession() {
    final next = widget.player.personalFmSession;
    if (identical(next, _session)) return;
    _session?.removeListener(_changed);
    _session = next;
    next?.addListener(_changed);
  }

  /// 进入页面时的唯一自动请求入口。
  ///
  /// - 已有候选或 FM 正在播放：复用会话，不请求。
  /// - 有请求在途：复用同一次请求，只显示加载状态。
  /// - 失败后状态未变：沿用会话退避，不为了页面打开反复请求；用户点重试
  ///   才走 retry 重新请求。
  void _ensureRecommendations({bool retry = false, bool notify = true}) {
    if (_preparingRecommendations) return;
    if (!retry && _autoRequested) return;
    final player = widget.player;
    final session = player.personalFmSession;
    if (!retry) {
      // FM 正在播放：进入页面只展示当前曲目与待播候选，不再请求。
      if (player.personalFmCurrentTrack != null) return;
      if (session?.hasCandidates == true) return;
      if (session?.isLoadingRecommendations == true) return;
    }
    _preparingRecommendations = true;
    _autoRequested = true;
    _recommendError = null;
    if (notify && mounted) setState(() {});
    player
        .preparePersonalFm(ownerKey: _ownerKey, retry: retry)
        .then<void>((outcome) {
          if (!mounted) {
            _preparingRecommendations = false;
            return;
          }
          setState(() {
            _preparingRecommendations = false;
            // 空批不是错误：候选区自己会显示「暂时没有接下来的推荐」。
            _recommendError = switch (outcome) {
              PersonalFmStartOutcome.failed => '网络不可用或推荐服务暂时异常，请重试。',
              _ => null,
            };
          });
        })
        .catchError((Object error) {
          if (!mounted) {
            _preparingRecommendations = false;
            return;
          }
          setState(() {
            _preparingRecommendations = false;
            _recommendError = '推荐请求失败，请重试。';
          });
        });
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final outcome = await widget.player.startPersonalFm(ownerKey: _ownerKey);
      if (!mounted) return;
      setState(() {
        _startError = switch (outcome) {
          PersonalFmStartOutcome.empty => '暂时没有可播放的推荐，稍后再试。',
          PersonalFmStartOutcome.failed => '电台开播失败，请稍后重试。',
          _ => null,
        };
      });
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// 候选区的「重新获取」/「重试」：只补候选，不跳播。
  void _retryRecommendations() {
    if (_preparingRecommendations) return;
    _ensureRecommendations(retry: true);
  }

  /// 点选待播条目：交给播放器解析加载，成功后才消耗候选。
  Future<void> _select(PersonalFmUpcomingItem item) async {
    final player = widget.player;
    // 只在真的有一次解析在进行时屏蔽重复点击；后台补候选不该锁住已有歌曲。
    if (player.isPreparing) return;
    await player.playPersonalFmSong(item.song);
    if (!mounted) return;
    final error = player.errorMessage;
    if (error != null && error.isNotEmpty) {
      Toast.error(error);
    }
  }

  Future<void> _toggleLike(Song song) async {
    if (_liking) return;
    // 收藏歌单尚未就绪时不能把空歌单分支当成成功。
    if (widget.auth.likedPlaylist == null) {
      Toast.info('收藏功能暂不可用，请稍后重试');
      return;
    }
    setState(() => _liking = true);
    try {
      await widget.auth.toggleLike(song);
    } catch (_) {
      if (mounted) Toast.error('收藏操作失败，请重试');
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final current = player.personalFmCurrentTrack;
    final upcoming = player.upcomingPersonalFmEntries.take(5).toList();
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        MediaQuery.sizeOf(context).width >= 900;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      child: LayoutBuilder(
        builder: (context, constraints) =>
            landscape && constraints.maxWidth >= 680
            ? _wideLayout(context, current, upcoming)
            : _compactLayout(context, current, upcoming, constraints.maxWidth),
      ),
    );
  }

  Widget _compactLayout(
    BuildContext context,
    PersonalFmTrack? current,
    List<PersonalFmUpcomingItem> upcoming,
    double width,
  ) {
    final theme = Theme.of(context);
    final song = current?.song;
    final startError = _startError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hero(context, compact: true),
        _compactControlPanel(
          context,
          song,
          width: width,
          hasRecommendations: upcoming.isNotEmpty,
        ),
        if (song == null && startError != null) ...[
          const SizedBox(height: 8),
          Text(
            startError,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 20),
        _upNext(
          context,
          upcoming,
          hasCurrent: song != null,
          twoColumns: AdaptiveLayout.isTablet(context) && width >= 460,
        ),
      ],
    );
  }

  Widget _wideLayout(
    BuildContext context,
    PersonalFmTrack? current,
    List<PersonalFmUpcomingItem> upcoming,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hero(context),
        const SizedBox(height: 14),
        _wideStage(context, current, upcoming),
        if (current != null) ...[
          const SizedBox(height: 16),
          _wideTrackDetails(context, current.song),
        ],
      ],
    );
  }

  Widget _hero(BuildContext context, {bool compact = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 12 : 2),
      child: Row(
        children: [
          Container(
            width: compact ? 42 : 56,
            height: compact ? 42 : 56,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(compact ? 13 : 16),
            ),
            child: Icon(
              Icons.favorite_rounded,
              size: compact ? 23 : 30,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '私人 FM',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideStage(
    BuildContext context,
    PersonalFmTrack? current,
    List<PersonalFmUpcomingItem> upcoming,
  ) {
    final theme = Theme.of(context);
    final items = upcoming
        .take(current == null ? _wideCoverLimit : _wideCoverLimit - 1)
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        const columnGap = 20.0;
        final controlWidth = (constraints.maxWidth * .29).clamp(252.0, 310.0);
        final coverRailWidth = constraints.maxWidth - controlWidth - columnGap;
        final availableCoverWidth = coverRailWidth - _wideCoverEdgePadding * 2;
        // 宽度增加时多露出后面的封面，同时让最后一张靠近栏的右边缘。
        final expansion = ((availableCoverWidth - 390) / 390).clamp(0.0, 1.0);
        final strideRatio = .72 + .22 * expansion;
        final coverSize =
            availableCoverWidth / (1 + strideRatio * (_wideCoverLimit - 1));
        final coverStride = coverSize * strideRatio;
        final textScaler = MediaQuery.textScalerOf(context);
        // 按右栏排满封面时的高度确定卡片尺寸，切换播放状态时保持稳定。
        final titleSize = theme.textTheme.titleMedium?.fontSize ?? 16;
        final captionSize = theme.textTheme.labelLarge?.fontSize ?? 14;
        final subtitleSize = theme.textTheme.labelSmall?.fontSize ?? 11;
        final controlHeight =
            coverSize +
            _wideCoverVerticalStep * (_wideCoverLimit - 1) +
            35 + // 标题、封面与两行文案之间的留白。
            1.45 *
                (textScaler.scale(titleSize) +
                    textScaler.scale(captionSize) +
                    textScaler.scale(subtitleSize));
        return Row(
          key: const ValueKey('personal-fm-wide-stage'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              key: const ValueKey('personal-fm-wide-control-panel'),
              width: controlWidth,
              height: controlHeight,
              child: _wideControlPanel(context, current),
            ),
            const SizedBox(width: columnGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          current == null ? '为你推荐' : '电台曲目',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (_isLoadingUpcoming && items.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (current != null || items.isNotEmpty)
                    _wideCoverStack(
                      context,
                      current,
                      items,
                      size: coverSize,
                      stride: coverStride,
                    ),
                  if (items.isEmpty || _recommendError != null)
                    _wideQueueStatus(context, hasCurrent: current != null),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _wideControlPanel(BuildContext context, PersonalFmTrack? current) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = widget.player;
    final song = current?.song;
    final coverUrl = song?.coverUrl;
    // 当前曲目的封面直接铺在操作区底部，遮罩为浅色封面提供文字对比度。
    final hasCover = coverUrl != null && coverUrl.isNotEmpty;
    final foreground = hasCover ? Colors.white : scheme.onSurface;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          if (hasCover)
            Positioned.fill(
              child: _controlArtwork(
                coverUrl,
                key: const ValueKey('personal-fm-wide-control-artwork'),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: hasCover ? null : _cardColor(context),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: hasCover ? Colors.white24 : scheme.outlineVariant,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 32,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '红心电台',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: song != null
                            ? _wideActions(context, song, onArtwork: hasCover)
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_startError case final error?) ...[
                                    Text(
                                      error,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: scheme.error),
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                  FilledButton.icon(
                                    onPressed: _starting || player.isPreparing
                                        ? null
                                        : _start,
                                    icon: _starting
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.play_arrow_rounded),
                                    label: const Text('开始播放'),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideTrackDetails(BuildContext context, Song song) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final metadata = [
      if (song.albumName case final String album when album.trim().isNotEmpty)
        album,
      if (song.duration case final Duration duration
          when duration > Duration.zero)
        formatDuration(duration),
    ];

    return Container(
      key: const ValueKey('personal-fm-wide-track-details'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .75)),
      ),
      child: Row(
        children: [
          Artwork(
            key: const ValueKey('personal-fm-wide-current-cover'),
            url: song.coverUrl,
            size: 110,
            borderRadius: 12,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前曲目',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.title,
                  key: const ValueKey('personal-fm-wide-current-title'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (metadata.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    metadata.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<({String tooltip, IconData icon, VoidCallback? onTap})> _playbackActions(
    Song song, {
    required bool liked,
  }) {
    final player = widget.player;
    final canAct = !player.isPreparing;
    return [
      (
        tooltip: player.isPlaying ? '暂停' : '播放',
        icon: player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        onTap: canAct ? player.togglePlay : null,
      ),
      (
        tooltip: '下一首',
        icon: Icons.skip_next_rounded,
        onTap: canAct ? player.next : null,
      ),
      (
        tooltip: liked ? '取消喜欢' : '喜欢',
        icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        onTap: _liking || song.source != SongSource.kugou
            ? null
            : () => _toggleLike(song),
      ),
      (
        tooltip: player.personalFmCurrentDisliked ? '已标记不喜欢' : '不喜欢',
        icon: Icons.thumb_down_alt_outlined,
        onTap: canAct && !player.personalFmCurrentDisliked
            ? player.dislikePersonalFmCurrent
            : null,
      ),
    ];
  }

  Widget _wideActions(
    BuildContext context,
    Song song, {
    required bool onArtwork,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final liked = widget.auth.isLiked(song);
    final actions = _playbackActions(song, liked: liked);
    return Row(
      children: [
        for (var index = 0; index < actions.length; index++)
          Expanded(
            child: Center(
              child: index == 0
                  ? IconButton.filled(
                      tooltip: actions[index].tooltip,
                      onPressed: actions[index].onTap,
                      icon: Icon(actions[index].icon, size: 22),
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(40),
                        shape: const CircleBorder(),
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                      ),
                    )
                  : IconButton(
                      tooltip: actions[index].tooltip,
                      onPressed: actions[index].onTap,
                      icon: Icon(
                        actions[index].icon,
                        size: 22,
                        color:
                            actions[index].onTap != null && index == 2 && liked
                            ? (onArtwork
                                  ? scheme.primaryContainer
                                  : scheme.primary)
                            : null,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(36),
                        backgroundColor: onArtwork
                            ? Colors.white.withValues(alpha: .16)
                            : scheme.surface,
                        foregroundColor: onArtwork
                            ? Colors.white
                            : scheme.onSurface,
                        disabledForegroundColor: onArtwork
                            ? Colors.white38
                            : null,
                      ),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _wideCoverStack(
    BuildContext context,
    PersonalFmTrack? current,
    List<PersonalFmUpcomingItem> items, {
    required double size,
    required double stride,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = widget.player;
    final songs = [
      if (current != null) current.song,
      ...items.map((item) => item.song),
    ];
    final hasCurrent = current != null;
    final canSelect = !player.isPreparing;
    final count = songs.length;
    final coversWidth = size + stride * (count - 1);
    final coversHeight = size + _wideCoverVerticalStep * (count - 1);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _wideCoverEdgePadding,
        5,
        _wideCoverEdgePadding,
        8,
      ),
      child: SizedBox(
        width: coversWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: coversHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 后面的封面先画，首张盖住第二张，依此类推。
                  for (var index = count - 1; index >= 0; index--)
                    Positioned(
                      left: stride * index,
                      top: _wideCoverVerticalStep * index,
                      child: _wideStackCover(
                        context,
                        songs[index],
                        size: size,
                        selected: hasCurrent && index == 0,
                        preparing: player.isPreparingSong(songs[index]),
                        onTap: canSelect && (!hasCurrent || index > 0)
                            ? () => _select(items[index - (hasCurrent ? 1 : 0)])
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = 0; index < count; index++)
                  SizedBox(
                    width: index == 0 ? size : stride,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: hasCurrent && index == 0
                          ? Text(
                              songs[index].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : _wideCoverCaption(
                              context,
                              items[index - (hasCurrent ? 1 : 0)],
                              enabled: canSelect,
                            ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _wideStackCover(
    BuildContext context,
    Song song, {
    required double size,
    required bool selected,
    required bool preparing,
    required VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: !selected,
      enabled: selected ? null : onTap != null,
      selected: selected,
      onTap: onTap,
      label: selected ? song.title : '播放 ${song.title}',
      child: DecoratedBox(
        key: selected ? const ValueKey('personal-fm-record-current') : null,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .22),
              blurRadius: 7,
              offset: const Offset(2, 3),
            ),
          ],
        ),
        child: Stack(
          children: [
            Artwork(
              key: selected
                  ? const ValueKey('personal-fm-record-artwork')
                  : null,
              url: song.coverUrl,
              size: size,
              borderRadius: 12,
            ),
            if (selected)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: scheme.primary, width: 2),
                  ),
                ),
              ),
            if (preparing)
              const Positioned.fill(
                child: Center(
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: radius,
                  excludeFromSemantics: true,
                  onTap: onTap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wideCoverCaption(
    BuildContext context,
    PersonalFmUpcomingItem item, {
    required bool enabled,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final song = item.song;
    final subtitle = item.isManual
        ? '插播'
        : item.isFromHistory
        ? '回听'
        : song.artist;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      canRequestFocus: false,
      excludeFromSemantics: true,
      onTap: enabled ? () => _select(item) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wideQueueStatus(BuildContext context, {required bool hasCurrent}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = _recommendError;
    final exhausted = _session?.isExhausted == true;
    final text = error ?? (exhausted ? '候选已用完' : '暂时没有接下来的推荐');
    return Padding(
      padding: EdgeInsets.symmetric(vertical: hasCurrent ? 4 : 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isLoadingUpcoming) ...[
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 12),
            Text(
              '正在获取推荐…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ] else ...[
            Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: error == null ? scheme.onSurfaceVariant : scheme.error,
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _retryRecommendations,
              child: Text(error == null ? '重新获取' : '重试'),
            ),
          ],
        ],
      ),
    );
  }

  /// 候选区当前是否正在等一批推荐（页面请求或会话补池）。
  bool get _isLoadingUpcoming =>
      _preparingRecommendations || _session?.isLoadingRecommendations == true;

  Color _cardColor(BuildContext context) {
    final theme = widget.theme;
    final frosted = theme != null && personalFmFrostedActive(theme);
    return personalFmCardColor(Theme.of(context).colorScheme, frosted: frosted);
  }

  Widget _controlArtwork(String url, {required Key key}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final decodeWidth = artworkDecodePixels(
          size: constraints.maxWidth,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return Stack(
          key: key,
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF202A3B)),
            Image(
              image: ResizeImage.resizeIfNeeded(
                decodeWidth,
                null,
                CachedArtworkImage(url),
              ),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox.shrink(),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99080D18), Color(0xC4080D18)],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _compactControlPanel(
    BuildContext context,
    Song? song, {
    required double width,
    required bool hasRecommendations,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = widget.player;
    final coverUrl = song?.coverUrl;
    final hasCover = coverUrl != null && coverUrl.isNotEmpty;
    final foreground = hasCover ? Colors.white : scheme.onSurface;
    final secondary = hasCover ? Colors.white : scheme.onSurfaceVariant;
    final radius = BorderRadius.circular(18);
    const padding = 14.0;
    const coverGap = 14.0;
    const actionSize = 48.0;
    final titleStyle = theme.textTheme.titleMedium!.copyWith(
      fontSize: 18,
      height: 1.25,
      fontWeight: FontWeight.w800,
      color: foreground,
    );
    final secondaryStyle = theme.textTheme.bodySmall!.copyWith(
      height: 1.3,
      color: secondary,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final innerWidth = width - 2 * padding;
    final preferredCover = (width * .28).clamp(72.0, 128.0);
    final singleActionRow = innerWidth >= 4 * actionSize + coverGap + 80;
    final coverSize = math
        .min(
          preferredCover,
          innerWidth - coverGap - (singleActionRow ? 4 : 2) * actionSize,
        )
        .clamp(0.0, preferredCover);
    final buttonHeight = math.max(
      actionSize,
      textScaler.scale(theme.textTheme.labelLarge!.fontSize!) * 1.4 + 12,
    );
    final actionHeight = math.max(
      buttonHeight,
      singleActionRow ? actionSize : 2 * actionSize,
    );
    // 两种状态共用操作区与曲目信息区，换歌或暂停时卡片和队列不会跳动。
    final detailHeight =
        textScaler.scale(titleStyle.fontSize!) * titleStyle.height! +
        2 *
            textScaler.scale(secondaryStyle.fontSize!) *
            secondaryStyle.height! +
        8;
    final contentHeight = math.max(coverSize, detailHeight + 4 + actionHeight);

    return ClipRRect(
      key: const ValueKey('personal-fm-compact-control-panel'),
      borderRadius: radius,
      child: Stack(
        children: [
          if (hasCover)
            Positioned.fill(
              child: _controlArtwork(
                coverUrl,
                key: const ValueKey('personal-fm-compact-control-artwork'),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: hasCover ? null : _cardColor(context),
              borderRadius: radius,
              border: Border.all(
                color: hasCover ? Colors.white24 : scheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(padding),
              child: SizedBox(
                height: contentHeight,
                child: Row(
                  children: [
                    if (song == null)
                      SizedBox.square(
                        dimension: coverSize,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                scheme.surfaceContainerLow,
                                scheme.primaryContainer,
                              ],
                            ),
                          ),
                          child: Icon(
                            Icons.sensors_rounded,
                            color: scheme.primary,
                          ),
                        ),
                      )
                    else
                      Artwork(url: coverUrl, size: coverSize, borderRadius: 12),
                    const SizedBox(width: coverGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (song != null) ...[
                                  Text(
                                    player.isPlaying ? '正在播放' : '已暂停',
                                    style: secondaryStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    strutStyle: StrutStyle.fromTextStyle(
                                      secondaryStyle,
                                      forceStrutHeight: true,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                ],
                                Text(
                                  song?.title ?? '红心电台',
                                  style: titleStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  strutStyle: StrutStyle.fromTextStyle(
                                    titleStyle,
                                    forceStrutHeight: true,
                                  ),
                                ),
                                if (song != null || hasRecommendations) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    song?.artist ?? '也可以点封面直接播放',
                                    style: secondaryStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    strutStyle: StrutStyle.fromTextStyle(
                                      secondaryStyle,
                                      forceStrutHeight: true,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            height: actionHeight,
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: song == null
                                  ? FilledButton.icon(
                                      onPressed: _starting || player.isPreparing
                                          ? null
                                          : _start,
                                      icon: _starting
                                          ? const SizedBox.square(
                                              dimension: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.play_arrow_rounded,
                                              size: 20,
                                            ),
                                      label: const FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text('开始播放'),
                                      ),
                                      style: FilledButton.styleFrom(
                                        minimumSize: Size(0, buttonHeight),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                      ),
                                    )
                                  : _compactActions(
                                      context,
                                      song,
                                      onArtwork: hasCover,
                                      rowWidth: singleActionRow
                                          ? 4 * actionSize
                                          : 2 * actionSize,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactActions(
    BuildContext context,
    Song song, {
    required bool onArtwork,
    required double rowWidth,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final liked = widget.auth.isLiked(song);
    final actions = _playbackActions(song, liked: liked);
    return SizedBox(
      width: rowWidth,
      child: Wrap(
        children: [
          for (var index = 0; index < actions.length; index++)
            IconButton.filled(
              tooltip: actions[index].tooltip,
              onPressed: actions[index].onTap,
              icon: Icon(actions[index].icon),
              style: IconButton.styleFrom(
                fixedSize: const Size.square(38),
                minimumSize: Size.zero,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.padded,
                shape: const CircleBorder(),
                backgroundColor: index == 0
                    ? scheme.primary
                    : onArtwork
                    ? Colors.white.withValues(alpha: .18)
                    : scheme.surfaceContainerHighest,
                foregroundColor: index == 0
                    ? scheme.onPrimary
                    : index == 2 && liked
                    ? (onArtwork ? scheme.primaryContainer : scheme.primary)
                    : (onArtwork ? Colors.white : scheme.onSurface),
                disabledForegroundColor: onArtwork ? Colors.white38 : null,
              ),
            ),
        ],
      ),
    );
  }

  /// 与「今日推荐」一样，歌曲行直接放在页面背景上。
  ///
  /// 列表区分三种来源：手动插播、回听暂存、候选池。数量说明放在标题右侧，
  /// 让「还有几首」在不滚动的情况下可知。每一行都能直接点播。
  Widget _upNext(
    BuildContext context,
    List<PersonalFmUpcomingItem> entries, {
    required bool hasCurrent,
    required bool twoColumns,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = widget.player;
    final session = _session;
    final loading = _isLoadingUpcoming;
    final exhausted = session?.isExhausted == true;
    // 列表含回听暂存与手动插播，候选计数只统计候选池；两者取大才是
    // 「还剩几首」的真实值，避免出现「共 3 首」却列出 4 行。
    final pending = session?.pendingCount ?? 0;
    final total = pending > entries.length ? pending : entries.length;
    final error = _recommendError;
    final rows = [
      for (final entry in entries)
        _UpNextRow(
          item: entry,
          enabled: !player.isPreparing,
          preparing: player.isPreparingSong(entry.song),
          onTap: () => _select(entry),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                hasCurrent ? '接下来' : '为你推荐',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (entries.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                '共 $total 首',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (loading && entries.isNotEmpty) ...[
              const SizedBox(width: 8),
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        if (entries.isNotEmpty) ...[
          if (twoColumns)
            for (var index = 0; index < rows.length; index += 2)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: rows[index]),
                  const SizedBox(width: 16),
                  Expanded(
                    child: index + 1 < rows.length
                        ? rows[index + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              )
          else
            ...rows,
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _retryRecommendations,
                child: const Text('重试'),
              ),
            ),
          ],
        ] else if (loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    '正在获取推荐…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else ...[
          Text(
            error ?? (exhausted ? '候选已用完' : '暂时没有接下来的推荐'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: error != null ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _retryRecommendations,
              child: Text(error != null ? '重试' : '重新获取'),
            ),
          ),
        ],
      ],
    );
  }
}

/// 「接下来」列表的一行：封面、歌名、艺人共用一个点击区域。
class _UpNextRow extends StatelessWidget {
  const _UpNextRow({
    required this.item,
    required this.onTap,
    required this.enabled,
    required this.preparing,
  });

  final PersonalFmUpcomingItem item;
  final VoidCallback onTap;
  final bool enabled;

  /// 这一首正在解析加载：显示指示并禁用重复点击。
  final bool preparing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final song = item.song;
    final badge = switch (item) {
      PersonalFmUpcomingItem(isManual: true) => '插播',
      PersonalFmUpcomingItem(isFromHistory: true) => '回听',
      _ => null,
    };
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          children: [
            Artwork(url: song.coverUrl, size: 44, borderRadius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (preparing) ...[
              const SizedBox(width: 8),
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ] else if (badge != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
