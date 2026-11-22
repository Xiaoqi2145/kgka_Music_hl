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

  Future<void> _start() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final account = widget.auth.session?.userId ?? 'anonymous';
      final outcome = await widget.player.startPersonalFm(
        ownerKey: '${AppConfig.effectiveBaseUrl}|$account',
      );
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
        if (current == null)
          _startCard(context)
        else ...[
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
        if (current == null)
          _startCard(context)
        else ...[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: _wideCurrent(context, current)),
              const SizedBox(width: 18),
              Expanded(flex: 4, child: _wideRail(context, upcoming)),
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
                Text(
                  '按你的口味持续推荐，边播边补',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!compact) _modeStrip(context),
        ],
      ),
    );
  }

  Widget _modeStrip(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _modeButton(context, '红心', selected: true),
        _modeButton(context, '小众'),
        _modeButton(context, '速览'),
        _modeButton(context, '电台'),
      ],
    );
  }

  Widget _modeButton(
    BuildContext context,
    String label, {
    bool selected = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: textTheme.labelMedium?.copyWith(
          color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        ),
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
                  '当前播放',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
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
                if (track.recommendDesc case final reason?) ...[
                  const SizedBox(height: 12),
                  Text(
                    reason,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = entries.take(4).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '即将播放',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          if (items.isEmpty)
            Text(
              '正在准备推荐',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else
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
    return SizedBox(
      width: 116,
      child: Column(
        children: [
          Artwork(url: song.coverUrl, size: 96, borderRadius: 48),
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
          Text(
            item.isManual
                ? '插播'
                : item.isFromHistory
                ? '回听'
                : '推荐',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Color _cardColor(BuildContext context) {
    final theme = widget.theme;
    final frosted = theme != null && personalFmFrostedActive(theme);
    return personalFmCardColor(Theme.of(context).colorScheme, frosted: frosted);
  }

  /// 未开播：一张与首页其它区块同材质的入口卡片。
  Widget _startCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.favorite_rounded, size: 30, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            '按你的口味推荐歌曲',
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '根据你在酷狗的收听口味持续推荐，边播边补。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (_startError case final error?) ...[
            const SizedBox(height: 10),
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _starting ? null : _start,
            icon: _starting
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_starting ? '正在获取推荐' : '开始播放'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
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
                    if (track.recommendDesc case final reason?) ...[
                      const SizedBox(height: 3),
                      Text(
                        reason,
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
  /// 让「还有几首」在不滚动的情况下可知。
  Widget _upNext(BuildContext context, List<PersonalFmUpcomingItem> entries) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = _session;
    final loading = session?.isLoadingRecommendations == true;
    final exhausted = session?.isExhausted == true;
    final total = session?.pendingCount ?? 0;
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
            if (loading)
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (entries.isNotEmpty)
          for (final entry in entries) _UpNextRow(item: entry),
        if (entries.isEmpty && !loading) ...[
          Text(
            exhausted ? '候选已用完' : '暂时没有接下来的推荐',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: widget.player.retryPersonalFm,
              child: const Text('重新获取'),
            ),
          ),
        ],
        if (widget.player.errorMessage case final error?)
          Text(
            error,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
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

/// 「接下来」列表的一行。只展示，不提供点播入口：推荐顺序由会话决定，
/// 直接点播会让候选消耗与实际播放脱节。
class _UpNextRow extends StatelessWidget {
  const _UpNextRow({required this.item});

  final PersonalFmUpcomingItem item;

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
    return Padding(
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
          if (badge != null) ...[
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
    );
  }
}
