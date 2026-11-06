import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'artwork.dart';
import 'toast.dart';

/// Opens the same queue surface from the player and the mini player.
void showPlayQueueSheet(BuildContext context, PlayerController player) {
  void removeFromQueue(BuildContext sheetContext, int index) {
    final newQueue = List<Song>.of(player.queue);
    if (index < 0 || index >= newQueue.length) return;
    final removed = newQueue.removeAt(index);
    final current = player.currentSong;
    if (current == null) return;

    if (removed.hash == current.hash) {
      final nextIndex = index.clamp(0, newQueue.length - 1);
      if (newQueue.isEmpty) {
        Navigator.of(sheetContext).pop();
        player.updateQueueContext([current]);
        return;
      }
      Navigator.of(sheetContext).pop();
      player.playSong(newQueue[nextIndex], queue: newQueue);
    } else {
      player.updateQueueContext(newQueue);
    }
  }

  Widget queueList(BuildContext sheetContext, {VoidCallback? dismiss}) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) => ListView.builder(
        itemCount: player.queue.length,
        itemBuilder: (context, index) {
          final song = player.queue[index];
          final active = player.currentSong?.hash == song.hash;
          return ListTile(
            selected: active,
            leading: SizedBox(
              width: 76,
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: active
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Artwork(url: song.coverUrl, size: 44),
                ],
              ),
            ),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: player.queue.length > 1
                ? IconButton(
                    tooltip: '从队列移除',
                    onPressed: () => removeFromQueue(sheetContext, index),
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                  )
                : null,
            onTap: () {
              if (dismiss != null) {
                dismiss();
              } else {
                Navigator.of(sheetContext).pop();
              }
              player.playSong(song, queue: player.queue);
            },
          );
        },
      ),
    );
  }

  final size = MediaQuery.sizeOf(context);
  final isLandscape = size.width > size.height;
  if (!isLandscape) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
            child: Row(
              children: [
                Text(
                  '播放列表  ${player.queue.length}',
                  style: Theme.of(
                    sheetContext,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
                const Spacer(),
                TextButton(
                  onPressed: player.queue.length > 1
                      ? () {
                          final current = player.currentSong;
                          if (current == null) return;
                          Navigator.of(sheetContext).pop();
                          player.updateQueueContext([current]);
                          Toast.success('已清空播放队列');
                        }
                      : null,
                  child: Text(
                    '清空',
                    style: TextStyle(
                      color: Theme.of(sheetContext).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Flexible(child: queueList(sheetContext)),
        ],
      ),
    );
    return;
  }

  final drawerWidth = (size.width * .38).clamp(320.0, 560.0);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: entry.remove,
            child: const ColoredBox(color: Colors.black54),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(overlayContext).colorScheme.surface,
            // 横屏播放列表贴合屏幕右侧，不额外保留圆角。
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: drawerWidth,
              height: double.infinity,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '播放列表  ${player.queue.length}',
                            style: Theme.of(overlayContext).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w900),
                          ),
                        ),
                        TextButton(
                          onPressed: player.queue.length > 1
                              ? () {
                                  final current = player.currentSong;
                                  if (current == null) return;
                                  entry.remove();
                                  player.updateQueueContext([current]);
                                  Toast.success('已清空播放队列');
                                }
                              : null,
                          child: Text(
                            '清空',
                            style: TextStyle(
                              color: Theme.of(overlayContext).colorScheme.error,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: entry.remove,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: queueList(overlayContext, dismiss: entry.remove),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
  Overlay.of(context).insert(entry);
}
