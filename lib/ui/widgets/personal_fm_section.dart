import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../models/personal_fm_models.dart';
import '../../services/personal_fm_session.dart';
import 'artwork.dart';
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
    final wide =
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        MediaQuery.sizeOf(context).width >= 900;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      child: wide
          ? _wideLayout(context, current, upcoming)
          : _compactLayout(context, current, upcoming),
    );
  }

  Widget _compactLayout(
    BuildContext context,
    PersonalFmTrack? current,
    List<PersonalFmUpcomingItem> upcoming,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hero(context, compact: true),
        if (current == null) ...[
          // 未开播时布局与播放中一致：上面是与「当前播放」等位的入口卡片，
          // 下面是「接下来」。顺序颠倒会让自动取到候选后的页面和播放中的
          // 页面看起来像两个不同的页面。
          _startCard(context),
          const SizedBox(height: 20),
          _upNext(context, upcoming),
        ] else ...[
          _nowPlaying(context, current),
          const SizedBox(height: 20),
          _upNext(context, upcoming),
        ],
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
        if (current == null) ...[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: _startCard(context)),
              // 没有候选时不画空壳：右栏留白比一张空卡片更像「还没内容」。
              if (upcoming.isNotEmpty) ...[
                const SizedBox(width: 18),
                Expanded(flex: 4, child: _wideRail(context, upcoming)),
              ],
            ],
          ),
          const SizedBox(height: 18),
          _upNext(context, upcoming),
        ] else ...[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: _wideCurrent(context, current)),
              if (upcoming.isNotEmpty) ...[
                const SizedBox(width: 18),
                Expanded(flex: 4, child: _wideRail(context, upcoming)),
              ],
            ],
          ),
          const SizedBox(height: 18),
          _upNext(context, upcoming),
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

  Widget _wideCurrent(BuildContext context, PersonalFmTrack track) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final song = track.song;
    final player = widget.player;
    final liked = widget.auth.isLiked(song);
    final canAct = !player.isPreparing;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Artwork(url: song.coverUrl, size: 176, borderRadius: 18),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _GhostAction(
                      tooltip: player.personalFmCurrentDisliked
                          ? '已标记不喜欢'
                          : '不喜欢',
                      icon: Icons.thumb_down_alt_outlined,
                      onPressed: canAct && !player.personalFmCurrentDisliked
                          ? player.dislikePersonalFmCurrent
                          : null,
                    ),
                    IconButton.filled(
                      tooltip: player.isPlaying ? '暂停' : '播放',
                      onPressed: canAct ? player.togglePlay : null,
                      icon: Icon(
                        player.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(52),
                        shape: const CircleBorder(),
                      ),
                    ),
                    _GhostAction(
                      tooltip: '下一首',
                      icon: Icons.skip_next_rounded,
                      onPressed: canAct ? player.next : null,
                    ),
                    _GhostAction(
                      tooltip: liked ? '取消喜欢' : '喜欢',
                      icon: liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: liked ? scheme.primary : scheme.onSurface,
                      onPressed: _liking || song.source != SongSource.kugou
                          ? null
                          : () => _toggleLike(song),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideRail(BuildContext context, List<PersonalFmUpcomingItem> entries) {
    final items = entries.take(4).toList();
    // 副栏只放横向封面：标题与数量由紧随其后的「接下来」列表承担，
    // 两块重复同一个标题只会让页面看起来像渲染了两次。
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 156,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, index) => const SizedBox(width: 14),
              itemBuilder: (context, index) =>
                  _circleRecommendation(context, items[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleRecommendation(
    BuildContext context,
    PersonalFmUpcomingItem item,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final song = item.song;
    final player = widget.player;
    final preparing = player.isPreparingSong(song);
    final enabled = !player.isPreparing;
    return SizedBox(
      width: 116,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? () => _select(item) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Artwork(url: song.coverUrl, size: 96, borderRadius: 48),
                  if (preparing)
                    const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              // 只有真正需要区分的来源才加标签；普通推荐不加，
              // 满屏「推荐」是没有信息量的噪音。
              if (item.isManual || item.isFromHistory)
                Text(
                  item.isManual ? '插播' : '回听',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
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

  /// 未开播：一张与首页其它区块同材质的入口卡片。
  Widget _startCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 只留一个主操作：入口卡片不再重复标题文案，说明信息由
    // 上方标题区与下方候选列表承担。
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_startError case final error?) ...[
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _starting ? null : _start,
              icon: _starting
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('开始播放'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 正在播放：封面 + 曲目信息 + 四个操作，材质与首页其它卡片一致。
  Widget _nowPlaying(BuildContext context, PersonalFmTrack track) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = widget.player;
    final song = track.song;
    final liked = widget.auth.isLiked(song);
    final canAct = !player.isPreparing;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Artwork(url: song.coverUrl, size: 84, borderRadius: 12),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _GhostAction(
                tooltip: player.personalFmCurrentDisliked ? '已标记不喜欢' : '不喜欢',
                icon: Icons.thumb_down_alt_outlined,
                onPressed: canAct && !player.personalFmCurrentDisliked
                    ? player.dislikePersonalFmCurrent
                    : null,
              ),
              IconButton.filled(
                tooltip: player.isPlaying ? '暂停' : '播放',
                onPressed: canAct ? player.togglePlay : null,
                iconSize: 30,
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(58),
                  shape: const CircleBorder(),
                ),
                icon: Icon(
                  player.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              _GhostAction(
                tooltip: '下一首',
                icon: Icons.skip_next_rounded,
                onPressed: canAct ? player.next : null,
              ),
              _GhostAction(
                tooltip: liked ? '取消喜欢' : '喜欢',
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: liked ? scheme.primary : scheme.onSurface,
                onPressed: _liking || song.source != SongSource.kugou
                    ? null
                    : () => _toggleLike(song),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 接下来：与「今日推荐」同样的行样式，标题用区块头字重。
  ///
  /// 列表区分三种来源：手动插播、回听暂存、候选池。数量说明放在标题右侧，
  /// 让「还有几首」在不滚动的情况下可知。每一行都能直接点播。
  Widget _upNext(BuildContext context, List<PersonalFmUpcomingItem> entries) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '接下来',
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
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
            const Spacer(),
            if (loading && entries.isNotEmpty)
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (entries.isNotEmpty) ...[
          for (final entry in entries)
            _UpNextRow(
              item: entry,
              enabled: !player.isPreparing,
              preparing: player.isPreparingSong(entry.song),
              onTap: () => _select(entry),
            ),
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
                Text(
                  '正在获取推荐…',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
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

/// 圆形幽灵按钮：播放卡片里的次要操作，与主按钮拉开层级。
class _GhostAction extends StatelessWidget {
  const _GhostAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 24,
      icon: Icon(icon, color: color),
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
