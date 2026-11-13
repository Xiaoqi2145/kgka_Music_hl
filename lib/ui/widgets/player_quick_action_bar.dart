import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../controllers/player_page_layout_controller.dart';
import 'player_page_actions.dart';

/// 与控制行核心按钮同行的用户快捷动作。
///
/// 每个动作占固定槽位。正式态只有图标；编辑态在图标外增加独立圆角框，
/// 框与图标共用同一槽位，不额外撑宽控制行。
class PlayerQuickActionBar extends StatelessWidget {
  const PlayerQuickActionBar({
    super.key,
    required this.resolution,
    required this.player,
    required this.size,
    required this.iconSize,
    required this.color,
    required this.gap,
    this.editing = false,
  });

  final QuickActionResolution resolution;
  final PlayerController player;
  final double size;
  final double iconSize;
  final Color color;
  final double gap;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    if (!resolution.show || resolution.actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in resolution.actions) ...[
          SizedBox(width: gap),
          _QuickActionSlot(
            action: action,
            player: player,
            size: size,
            iconSize: iconSize,
            color: color,
            editing: editing,
          ),
        ],
      ],
    );
  }
}

class _QuickActionSlot extends StatelessWidget {
  const _QuickActionSlot({
    required this.action,
    required this.player,
    required this.size,
    required this.iconSize,
    required this.color,
    required this.editing,
  });

  final PlayerAction action;
  final PlayerController player;
  final double size;
  final double iconSize;
  final Color color;
  final bool editing;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: editing
          ? Key('player-quick-action-edit-frame-${action.id.name}')
          : null,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: editing
          ? BoxDecoration(
              color: Colors.white.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Colors.white.withValues(alpha: .55)),
            )
          : null,
      child: Tooltip(
        message: action.tooltipFor(player),
        child: IconButton(
          color: editing ? color.withValues(alpha: .55) : color,
          iconSize: iconSize,
          padding: EdgeInsets.zero,
          onPressed: editing ? null : action.onTap,
          icon: Icon(action.iconFor(player)),
        ),
      ),
    );
  }
}
