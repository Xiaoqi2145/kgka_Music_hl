import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/app_theme.dart';
import 'package:kgka_music_hl/ui/widgets/play_queue_sheet.dart';

class _Player extends ChangeNotifier implements PlayerController {
  _Player(this.queue, this.currentSong);

  @override
  final List<Song> queue;
  @override
  final Song currentSong;
  @override
  bool isPlaying = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(String hash) =>
    Song(id: hash, hash: hash, title: 'Song $hash', artist: 'Artist $hash');

void main() {
  testWidgets('opens scrolled to the current song', (tester) async {
    tester.view.physicalSize = const Size(430, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final queue = List.generate(40, (index) => _song('song-$index'));
    final player = _Player(queue, queue[20]);
    addTearDown(player.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showPlayQueueSheet(context, player),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();

    final scrollable = tester.widget<Scrollable>(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
    final offset = scrollable.controller?.offset ?? 0;
    expect(offset, greaterThan(0));
    expect(find.text('Song song-20'), findsOneWidget);
  });
}
