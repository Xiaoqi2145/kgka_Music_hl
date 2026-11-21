import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../../services/cloud_listening_service.dart';
import '../../services/playback_stats_service.dart';
import '../widgets/toast.dart';
import '../adaptive_layout.dart';

/// 播放统计页面：展示累计播放次数、听歌时长、最常听歌手/歌曲 Top 10。
class PlaybackStatsPage extends StatefulWidget {
  const PlaybackStatsPage({
    super.key,
    required this.player,
    this.cloudListening,
  });

  final PlayerController player;
  final CloudListeningService? cloudListening;

  @override
  State<PlaybackStatsPage> createState() => _PlaybackStatsPageState();
}

class _PlaybackStatsPageState extends State<PlaybackStatsPage> {
  Future<PlaybackStats>? _future;
  CloudListeningSummary? _cloud;
  bool _cloudLoading = false;
  bool _cloudError = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadCloud();
  }

  void _reload() {
    setState(() {
      _future = widget.player.getPlaybackStats();
    });
  }

  Future<void> _loadCloud({bool refresh = false}) async {
    final service = widget.cloudListening;
    if (service == null || _cloudLoading) return;
    setState(() {
      _cloudLoading = true;
      _cloudError = false;
    });
    try {
      final summary = await service.load(force: refresh);
      if (!mounted) return;
      setState(() => _cloud = summary);
    } catch (_) {
      if (!mounted) return;
      setState(() => _cloudError = true);
    } finally {
      if (mounted) setState(() => _cloudLoading = false);
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('清空播放统计'),
          content: const Text('确定要清空全部播放统计吗？此操作不可恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清空'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    widget.player.clearPlaybackStatsLocally();
    await widget.player.clearPlaybackStats();
    Toast.success('已清空播放统计');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放统计'),
        actions: [
          FutureBuilder<PlaybackStats>(
            future: _future,
            builder: (context, snapshot) {
              final hasData = snapshot.hasData;
              final stats = snapshot.data;
              final hasStats =
                  hasData &&
                  stats != null &&
                  (stats.totalPlays > 0 ||
                      stats.totalListenTime > Duration.zero);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '刷新云端统计',
                    onPressed: _cloudLoading || widget.cloudListening == null
                        ? null
                        : () => _loadCloud(refresh: true),
                    icon: _cloudLoading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: '清空本机统计',
                    onPressed: hasStats ? _confirmClear : null,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: AdaptiveContentPadding(
        child: FutureBuilder<PlaybackStats>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _ErrorView(message: '${snapshot.error}');
            }
            final stats = snapshot.data ?? const PlaybackStats();
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (_cloud != null)
                  _CloudSection(
                    summary: _cloud!,
                    error: _cloudError,
                    onRefresh: () => _loadCloud(refresh: true),
                  ),
                if (_cloud != null) const SizedBox(height: 24),
                if (stats.totalPlays == 0 &&
                    stats.totalListenTime == Duration.zero)
                  const SizedBox(height: 280, child: _EmptyView())
                else
                  _StatsContent(stats: stats, embedded: true),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatsContent extends StatelessWidget {
  const _StatsContent({required this.stats, this.embedded = false});

  final PlaybackStats stats;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _SectionHeader(title: '总览'),
      const SizedBox(height: 8),
      _StatsCard(
        children: [
          _StatRow(
            icon: Icons.play_circle_outline_rounded,
            iconColor: Theme.of(context).colorScheme.primary,
            title: '累计播放',
            value: '${stats.totalPlays} 次',
          ),
          const _StatsDivider(),
          _StatRow(
            icon: Icons.timer_outlined,
            iconColor: Theme.of(context).colorScheme.primary,
            title: '累计听歌时长',
            value: stats.formattedListenTime,
          ),
          const _StatsDivider(),
          _StatRow(
            icon: Icons.calendar_today_outlined,
            iconColor: Theme.of(context).colorScheme.primary,
            title: '首次播放',
            value: stats.firstPlayDate == null
                ? '—'
                : _formatDate(stats.firstPlayDate!),
          ),
        ],
      ),
      if (stats.topArtists.isNotEmpty) ...[
        const SizedBox(height: 24),
        _SectionHeader(title: '最常听歌手 Top 10'),
        const SizedBox(height: 8),
        _StatsCard(
          children: [
            for (var i = 0; i < stats.topArtists.length; i++) ...[
              if (i > 0) const _StatsDivider(),
              _RankRow(
                rank: i + 1,
                title: stats.topArtists[i].key,
                count: stats.topArtists[i].value,
              ),
            ],
          ],
        ),
      ],
      if (stats.topSongs.isNotEmpty) ...[
        const SizedBox(height: 24),
        _SectionHeader(title: '最常听歌曲 Top 10'),
        const SizedBox(height: 8),
        _StatsCard(
          children: [
            for (var i = 0; i < stats.topSongs.length; i++) ...[
              if (i > 0) const _StatsDivider(),
              _RankRow(
                rank: i + 1,
                title: stats.topSongs[i].key,
                count: stats.topSongs[i].value,
              ),
            ],
          ],
        ),
      ],
    ];
    return embedded ? Column(children: children) : ListView(children: children);
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _CloudSection extends StatelessWidget {
  const _CloudSection({
    required this.summary,
    required this.error,
    required this.onRefresh,
  });

  final CloudListeningSummary summary;
  final bool error;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final rank = summary.rank.take(10).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionHeader(title: '酷狗账号')),
            if (summary.refreshedAt != null)
              Flexible(
                child: Text(
                  '更新于 ${_formatClock(summary.refreshedAt!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            IconButton(
              tooltip: '刷新',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _CloudSummaryCard(summary: summary),
        if (rank.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionHeader(title: '酷狗听歌排行'),
          const SizedBox(height: 8),
          _StatsCard(
            children: [
              for (var i = 0; i < rank.length; i++) ...[
                if (i > 0) const _StatsDivider(),
                _CloudRankRow(rank: i + 1, item: rank[i]),
              ],
            ],
          ),
        ] else if (summary.rankError != null) ...[
          const SizedBox(height: 8),
          Text(
            summary.rankError!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (error) ...[
          const SizedBox(height: 8),
          Text(
            '刷新失败，正在显示上次成功结果',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
          ),
        ],
      ],
    );
  }

  String _formatClock(DateTime value) {
    final local = value.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

@visibleForTesting
class CloudStatsPreviewSummary {
  const CloudStatsPreviewSummary({
    required this.level,
    required this.levelName,
    required this.totalSeconds,
    required this.nextLevelSeconds,
  });

  final int level;
  final String levelName;
  final int totalSeconds;
  final int nextLevelSeconds;
}

@visibleForTesting
class CloudStatsPreview extends StatelessWidget {
  const CloudStatsPreview({super.key, required this.summary});

  final CloudStatsPreviewSummary summary;

  @override
  Widget build(BuildContext context) {
    return _CloudSection(
      summary: CloudListeningSummary(
        level: summary.level,
        levelName: summary.levelName,
        totalSeconds: summary.totalSeconds,
        nextLevelSeconds: summary.nextLevelSeconds,
      ),
      error: false,
      onRefresh: () {},
    );
  }
}

class _CloudSummaryCard extends StatelessWidget {
  const _CloudSummaryCard({required this.summary});

  final CloudListeningSummary summary;

  @override
  Widget build(BuildContext context) {
    final level = summary.level;
    final levelName = summary.levelName;
    final levelText = level == null
        ? '—'
        : levelName == null
        ? 'Lv.$level'
        : 'Lv.$level · $levelName';
    final total = summary.totalTime;
    return _StatsCard(
      children: [
        _CloudValueRow(
          icon: Icons.military_tech_outlined,
          title: '账号等级',
          value: levelText,
          detail: total == null ? summary.gradeError : null,
        ),
        const _StatsDivider(),
        _CloudValueRow(
          icon: Icons.schedule_rounded,
          title: '账号累计时长',
          value: total == null
              ? (summary.gradeError ?? '不可用')
              : formatCloudListenTime(total),
        ),
        if (summary.nextLevelTime != null) ...[
          const _StatsDivider(),
          _CloudValueRow(
            icon: Icons.flag_outlined,
            title: '距下一等级',
            value: formatCloudListenTime(summary.nextLevelTime!),
          ),
        ],
      ],
    );
  }
}

class _CloudValueRow extends StatelessWidget {
  const _CloudValueRow({
    required this.icon,
    required this.title,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Icon(icon, size: 22, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String formatCloudListenTime(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '$hours小时$minutes分钟';
  if (minutes > 0) return '$minutes分钟$seconds秒';
  return '$seconds秒';
}

class _CloudRankRow extends StatelessWidget {
  const _CloudRankRow({required this.rank, required this.item});

  final int rank;
  final CloudListenRank item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: rank <= 3 ? scheme.primary : scheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (item.artist != null)
                  Text(
                    item.artist!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (item.count != null)
            Text(
              '${item.count} 次',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(children: children),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          SizedBox(width: 32, child: Icon(icon, size: 22, color: iconColor)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: iconColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.rank,
    required this.title,
    required this.count,
  });

  final int rank;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isTop3 = rank <= 3;
    final rankColor = isTop3 ? colorScheme.primary : colorScheme.outline;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: rankColor,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '$count 次',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsDivider extends StatelessWidget {
  const _StatsDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 62,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bar_chart_rounded,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: .5),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无播放统计',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              '播放歌曲后会在这里看到统计数据',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, size: 48),
            const SizedBox(height: 12),
            const Text('加载失败', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
