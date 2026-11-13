import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import '../pages/desktop_lyrics_settings_page.dart';
import 'audio_effects_sheet.dart';
import 'playback_speed_sheet.dart';
import 'sleep_timer_sheet.dart';
import 'song_action_sheets.dart';

/// 播放页控件的稳定标识。
///
/// 持久化只使用 [PlayerActionId.name]。`音质 · 128K`、`音质：无损` 这类
/// 带运行时值的显示文案、以及随宫格/列表形态变化的标题都不能作为键。
/// 前 9 项为「更多」面板中可加入快捷区的功能动作，后 5 项为播放控制行
/// 固有控件（[PlayerAction.core]，一期不参与编辑）。
enum PlayerActionId {
  playbackSpeed,
  audioQuality,
  audioEffects,
  lyricPicker,
  sleepTimer,
  desktopLyrics,
  desktopLyricsSettings,
  addToNext,
  addToPlaylist,
  playbackMode,
  previous,
  playPause,
  next,
  playQueue,
}

/// 兼容模式（未自定义过）的快捷区成员，与 2163695 引入的硬编码一致。
const List<PlayerActionId> kLegacyQuickActions = <PlayerActionId>[
  PlayerActionId.lyricPicker,
  PlayerActionId.audioQuality,
  PlayerActionId.audioEffects,
];

/// 可加入快捷区的 9 项，顺序即编辑器候选池的默认顺序。
const List<PlayerActionId> kEditableActionIds = <PlayerActionId>[
  PlayerActionId.playbackSpeed,
  PlayerActionId.audioQuality,
  PlayerActionId.audioEffects,
  PlayerActionId.lyricPicker,
  PlayerActionId.sleepTimer,
  PlayerActionId.desktopLyrics,
  PlayerActionId.desktopLyricsSettings,
  PlayerActionId.addToNext,
  PlayerActionId.addToPlaylist,
];

/// 播放页单个控件的完整描述（注册表条目）。
class PlayerAction {
  const PlayerAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.core,
    required this.available,
    required this.showInMore,
    required this.onTap,
    required this.tooltip,
    this.iconBuilder,
    this.availabilityHint,
  });

  final PlayerActionId id;

  /// 稳定中文名，不含动态值，用于编辑器与测试断言。
  final String label;

  final IconData icon;

  /// true = 播放控制行固有控件，恒显且不可编辑。
  final bool core;

  /// 当前歌曲 / 设备下是否可用；不可用的动作不会渲染，也不会占槽位。
  final bool Function(PlayerController player, Song song) available;

  /// 是否出现在「更多」面板（封装既有的 isGrid / includeNext 规则）。
  final bool Function({required bool isGrid, required bool includeNext})
  showInMore;

  /// 点击行为。在 build 阶段捕获 context，面板关闭后延迟调用仍然有效。
  final VoidCallback onTap;

  /// 快捷按钮的 tooltip，可含运行时值。
  final String Function(PlayerController player) tooltip;

  /// 图标随状态变化时（桌面歌词开关）使用。
  final IconData? Function(PlayerController player)? iconBuilder;

  /// 编辑器里解释当前条件不可用的原因。
  final String? Function(PlayerController player, Song song)? availabilityHint;

  IconData iconFor(PlayerController player) =>
      iconBuilder?.call(player) ?? icon;

  String? hintFor(PlayerController player, Song song) =>
      available(player, song) ? null : availabilityHint?.call(player, song);
}

/// 构造播放页全部 14 个控件。[onAudioQuality] / [onLyricPicker] 由播放页
/// 注入，避免新文件反向依赖 `player_page.dart` 的私有函数。
List<PlayerAction> buildPlayerActions({
  required BuildContext context,
  required Song song,
  required PlayerController player,
  required AuthController auth,
  required VoidCallback onAudioQuality,
  required VoidCallback onLyricPicker,
}) {
  const always = _Always();
  bool desktopSupported(PlayerController p, Song _) =>
      p.isDesktopLyricsSupported;
  bool desktopEnabled(PlayerController p, Song _) => p.desktopLyricsEnabled;
  bool kugouOnly(PlayerController _, Song s) => s.source == SongSource.kugou;

  PlayerAction editable({
    required PlayerActionId id,
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    bool Function(PlayerController, Song)? available,
    IconData? Function(PlayerController)? iconBuilder,
    bool Function({required bool isGrid, required bool includeNext})?
    showInMore,
    String? Function(PlayerController, Song)? availabilityHint,
  }) {
    return PlayerAction(
      id: id,
      label: label,
      icon: icon,
      core: false,
      available: available ?? always.available,
      showInMore: showInMore ?? always.showInMore,
      onTap: onTap,
      tooltip: tooltip == null ? (_) => label : (p) => tooltip,
      iconBuilder: iconBuilder,
      availabilityHint: availabilityHint,
    );
  }

  PlayerAction core(PlayerActionId id, String label, IconData icon) {
    return PlayerAction(
      id: id,
      label: label,
      icon: icon,
      core: true,
      available: always.available,
      showInMore: ({required bool isGrid, required bool includeNext}) => false,
      onTap: () {},
      tooltip: (_) => label,
    );
  }

  return <PlayerAction>[
    editable(
      id: PlayerActionId.playbackSpeed,
      label: '倍速播放',
      icon: Icons.speed_rounded,
      onTap: () => showPlaybackSpeedSheet(context: context, player: player),
    ),
    editable(
      id: PlayerActionId.audioQuality,
      label: '音质',
      icon: Icons.high_quality_rounded,
      tooltip: null,
      onTap: onAudioQuality,
    ),
    editable(
      id: PlayerActionId.audioEffects,
      label: '音效',
      icon: Icons.graphic_eq_rounded,
      onTap: () => showAudioEffectsSheet(context: context, player: player),
    ),
    editable(
      id: PlayerActionId.lyricPicker,
      label: '更换歌词',
      icon: Icons.manage_search_rounded,
      onTap: onLyricPicker,
      // 竖屏「更多」是宫格，歌词页已有独立按钮，故不重复出现。
      showInMore: ({required bool isGrid, required bool includeNext}) =>
          !isGrid,
    ),
    editable(
      id: PlayerActionId.sleepTimer,
      label: '定时播放',
      icon: Icons.bedtime_rounded,
      onTap: () => showSleepTimerSheet(context: context, player: player),
    ),
    editable(
      id: PlayerActionId.desktopLyrics,
      label: '桌面歌词',
      icon: Icons.lyrics_outlined,
      available: desktopSupported,
      availabilityHint: (player, _) =>
          player.isDesktopLyricsSupported ? '' : '仅 Android',
      iconBuilder: (p) =>
          p.desktopLyricsEnabled ? Icons.lyrics_rounded : Icons.lyrics_outlined,
      onTap: () => player.setDesktopLyricsEnabled(!player.desktopLyricsEnabled),
    ),
    editable(
      id: PlayerActionId.desktopLyricsSettings,
      label: '歌词设置',
      icon: Icons.tune_rounded,
      available: desktopEnabled,
      availabilityHint: (player, _) => player.isDesktopLyricsSupported
          ? '仅在桌面歌词开启后可用'
          : '仅 Android 且桌面歌词开启后可用',
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DesktopLyricsSettingsPage(player: player),
        ),
      ),
    ),
    editable(
      id: PlayerActionId.addToNext,
      label: '下一首',
      icon: Icons.queue_music_rounded,
      showInMore: ({required bool isGrid, required bool includeNext}) =>
          includeNext,
      onTap: () => addSongToQueueWithFeedback(
        context: context,
        player: player,
        song: song,
      ),
    ),
    editable(
      id: PlayerActionId.addToPlaylist,
      label: '添加到歌单',
      icon: Icons.playlist_add_rounded,
      available: kugouOnly,
      availabilityHint: (_, _) => '仅酷狗歌曲',
      onTap: () =>
          showAddToPlaylistSheet(context: context, auth: auth, song: song),
    ),
    core(PlayerActionId.playbackMode, '播放模式', Icons.repeat_rounded),
    core(PlayerActionId.previous, '上一首', Icons.skip_previous_rounded),
    core(PlayerActionId.playPause, '播放/暂停', Icons.play_arrow_rounded),
    core(PlayerActionId.next, '下一首', Icons.skip_next_rounded),
    core(PlayerActionId.playQueue, '播放列表', Icons.queue_music_rounded),
  ];
}

/// 带运行时值的 tooltip：与 2163695 的文案保持一致。
extension PlayerActionTooltip on PlayerAction {
  String tooltipFor(PlayerController player) {
    return switch (id) {
      PlayerActionId.audioQuality => '音质 · ${player.audioQuality.badge}',
      PlayerActionId.audioEffects => '音效 · ${player.audioEffectsLabel}',
      _ => tooltip(player),
    };
  }
}

/// 把注册表条目转换成「更多」面板项；标题 / 副标题 / 动态图标在此集中维护。
SongSheetAction playerActionToSheetAction(
  PlayerAction action, {
  required bool isGrid,
  required PlayerController player,
}) {
  void tap() => action.onTap();
  switch (action.id) {
    case PlayerActionId.playbackSpeed:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: isGrid ? '倍速' : '倍速播放',
        subtitle: player.playbackSpeedLabel,
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.audioQuality:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: isGrid ? '音质' : '音质：${player.audioQuality.label}',
        subtitle: isGrid ? player.audioQuality.badge : '切换当前播放音质',
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.audioEffects:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: '音效',
        subtitle: isGrid ? null : player.audioEffectsLabel,
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.lyricPicker:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: '更换歌词',
        subtitle: '搜索并选择其他歌词版本',
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.sleepTimer:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: isGrid ? '定时' : '定时播放',
        subtitleBuilder: isGrid
            ? null
            : (context) => ValueListenableBuilder<SleepTimerUiState>(
                valueListenable: player.sleepTimerUiListenable,
                builder: (context, state, _) {
                  final subtitle = state.finishCurrentSong
                      ? '播完歌曲后停止'
                      : state.active
                      ? '剩余 ${formatSleepRemaining(state.remaining)}'
                      : null;
                  return subtitle == null
                      ? const SizedBox.shrink()
                      : Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        );
                },
              ),
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.desktopLyrics:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: '桌面歌词',
        subtitle: isGrid ? null : (player.desktopLyricsEnabled ? '已开启' : '已关闭'),
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.desktopLyricsSettings:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: '歌词设置',
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.addToNext:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: '下一首',
        isGrid: isGrid,
        onTap: tap,
      );
    case PlayerActionId.addToPlaylist:
      return SongSheetAction(
        icon: action.iconFor(player),
        title: '添加到歌单',
        isGrid: isGrid,
        onTap: tap,
      );
    default:
      return SongSheetAction(
        icon: action.icon,
        title: action.label,
        isGrid: isGrid,
        onTap: tap,
      );
  }
}

/// 定时播放剩余时间格式化（从播放页迁入，供注册表与编辑器共用）。
String formatSleepRemaining(Duration? remaining) {
  if (remaining == null || remaining <= Duration.zero) return '';
  final minutes = remaining.inMinutes;
  final seconds = remaining.inSeconds.remainder(60);
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class _Always {
  const _Always();
  bool available(PlayerController player, Song song) => true;
  bool showInMore({required bool isGrid, required bool includeNext}) => true;
}
