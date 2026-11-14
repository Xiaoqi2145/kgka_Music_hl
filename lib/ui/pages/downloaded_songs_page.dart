import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../adaptive_layout.dart';
import '../widgets/artwork.dart';
import 'cache_management_page.dart';

/// 已下载歌曲与下载任务。
class DownloadedSongsPage extends StatefulWidget {
  const DownloadedSongsPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.downloads,
    this.cache,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final DownloadController downloads;
  final CacheService? cache;

  @override
  State<DownloadedSongsPage> createState() => _DownloadedSongsPageState();
}

class _DownloadedSongsPageState extends State<DownloadedSongsPage> {
  final _search = TextEditingController();
  final _busy = <String>{};
  bool _clearing = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _operate(String key, Future<void> Function() action) async {
    if (_busy.contains(key) || _clearing) return;
    setState(() => _busy.add(key));
    try {
      await action();
    } catch (_) {
      _message('操作失败，请重试');
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _delete(DownloadEntry entry) async {
    final confirmed = await _confirm(
      '删除下载',
      '将删除「${entry.song.title}」的本地文件。',
    );
    if (!confirmed || !mounted) return;
    await _operate(entry.song.hash, () async {
      await widget.downloads.deleteDownload(entry.song);
      _message('已删除');
    });
  }

  Future<void> _clear() async {
    if (_clearing || _busy.isNotEmpty) return;
    final confirmed = await _confirm('删除全部下载', '已下载的文件会从设备中删除。');
    if (!confirmed || !mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.downloads.clearAllDownloads();
      _message('已删除全部下载');
    } catch (_) {
      _message('删除失败，请重试');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  void _openCache() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (cacheContext) => CacheManagementPage(
          cache: widget.cache ?? widget.player.cacheService,
          downloads: widget.downloads,
          onOpenDownloads: () => Navigator.of(cacheContext).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([widget.downloads, widget.player]),
      builder: (context, _) {
        final all = widget.downloads.downloadEntries;
        final saved =
            all.where((e) => e.status == DownloadStatus.downloaded).toList()
              ..sort(
                (a, b) => (b.downloadedAt ?? DateTime(0)).compareTo(
                  a.downloadedAt ?? DateTime(0),
                ),
              );
        final tasks = all
            .where((e) => e.status != DownloadStatus.downloaded)
            .toList();
        final query = _search.text.trim().toLowerCase();
        final entries =
            (tasks.isEmpty ? saved : [...tasks, ...saved]).where((e) {
              return query.isEmpty ||
                  '${e.song.title} ${e.song.artist}'.toLowerCase().contains(
                    query,
                  );
            }).toList();

        return Scaffold(
          appBar: AppBar(
            title: const Text('下载'),
            actions: [
              IconButton(
                tooltip: '缓存管理',
                icon: const Icon(Icons.cached_rounded),
                onPressed: _openCache,
              ),
              if (saved.isNotEmpty)
                IconButton(
                  tooltip: '删除全部下载',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _clearing || _busy.isNotEmpty ? null : _clear,
                ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(2),
              child: SizedBox(
                height: 2,
                child: _clearing
                    ? const LinearProgressIndicator(semanticsLabel: '正在删除下载')
                    : null,
              ),
            ),
          ),
          body: SafeArea(
            top: false,
            child: AdaptiveContentPadding(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: '搜索歌曲或歌手',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close_rounded),
                              ),
                        filled: true,
                        fillColor: colors.surfaceContainerLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: entries.isEmpty
                        ? _empty(context, query.isNotEmpty)
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                            itemCount: entries.length,
                            itemBuilder: (context, index) =>
                                _row(entries[index]),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _empty(BuildContext context, bool searching) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching
                  ? Icons.search_off_rounded
                  : Icons.download_for_offline_outlined,
              size: 48,
              color: colors.outline,
            ),
            const SizedBox(height: 16),
            Text(
              searching ? '没有找到匹配的歌曲' : '还没有下载的歌曲',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              searching ? '试试其他歌名或歌手' : '在歌曲菜单中选择下载。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(DownloadEntry entry) {
    final colors = Theme.of(context).colorScheme;
    final song = entry.song;
    final completed = entry.status == DownloadStatus.downloaded;
    final running = entry.status == DownloadStatus.downloading;
    final busy = _busy.contains(song.hash) || _clearing;
    final current = widget.player.currentSong?.hash == song.hash;
    final progress = entry.progress.clamp(0.0, 1.0);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      leading: Artwork(url: song.coverUrl, size: 48, borderRadius: 12),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: completed && current ? colors.primary : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${song.artist} · ${entry.quality.badge}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (!completed) ...[
            const SizedBox(height: 4),
            if (running) ...[
              LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                minHeight: 3,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              running
                  ? progress > 0
                        ? '下载中 ${(progress * 100).round()}%'
                        : '准备下载…'
                  : entry.error ?? '下载失败',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: running ? colors.primary : colors.error,
              ),
            ),
          ],
        ],
      ),
      trailing: completed
          ? IconButton(
              tooltip: '删除下载',
              onPressed: busy ? null : () => _delete(entry),
              icon: const Icon(Icons.delete_outline_rounded),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!running)
                  IconButton(
                    tooltip: '重试下载',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: busy
                        ? null
                        : () => _operate(song.hash, () async {
                            await widget.downloads.download(
                              song,
                              entry.quality,
                            );
                            if (widget.downloads.entryFor(song)?.status ==
                                DownloadStatus.failed) {
                              _message('下载失败，请稍后重试');
                            }
                          }),
                  ),
                IconButton(
                  tooltip: running ? '取消下载' : '移除任务',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _clearing
                      ? null
                      : () async {
                          if (running) {
                            try {
                              await widget.downloads.cancelDownload(song);
                            } catch (_) {
                              _message('取消失败，请重试');
                            }
                          } else if (!busy) {
                            await _operate(
                              song.hash,
                              () => widget.downloads.deleteDownload(song),
                            );
                          }
                        },
                ),
              ],
            ),
      onTap: completed
          ? () => _operate(
              song.hash,
              () => widget.player.playDownloadedSong(song),
            )
          : null,
    );
  }
}
