import 'package:flutter/material.dart';

import '../../controllers/download_controller.dart';
import '../adaptive_layout.dart';
import '../widgets/artwork.dart';

/// 缓存歌曲列表。
///
/// 从「缓存管理」里独立出来：缓存管理是**设置类**页面（看用量、调上限、清理），
/// 而这里是**内容类**页面（一长串歌名，逐条保存或删除）。两者混在一页时，
/// 分类卡片和成百上千行歌曲共享同一条滚动轴，越往下滑越不知道自己在哪一层。
class CachedSongsPage extends StatefulWidget {
  const CachedSongsPage({super.key, required this.downloads});

  final DownloadController downloads;

  @override
  State<CachedSongsPage> createState() => _CachedSongsPageState();
}

class _CachedSongsPageState extends State<CachedSongsPage> {
  final Set<String> _busyKeys = <String>{};

  void _feedback(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(String cacheKey, Future<void> Function() action) async {
    if (_busyKeys.contains(cacheKey)) return;
    setState(() => _busyKeys.add(cacheKey));
    try {
      await action();
    } catch (error) {
      _feedback('操作失败：$error');
    } finally {
      if (mounted) setState(() => _busyKeys.remove(cacheKey));
    }
  }

  Future<void> _saveDownload(PlayCacheEntry entry) async {
    await _run(entry.cacheKey, () async {
      final downloads = widget.downloads;
      await downloads.download(entry.song, entry.quality);
      final result = downloads.entryFor(entry.song);
      if (result?.status != DownloadStatus.downloaded) {
        throw StateError(result?.error ?? '未能保存下载，请重试');
      }
      _feedback('已保存到下载');
    });
  }

  Future<void> _delete(PlayCacheEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清理'),
        content: Text('删除“${entry.song.title}”的缓存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(entry.cacheKey, () async {
      await widget.downloads.deletePlayCache(entry.song, entry.quality);
      _feedback('已删除');
    });
  }

  String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.downloads,
      builder: (context, _) {
        final entries = widget.downloads.playCacheEntries.toList()
          ..sort((a, b) => b.lastAccessedAt.compareTo(a.lastAccessedAt));
        return Scaffold(
          appBar: AppBar(title: const Text('缓存歌曲')),
          body: SafeArea(
            top: false,
            child: AdaptiveContentPadding(
              child: entries.isEmpty
                  ? _empty(context)
                  : ListView.builder(
                      key: const PageStorageKey('cached-songs-scroll'),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                      itemCount: entries.length + 1,
                      itemBuilder: (context, index) {
                        if (index == entries.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              '${entries.length} 首 · 共 ${_size(entries.fold<int>(0, (sum, entry) => sum + entry.size))}',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          );
                        }
                        return _row(
                          context,
                          entries[index],
                          first: index == 0,
                          last: index == entries.length - 1,
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_outlined, size: 48, color: colors.outline),
            const SizedBox(height: 16),
            Text('暂无缓存歌曲', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '播放过的歌曲会自动缓存到这里。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    PlayCacheEntry entry, {
    required bool first,
    required bool last,
  }) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final downloads = widget.downloads;
    final status = downloads.entryFor(entry.song)?.status;
    final isProtected = downloads.isPlayCacheProtected(entry);
    final busy = _busyKeys.contains(entry.cacheKey);
    final saved = status == DownloadStatus.downloaded;
    final downloading = status == DownloadStatus.downloading;
    final saveLabel = saved
        ? '已下载'
        : downloading
        ? '下载中'
        : status == DownloadStatus.failed
        ? '重试下载'
        : '保存到下载';
    const radius = Radius.circular(20);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.only(
          topLeft: first ? radius : Radius.zero,
          topRight: first ? radius : Radius.zero,
          bottomLeft: last ? radius : Radius.zero,
          bottomRight: last ? radius : Radius.zero,
        ),
      ),
      child: Column(
        children: [
          if (!first)
            Padding(
              padding: const EdgeInsets.only(left: 72),
              child: Divider(
                height: 1,
                thickness: 1,
                color: colors.outlineVariant.withValues(alpha: .7),
              ),
            ),
          Padding(
            key: ValueKey(entry.cacheKey),
            padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
            child: Row(
              children: [
                Artwork(url: entry.song.coverUrl, size: 44, borderRadius: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry.song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleSmall,
                            ),
                          ),
                          if (isProtected) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.graphic_eq_rounded,
                              size: 14,
                              color: colors.primary,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${entry.song.artist} · ${entry.quality.label} · ${_size(entry.size)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<_EntryAction>(
                  key: const ValueKey('cache-entry-menu'),
                  enabled: !busy,
                  tooltip: '更多操作',
                  onSelected: (action) {
                    switch (action) {
                      case _EntryAction.saveDownload:
                        _saveDownload(entry);
                      case _EntryAction.delete:
                        _delete(entry);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      key: const ValueKey('save-download-entry'),
                      value: _EntryAction.saveDownload,
                      enabled: !saved && !downloading,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          saved
                              ? Icons.download_done_rounded
                              : Icons.download_rounded,
                        ),
                        title: Text(saveLabel),
                      ),
                    ),
                    PopupMenuItem(
                      key: const ValueKey('delete-cache-entry'),
                      value: _EntryAction.delete,
                      enabled: !isProtected,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.delete_outline_rounded,
                          color: isProtected ? null : colors.error,
                        ),
                        title: const Text('删除'),
                        subtitle: isProtected
                            ? const Text('正在播放，无法清理')
                            : null,
                      ),
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
}

enum _EntryAction { saveDownload, delete }
