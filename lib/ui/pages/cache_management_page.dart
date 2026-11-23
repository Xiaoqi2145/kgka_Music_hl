import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/download_controller.dart';
import '../../services/artwork_cache_service.dart';
import '../../services/cache_service.dart';
import '../adaptive_layout.dart';
import 'cached_songs_page.dart';

/// 缓存管理。
///
/// 这一页只负责**设置类**的事情：三类缓存各占多大、上限多少、要不要清。
/// 歌曲清单本身是内容，放在 [CachedSongsPage]，由下方同级的「缓存歌曲」卡进入——
/// 否则一长串歌名会把三张设置卡推得远远的，越往下滑越分不清自己在哪一层。
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

  void _openCachedSongs() {
    final downloads = widget.downloads;
    if (downloads == null) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => CachedSongsPage(downloads: downloads)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final downloads = widget.downloads;
    final entries = downloads?.playCacheEntries.toList() ?? <PlayCacheEntry>[];
    final cachedBytes = entries.fold<int>(0, (sum, entry) => sum + entry.size);

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
          child: ListView(
            key: const PageStorageKey('cache-management-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
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
                          action: () => downloads.setPlayCacheMaxBytes(bytes),
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
                    action: () =>
                        ArtworkCacheService.instance.setMaxCacheBytes(bytes),
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
              const SizedBox(height: 12),
              _songsEntry(
                count: entries.length,
                bytes: cachedBytes,
                onOpen: downloads == null ? null : _openCachedSongs,
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
    final textTheme = Theme.of(context).textTheme;
    // 「清理」从独立一行挪回标题行：原来它孤零零挂在卡片右下角，既没有说明
    // 清理的是哪一类，又凭空吃掉一截高度；现在「图标 + 标题 + 用量 + 清理」
    // 构成一条完整信息带，正文说明在下方独立成段。
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: colors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      size,
                      style: textTheme.titleMedium?.copyWith(
                        color: colors.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: ValueKey('clear-$title'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _busy ? null : onClear,
                child: const Text('清理'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (limit != null) ...[const Divider(height: 28), limit],
        ],
      ),
    );
  }

  /// 「缓存歌曲」入口卡：与三张缓存卡同级，点进去才是列表页。
  Widget _songsEntry({
    required int count,
    required int bytes,
    required VoidCallback? onOpen,
  }) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final enabled = onOpen != null;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('open-cached-songs'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.queue_music_rounded,
                      color: colors.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('缓存歌曲', style: textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(
                          count == 0 ? '暂无' : '$count 首 · ${_size(bytes)}',
                          style: textTheme.titleMedium?.copyWith(
                            color: enabled ? colors.primary : colors.outline,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: enabled ? colors.onSurfaceVariant : colors.outline,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '播放过的歌曲会自动缓存到这里，可逐首保存到下载或删除。',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
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
