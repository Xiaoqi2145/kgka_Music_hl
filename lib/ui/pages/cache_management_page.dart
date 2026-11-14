import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/download_controller.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/cache_service.dart';
import '../adaptive_layout.dart';
import '../widgets/artwork.dart';

/// 缓存管理。
class CacheManagementPage extends StatefulWidget {
  const CacheManagementPage({
    super.key,
    this.cache,
    this.downloads,
    this.onOpenDownloads,
  });

  final CacheService? cache;
  final DownloadController? downloads;
  final VoidCallback? onOpenDownloads;

  @override
  State<CacheManagementPage> createState() => _CacheManagementPageState();
}

class _CacheManagementPageState extends State<CacheManagementPage> {
  int? _playBytes;
  int? _artworkBytes;
  int? _dataBytes;
  bool _busy = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    widget.downloads?.addListener(_onDownloadsChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant CacheManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.downloads != widget.downloads) {
      oldWidget.downloads?.removeListener(_onDownloadsChanged);
      widget.downloads?.addListener(_onDownloadsChanged);
    }
  }

  @override
  void dispose() {
    widget.downloads?.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  void _onDownloadsChanged() {
    if (!mounted) return;
    setState(() {
      _playBytes = widget.downloads?.playCacheEntries.fold<int>(
        0,
        (total, entry) => total + entry.size,
      );
    });
  }

  Future<void> _loadSizes() async {
    final errors = <String>[];
    Future<int?> read(String name, Future<int> Function()? action) async {
      if (action == null) return null;
      try {
        return await action();
      } catch (_) {
        errors.add(name);
        return null;
      }
    }

    final sizes = await Future.wait([
      read('播放缓存', widget.downloads?.getPlayCacheDirSize),
      read('封面缓存', ArtworkCacheService.instance.getCacheSize),
      read('数据缓存', widget.cache?.getCacheSize),
    ]);
    if (!mounted) return;
    setState(() {
      _playBytes = sizes[0];
      _artworkBytes = sizes[1];
      _dataBytes = sizes[2];
      _loadError = errors.isEmpty ? null : '${errors.join('、')}读取失败，请重试';
    });
  }

  Future<void> _refresh() async {
    await _loadSizes();
    if (mounted) setState(() => _busy = false);
  }

  void _feedback(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _perform({
    required String success,
    required Future<void> Function() action,
    String? confirmation,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (confirmation != null) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认清理'),
            content: Text(confirmation),
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
      }
      await action();
      await _loadSizes();
      _feedback(success);
    } catch (error) {
      _feedback('操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveDownload(PlayCacheEntry entry) => _perform(
    success: '已保存到下载',
    action: () async {
      final downloads = widget.downloads!;
      await downloads.download(entry.song, entry.quality);
      final result = downloads.entryFor(entry.song);
      if (result?.status != DownloadStatus.downloaded) {
        throw StateError(result?.error ?? '未能保存下载，请重试');
      }
    },
  );

  String _size(int? bytes) {
    if (bytes == null) return _busy ? '计算中…' : '暂不可用';
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
    final colors = Theme.of(context).colorScheme;
    final downloads = widget.downloads;
    final entries = downloads?.playCacheEntries.toList() ?? <PlayCacheEntry>[];
    entries.sort((a, b) => b.lastAccessedAt.compareTo(a.lastAccessedAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存管理'),
        actions: [
          if (widget.onOpenDownloads != null)
            IconButton(
              tooltip: '下载',
              onPressed: () => widget.onOpenDownloads!(),
              icon: const Icon(Icons.download_done_rounded),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _busy
                ? null
                : () => _perform(success: '已刷新', action: () async {}),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _busy
                ? const LinearProgressIndicator(semanticsLabel: '正在处理缓存')
                : null,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: AdaptiveContentPadding(
          child: CustomScrollView(
            key: const PageStorageKey('cache-management-scroll'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                sliver: SliverList.list(
                  children: [
                    if (_loadError != null) ...[
                      Text(_loadError!, style: TextStyle(color: colors.error)),
                      const SizedBox(height: 12),
                    ],
                    _category(
                      icon: Icons.music_note_rounded,
                      title: '播放缓存',
                      size: downloads == null ? '未启用' : _size(_playBytes),
                      description:
                          '听过的歌曲暂时保留，超出上限时优先移除较久未使用的条目。清理时保留当前播放的歌曲。',
                      onClear: downloads == null || (_playBytes ?? 0) == 0
                          ? null
                          : () => _perform(
                              success: '播放缓存已清理',
                              confirmation: '清理播放缓存？当前播放的歌曲会保留。',
                              action: downloads.clearPlayCache,
                            ),
                      limit: downloads == null
                          ? null
                          : _LimitEditor(
                              label: '播放缓存上限',
                              value: downloads.playCacheMaxBytes,
                              min: AppConfig.minPlayCacheMaxBytes,
                              max: AppConfig.maxPlayCacheMaxBytes,
                              enabled: !_busy,
                              onSave: (bytes) => _perform(
                                success: '上限已更新',
                                action: () =>
                                    downloads.setPlayCacheMaxBytes(bytes),
                              ),
                            ),
                    ),
                    const SizedBox(height: 12),
                    _category(
                      icon: Icons.image_outlined,
                      title: '封面缓存',
                      size: _size(_artworkBytes),
                      description: '浏览时保存的封面图片，清理后再次浏览会重新加载。',
                      onClear: (_artworkBytes ?? 0) == 0
                          ? null
                          : () => _perform(
                              success: '封面缓存已清理',
                              confirmation: '清理封面缓存？',
                              action: ArtworkCacheService.instance.clearCache,
                            ),
                      limit: _LimitEditor(
                        label: '封面缓存上限',
                        value: ArtworkCacheService.instance.maxCacheBytes,
                        min: AppConfig.minArtworkCacheMaxBytes,
                        max: AppConfig.maxArtworkCacheMaxBytes,
                        enabled: !_busy,
                        onSave: (bytes) => _perform(
                          success: '上限已更新',
                          action: () => ArtworkCacheService.instance
                              .setMaxCacheBytes(bytes),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _category(
                      icon: Icons.storage_rounded,
                      title: '数据缓存',
                      size: widget.cache == null ? '未启用' : _size(_dataBytes),
                      description:
                          '首页和歌单的浏览数据，清理后再次打开会重新获取。上限 ${_size(AppConfig.maxDataCacheBytes)}。',
                      onClear: widget.cache == null || (_dataBytes ?? 0) == 0
                          ? null
                          : () => _perform(
                              success: '数据缓存已清理',
                              confirmation: '清理数据缓存？',
                              action: widget.cache!.clearAllCache,
                            ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '缓存的歌曲 · ${entries.length}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (entries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('暂无缓存歌曲'),
                      ),
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _entry(entries[index]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _category({
    required IconData icon,
    required String title,
    required String size,
    required String description,
    VoidCallback? onClear,
    Widget? limit,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: colors.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(size, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(description, style: TextStyle(color: colors.onSurfaceVariant)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: ValueKey('clear-$title'),
              onPressed: _busy ? null : onClear,
              child: Text('清理'),
            ),
          ),
          if (limit != null) ...[const Divider(height: 24), limit],
        ],
      ),
    );
  }

  Widget _entry(PlayCacheEntry entry) {
    final downloads = widget.downloads!;
    final status = downloads.entryFor(entry.song)?.status;
    final protected = downloads.isPlayCacheProtected(entry);
    final saved = status == DownloadStatus.downloaded;
    final downloading = status == DownloadStatus.downloading;
    return Container(
      key: ValueKey(entry.cacheKey),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Artwork(url: entry.song.coverUrl, size: 48, borderRadius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.song.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${entry.song.artist} · ${entry.quality.label} · ${_size(entry.size)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (protected)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('正在播放，无法清理'),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                key: const ValueKey('save-download-entry'),
                onPressed: _busy || saved || downloading
                    ? null
                    : () => _saveDownload(entry),
                icon: Icon(
                  saved ? Icons.download_done_rounded : Icons.download_rounded,
                  size: 18,
                ),
                label: Text(
                  saved
                      ? '已下载'
                      : downloading
                      ? '下载中'
                      : status == DownloadStatus.failed
                      ? '重试下载'
                      : '保存到下载',
                ),
              ),
              TextButton.icon(
                key: const ValueKey('delete-cache-entry'),
                onPressed: _busy || protected
                    ? null
                    : () => _perform(
                        success: '已删除',
                        confirmation:
                            '删除“${entry.song.title}”的缓存？',
                        action: () => downloads.deletePlayCache(
                          entry.song,
                          entry.quality,
                        ),
                      ),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LimitEditor extends StatefulWidget {
  const _LimitEditor({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onSave,
  });
  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final Future<void> Function(int) onSave;

  @override
  State<_LimitEditor> createState() => _LimitEditorState();
}

class _LimitEditorState extends State<_LimitEditor> {
  static const _mb = 1024 * 1024;
  late final _controller = TextEditingController(
    text: '${(widget.value ~/ _mb)}',
  );
  String? _error;

  @override
  void didUpdateWidget(covariant _LimitEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.text = '${(widget.value ~/ _mb)}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (!widget.enabled) return;
    final mb = int.tryParse(_controller.text.trim());
    if (mb == null || mb * _mb < widget.min || mb * _mb > widget.max) {
      setState(
        () => _error = '请输入 ${widget.min ~/ _mb}–${widget.max ~/ _mb} MB',
      );
      return;
    }
    setState(() => _error = null);
    FocusScope.of(context).unfocus();
    widget.onSave(mb * _mb);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: ValueKey(widget.label),
              controller: _controller,
              enabled: widget.enabled,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                isDense: true,
                suffixText: 'MB',
                errorText: _error,
                errorMaxLines: 2,
                helperText: '${widget.min ~/ _mb}–${widget.max ~/ _mb} MB',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => _save(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: '保存${widget.label}',
            onPressed: widget.enabled ? _save : null,
            icon: const Icon(Icons.check_rounded),
          ),
        ],
      ),
    ],
  );
}
