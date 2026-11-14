import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../services/app_update_service.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/audio_effects_sheet.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/toast.dart';
import 'about_page.dart';
import 'cache_management_page.dart';
import 'downloaded_songs_page.dart';
import 'audio_interruption_settings_page.dart';
import 'desktop_lyrics_settings_page.dart';
import 'personalization_settings_page.dart';
import 'playback_history_page.dart';
import 'playback_stats_page.dart';
import '../adaptive_layout.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.theme,
    required this.localMusic,
    this.cache,
    this.downloads,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final ThemeController theme;
  final LocalMusicController localMusic;
  final CacheService? cache;
  final DownloadController? downloads;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: AnimatedBuilder(
          animation: Listenable.merge([auth, player, localMusic, theme]),
          builder: (context, _) {
            return AdaptiveContentPadding(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  // Account section
                  _SectionHeader(title: '账号'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.sync_rounded,
                        iconColor: colorScheme.primary,
                        title: '同步个人信息',
                        subtitle: '刷新头像、昵称和歌单数据',
                        loading: auth.isLoading,
                        onTap: auth.isLoading
                            ? null
                            : () => auth.refreshProfile(),
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.logout_rounded,
                        iconColor: colorScheme.error,
                        title: '退出登录',
                        titleColor: colorScheme.error,
                        onTap: auth.isLoading
                            ? null
                            : () => _confirmLogout(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Playback section
                  _SectionHeader(title: '播放'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.high_quality_rounded,
                        iconColor: colorScheme.primary,
                        title: '默认音质',
                        subtitle: player.audioQuality.label,
                        onTap: () => _selectDefaultAudioQuality(context),
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.auto_awesome_rounded,
                        iconColor: colorScheme.primary,
                        title: '智能音质',
                        subtitle: '播放失败时自动降级音质重试',
                        value: player.smartQualityEnabled,
                        onChanged: player.setSmartQualityEnabled,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.headphones_rounded,
                        iconColor: colorScheme.primary,
                        title: '设备连接自动播放',
                        subtitle: '连接蓝牙耳机等音频设备时自动继续播放',
                        value: player.autoPlayOnDeviceConnected,
                        onChanged: player.setAutoPlayOnDeviceConnected,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.restore_rounded,
                        iconColor: colorScheme.primary,
                        title: '接续播放',
                        subtitle: '重新打开应用时恢复上次的歌曲和播放列表',
                        value: player.resumePlaybackEnabled,
                        onChanged: player.setResumePlaybackEnabled,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.bolt_rounded,
                        iconColor: colorScheme.primary,
                        title: '预加载歌曲',
                        subtitle: '提前载入下一首歌曲的播放地址，减少切歌等待',
                        value: player.gaplessPlaybackEnabled,
                        onChanged: player.setGaplessPlaybackEnabled,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.swap_horiz_rounded,
                        iconColor: colorScheme.primary,
                        title: '无缝播放',
                        subtitle: player.gaplessPlaybackEnabled
                            ? '在原生播放器内衔接下一曲，消除切歌间隙（仅 Android）'
                            : '需先开启「预加载歌曲」',
                        value: player.realGaplessPlaybackEnabled,
                        // 门禁：没有预解析地址就没有可衔接的下一曲。
                        enabled: player.gaplessPlaybackEnabled,
                        onChanged: player.setRealGaplessPlaybackEnabled,
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.volume_up_rounded,
                        iconColor: colorScheme.primary,
                        title: '音量均衡',
                        subtitle: '自动统一不同歌曲的播放音量',
                        value: player.volumeNormalizationEnabled,
                        onChanged: player.setVolumeNormalizationEnabled,
                      ),
                      if (player.volumeNormalizationEnabled) ...[
                        _SettingsDivider(),
                        _VolumeNormLufsSlider(player: player),
                      ],
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.graphic_eq_rounded,
                        iconColor: colorScheme.primary,
                        title: '音效',
                        subtitle: player.audioEffectsLabel,
                        onTap: () => showAudioEffectsSheet(
                          context: context,
                          player: player,
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.bar_chart_rounded,
                        iconColor: colorScheme.primary,
                        title: '播放统计',
                        subtitle: '听歌时长、最常听歌手等',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlaybackStatsPage(player: player),
                          ),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.history_rounded,
                        iconColor: colorScheme.primary,
                        title: '播放历史',
                        subtitle: '最近播放的歌曲',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlaybackHistoryPage(
                              api: api,
                              auth: auth,
                              player: player,
                            ),
                          ),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsTile(
                        icon: Icons.block_rounded,
                        title: '后台打断机制',
                        subtitle: _audioInterruptionSummary(player),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                AudioInterruptionSettingsPage(player: player),
                          ),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.bar_chart_rounded,
                        iconColor: colorScheme.primary,
                        title: '增加听歌时长',
                        subtitle: '每播放 30 分钟自动同步一次',
                        value: player.addListeningTimeEnabled,
                        onChanged: player.setAddListeningTimeEnabled,
                      ),
                      if (player.isDesktopLyricsSupported) ...[
                        _SettingsDivider(),
                        _SettingsSwitchTile(
                          icon: Icons.lyrics_rounded,
                          iconColor: colorScheme.primary,
                          title: '桌面歌词',
                          subtitle: '在其他应用上方显示歌词悬浮窗',
                          value: player.desktopLyricsEnabled,
                          onChanged: (value) async {
                            await player.setDesktopLyricsEnabled(value);
                            if (!player.desktopLyricsEnabled && value) {
                              Toast.error('需要悬浮窗权限才能使用桌面歌词');
                            }
                          },
                        ),
                        if (player.desktopLyricsEnabled) ...[
                          _SettingsDivider(),
                          _SettingsTile(
                            icon: Icons.tune_rounded,
                            iconColor: colorScheme.primary,
                            title: '歌词设置',
                            subtitle: '透明度、颜色、锁定位置等',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    DesktopLyricsSettingsPage(player: player),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Local Music section
                  _SectionHeader(title: '本地'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.computer_rounded,
                        iconColor: colorScheme.primary,
                        title: '本地音乐目录',
                        subtitle: localMusic.localMusicDir ?? '未设置',
                        onTap: () => _selectOrClearDir(context, localMusic),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Network section
                  _SectionHeader(title: '网络'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.dns_rounded,
                        iconColor: colorScheme.primary,
                        title: 'API 服务器地址',
                        subtitle: AppConfig.hasCustomBaseUrl
                            ? AppConfig.customBaseUrl
                            : '默认：${AppConfig.defaultApiBaseUrl}',
                        onTap: () => _editApiBaseUrl(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Cache section
                  _SectionHeader(title: '缓存'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.storage_rounded,
                        iconColor: colorScheme.primary,
                        title: '缓存管理',
                        subtitle: '查看和清理缓存',
                        onTap: () => _showCacheManagement(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Personalization section
                  _SectionHeader(title: '个性化'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.palette_rounded,
                        iconColor: colorScheme.primary,
                        title: '皮肤与背景',
                        subtitle: '配色方案与自定义全局背景图',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PersonalizationSettingsPage(
                              themeController: theme,
                            ),
                          ),
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.screen_rotation_rounded,
                        iconColor: colorScheme.primary,
                        title: '横屏模式',
                        subtitle: '允许手机横屏时自动旋转（平板默认开启）',
                        value: theme.landscapeEnabled,
                        onChanged: (value) {
                          theme.setLandscapeEnabled(
                            value,
                            AdaptiveLayout.isTablet(context),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // App section
                  _SectionHeader(title: '应用'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsTile(
                        icon: Icons.info_outline_rounded,
                        iconColor: colorScheme.primary,
                        title: '关于',
                        subtitle: AppUpdateService.isSupportedPlatform
                            ? '版本、更新日志与检查更新'
                            : '版本与更新日志',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AboutPage(api: api),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _audioInterruptionSummary(PlayerController player) {
    final parts = <String>[];
    if (!player.audioInterruptionEnabled) parts.add('已阻止打断');
    if (player.autoResumeAfterInterruption) parts.add('自动恢复');
    return parts.isEmpty ? '未开启' : parts.join(' · ');
  }

  Future<void> _selectDefaultAudioQuality(BuildContext context) async {
    final quality = await showAudioQualitySheet(
      context: context,
      selected: player.audioQuality,
      title: '默认音质',
      subtitle: '新播放的歌曲会使用这个音质',
    );
    if (quality == null) return;
    await player.setAudioQuality(quality);
  }

  /// 打开独立缓存页，下载由用户在单独页面管理。
  Future<void> _showCacheManagement(BuildContext context) async {
    final downloads = this.downloads;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (cacheContext) => CacheManagementPage(
          cache: cache,
          downloads: downloads,
          onOpenDownloads: downloads == null
              ? null
              : () {
                  Navigator.of(cacheContext).push<void>(
                    MaterialPageRoute(
                      builder: (_) => DownloadedSongsPage(
                        api: api,
                        auth: auth,
                        player: player,
                        downloads: downloads,
                        cache: cache,
                      ),
                    ),
                  );
                },
        ),
      ),
    );
  }

  Future<void> _editApiBaseUrl(BuildContext context) async {
    final controller = TextEditingController(
      text: AppConfig.customBaseUrl ?? '',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('API 服务器地址'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '留空则使用默认地址',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '默认：${AppConfig.defaultApiBaseUrl}',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/api',
                  labelText: 'Base URL',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            if (AppConfig.hasCustomBaseUrl)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(''),
                child: Text(
                  '恢复默认',
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
              ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (result == null || !context.mounted) return;

    await AppConfig.saveCustomBaseUrl(result);
    if (!context.mounted) return;

    Toast.success(
      AppConfig.hasCustomBaseUrl
          ? '已切换到 ${AppConfig.customBaseUrl}，重启后生效'
          : '已恢复默认 API 地址，重启后生效',
    );
  }

  Future<void> _selectOrClearDir(
    BuildContext context,
    LocalMusicController localMusic,
  ) async {
    final dir = localMusic.localMusicDir;
    if (dir == null || dir.isEmpty) {
      await _pickLocalMusicDir(context, localMusic);
      return;
    }

    final option = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  '当前目录: $dir',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('选择新目录'),
                onTap: () => Navigator.of(context).pop(1),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: colorScheme.error,
                ),
                title: Text('清除目录', style: TextStyle(color: colorScheme.error)),
                onTap: () => Navigator.of(context).pop(2),
              ),
            ],
          ),
        );
      },
    );

    if (!context.mounted) return;
    if (option == 1) {
      await _pickLocalMusicDir(context, localMusic);
    } else if (option == 2) {
      await localMusic.setLocalMusicDir(null);
      Toast.success('已清除本地目录');
    }
  }

  Future<void> _pickLocalMusicDir(
    BuildContext context,
    LocalMusicController localMusic,
  ) async {
    try {
      final path = await FilePicker.getDirectoryPath();
      if (path == null) return;
      await localMusic.setLocalMusicDir(path);
      Toast.success('设置成功并开始扫描');
    } catch (e) {
      debugPrint('Error picking folder: $e');
      Toast.error('选择文件夹失败：$e');
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('退出登录'),
          content: const Text('确定要退出当前账号吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('退出登录'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

// --- Shared widgets ---

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

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

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

/// 音量均衡参考响度滑块。
class _VolumeNormLufsSlider extends StatelessWidget {
  const _VolumeNormLufsSlider({required this.player});

  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lufs = player.volumeNormalizationRefLufs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 20, 10),
      child: Row(
        children: [
          const SizedBox(width: 46),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '目标响度',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '${lufs.toStringAsFixed(0)} LUFS',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Slider(
                  min: -16,
                  max: -6,
                  divisions: 10,
                  value: lufs.clamp(-16.0, -6.0),
                  onChanged: (value) =>
                      player.setVolumeNormalizationRefLufs(value),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.iconColor,
    this.titleColor,
    this.subtitle,
    this.loading = false,
    this.onTap,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: loading
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: colorScheme.primary,
                      ),
                    )
                  : Icon(
                      icon,
                      size: 22,
                      color: iconColor ?? colorScheme.primary,
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: titleColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colorScheme.outline,
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.iconColor,
    this.subtitle,
    this.enabled = true,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// false 时置灰且不可操作（用于「依赖前置开关」的选项）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : .5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Icon(
                icon,
                size: 22,
                color: iconColor ?? colorScheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 62,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4),
    );
  }
}
