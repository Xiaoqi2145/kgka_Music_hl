import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../controllers/player_page_layout_controller.dart';
import 'player_page_actions.dart';

/// 与控制行核心按钮同行的用户快捷动作。
///
/// 按钮尺寸、颜色、点击区域与 [IconButton] 核心控件一致，不再使用圆底
/// 容器或独立一行。编辑态只禁用点击，槽位编辑由覆盖层负责。
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
          SizedBox.square(
            dimension: size,
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
          ),
        ],
      ],
    );
  }
}
