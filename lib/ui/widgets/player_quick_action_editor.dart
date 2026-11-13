import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../controllers/player_page_layout_controller.dart';
import '../../models/music_models.dart';
import 'player_page_actions.dart';

/// 播放页内快捷动作编辑器（D4）。
///
/// 编辑面板只占下半屏，播放页原控制行保持可见并作为实时预览。面板本身
/// 使用不透明深色底，避免歌词透过小字号内容影响可读性。
class PlayerQuickActionEditor extends StatelessWidget {
  const PlayerQuickActionEditor({
    super.key,
    required this.all,
    required this.draft,
    required this.resolution,
    required this.player,
    required this.song,
    required this.onChanged,
    required this.onCommit,
    required this.onCancel,
    required this.onReset,
  });

  final List<PlayerAction> all;
  final List<PlayerActionId> draft;
  final QuickActionResolution resolution;
  final PlayerController player;
  final Song song;
  final ValueChanged<List<PlayerActionId>> onChanged;
  final VoidCallback onCommit;
  final VoidCallback onCancel;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final byId = <PlayerActionId, PlayerAction>{
      for (final action in all) action.id: action,
    };
    final selected = draft.toSet();
    final hints = <PlayerActionId, String>{};
    for (final action in all) {
      final hint = action.hintFor(player, song);
      if (hint != null && hint.isNotEmpty) hints[action.id] = hint;
    }
    final ordered = <PlayerAction>[
      for (final id in draft)
        if (byId[id] != null) byId[id]!,
    ];
    final candidates = <PlayerAction>[
      for (final id in kEditableActionIds)
        if (!selected.contains(id) && byId[id] != null) byId[id]!,
    ];
    final shown = resolution.actions.map((action) => action.id).toSet();

    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .58,
            maxWidth: 760,
          ),
          child: Material(
            color: const Color(0xFF14171C),
            elevation: 18,
            shadowColor: Colors.black54,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '编辑快捷动作',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(onPressed: onCancel, child: const Text('取消')),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: onCommit,
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '控制行预览'
                          '${resolution.overflow.isEmpty ? '' : ' · 超出项仍在「更多」'}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        '${shown.length}/${resolution.maxSlots}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _SectionTitle(title: '已选动作', trailing: '拖动排序'),
                        if (ordered.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '点击下方动作加入控制行',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          )
                        else
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            buildDefaultDragHandles: false,
                            itemCount: ordered.length,
                            onReorderItem: (oldIndex, newIndex) {
                              final next = [...draft];
                              final moved = next.removeAt(oldIndex);
                              var insertAt = newIndex;
                              if (insertAt > next.length) {
                                insertAt = next.length;
                              }
                              next.insert(insertAt, moved);
                              onChanged(next);
                            },
                            itemBuilder: (context, index) {
                              final action = ordered[index];
                              final hint = hints[action.id];
                              final dimmed =
                                  hint != null || !shown.contains(action.id);
                              return Container(
                                key: ValueKey('draft-${action.id.name}'),
                                margin: const EdgeInsets.only(bottom: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .05),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ListTile(
                                  dense: true,
                                  minLeadingWidth: 20,
                                  contentPadding: const EdgeInsets.only(
                                    left: 10,
                                    right: 2,
                                  ),
                                  leading: Icon(
                                    action.iconFor(player),
                                    size: 20,
                                    color: dimmed
                                        ? Colors.white38
                                        : Colors.white,
                                  ),
                                  title: Text(
                                    action.label,
                                    style: TextStyle(
                                      color: dimmed
                                          ? Colors.white54
                                          : Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                  subtitle: hint == null
                                      ? null
                                      : Text(
                                          hint,
                                          style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 11,
                                          ),
                                        ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: '移除 ${action.label}',
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                          color: Colors.white70,
                                        ),
                                        onPressed: () {
                                          final next = [...draft]
                                            ..remove(action.id);
                                          onChanged(next);
                                        },
                                      ),
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          child: Icon(
                                            Icons.drag_handle_rounded,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        const SizedBox(height: 10),
                        const _SectionTitle(title: '可添加'),
                        _CandidatePanel(
                          candidates: candidates,
                          hints: hints,
                          onAdd: (id) => onChanged([...draft, id]),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onReset,
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text('恢复默认'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (trailing != null)
            Text(
              trailing!,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

class _CandidatePanel extends StatelessWidget {
  const _CandidatePanel({
    required this.candidates,
    required this.hints,
    required this.onAdd,
  });

  final List<PlayerAction> candidates;
  final Map<PlayerActionId, String> hints;
  final ValueChanged<PlayerActionId> onAdd;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) {
      return const Text(
        '全部动作都已加入',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      );
    }
    return SizedBox(
      height: 120,
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final action in candidates)
              _CandidateChip(
                action: action,
                hint: hints[action.id],
                onPressed: () => onAdd(action.id),
              ),
          ],
        ),
      ),
    );
  }
}

class _CandidateChip extends StatelessWidget {
  const _CandidateChip({
    required this.action,
    required this.hint,
    required this.onPressed,
  });

  final PlayerAction action;
  final String? hint;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final hintText = hint;
    return Tooltip(
      message: hintText ?? '加入控制行',
      child: Material(
        key: Key('quick-action-candidate-${action.id.name}'),
        color: Colors.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add_rounded,
                  size: 16,
                  color: hintText == null ? Colors.white : Colors.white54,
                ),
                const SizedBox(width: 5),
                Text(
                  hintText == null
                      ? action.label
                      : '${action.label} · $hintText',
                  style: TextStyle(
                    color: hintText == null ? Colors.white : Colors.white54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
