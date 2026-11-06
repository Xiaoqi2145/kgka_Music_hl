import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'artwork.dart';

/// Opens the same queue surface from the player and the mini player.
void showPlayQueueSheet(BuildContext context, PlayerController player) {
  void removeFromQueue(
    BuildContext sheetContext,
    int index, {
    VoidCallback? dismiss,
  }) {
    void closeSheet() {
      if (dismiss != null) {
        dismiss();
      } else {
        Navigator.of(sheetContext).pop();
      }
    }

    final newQueue = List<Song>.of(player.queue);
    if (index < 0 || index >= newQueue.length) return;
    final removed = newQueue.removeAt(index);
    final current = player.currentSong;
    if (current == null) return;

    if (removed.hash == current.hash) {
      final nextIndex = index.clamp(0, newQueue.length - 1);
      if (newQueue.isEmpty) {
        closeSheet();
        player.updateQueueContext([current]);
        return;
      }
      closeSheet();
      player.playSong(newQueue[nextIndex], queue: newQueue);
    } else {
      player.updateQueueContext(newQueue);
    }
  }

  Widget queueHeader(BuildContext context, {VoidCallback? onClose}) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .65),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '播放列表  ${player.queue.length}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              if (onClose != null)
                IconButton(
                  tooltip: '关闭',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                  color: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget queueList(BuildContext sheetContext, {VoidCallback? dismiss}) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        if (player.queue.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 36),
            child: Center(
              child: Text(
                '播放队列为空',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
          itemCount: player.queue.length,
          itemBuilder: (context, index) {
            final song = player.queue[index];
            final active = player.currentSong?.hash == song.hash;
            final dismissible = player.queue.length > 1;
            final tile = Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: active ? scheme.primary.withValues(alpha: .08) : null,
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: ListTile(
                  selected: active,
                  selectedColor: scheme.primary,
                  tileColor: Colors.transparent,
                  selectedTileColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  leading: SizedBox(
                    width: 76,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: active
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Artwork(url: song.coverUrl, size: 50, borderRadius: 10),
                      ],
                    ),
                  ),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: active ? scheme.primary : scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: active
                          ? scheme.primary.withValues(alpha: .78)
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: active
                      ? Icon(
                          player.isPlaying
                              ? Icons.equalizer_rounded
                              : Icons.pause_rounded,
                          size: 18,
                          color: scheme.primary,
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
                ),
              ),
            );
            if (!dismissible) return tile;
            return Dismissible(
              key: ValueKey(song.hash),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.delete_outline_rounded,
                  color: scheme.onErrorContainer,
                ),
              ),
              onDismissed: (_) => removeFromQueue(
                sheetContext,
                index,
                dismiss: dismiss,
              ),
              child: tile,
            );
          },
        );
      },
    );
  }

  final size = MediaQuery.sizeOf(context);
  final scheme = Theme.of(context).colorScheme;
  final isLandscape = size.width > size.height;
  if (!isLandscape) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surfaceContainerLow,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            queueHeader(sheetContext),
            Flexible(child: queueList(sheetContext)),
          ],
        ),
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
            color: Theme.of(overlayContext).colorScheme.surfaceContainerLow,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: drawerWidth,
              height: double.infinity,
              child: SafeArea(
                child: Column(
                  children: [
                    queueHeader(overlayContext, onClose: entry.remove),
                    Expanded(
                      child: queueList(overlayContext, dismiss: entry.remove),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  Overlay.of(context).insert(entry);
}
