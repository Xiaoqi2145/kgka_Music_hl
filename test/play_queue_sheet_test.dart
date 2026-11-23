import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/core/api_client.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/models/personal_fm_models.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/personal_fm_session.dart';
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
  List<PersonalFmSelection> personalFmQueueEntries = const [];
  PersonalFmSelection? selected;
  Song? ordinarySelection;

  @override
  Future<void> playPersonalFmSong(PersonalFmSelection selection) async {
    selected = selection;
  }

  @override
  Future<void> playSong(Song song, {List<Song>? queue}) async {
    ordinarySelection = song;
  }

  @override
  void removePersonalFmSong(PersonalFmSelection selection) {
    queue.remove(selection.track.song);
    personalFmQueueEntries = personalFmQueueEntries
        .where((entry) => entry != selection)
        .toList();
    notifyListeners();
  }

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

  testWidgets('open FM queue refreshes and routes tap and swipe by entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = MusicApi(ApiClient());
    final session = PersonalFmSession(api, ownerKey: 'test', launchId: 'test');
    final songs = [_song('A'), _song('B'), _song('C')];
    final player = _Player([...songs], songs.first);
    PersonalFmSelection entry(Song song, PersonalFmTrackSource? source) =>
        (session: session, track: PersonalFmTrack(song: song), source: source);
    final current = entry(songs[0], null);
    final b = entry(songs[1], PersonalFmTrackSource.candidate);
    final c = entry(songs[2], PersonalFmTrackSource.candidate);
    player.personalFmQueueEntries = [current, b, c];
    addTearDown(player.dispose);
    addTearDown(session.dispose);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlayQueueSheet(context, player),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.text('Song A'),
        matching: find.byType(Dismissible),
      ),
      findsNothing,
    );
    final newSong = _song('D');
    final added = entry(newSong, PersonalFmTrackSource.candidate);
    player.queue.add(newSong);
    player.personalFmQueueEntries = [current, b, c, added];
    player.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Song D'), findsOneWidget);
    await tester.drag(find.byKey(ValueKey(b)), const Offset(-380, 0));
    await tester.pumpAndSettle();
    expect(find.text('Song B'), findsNothing);
    expect(find.text('Song C'), findsOneWidget);
    await tester.tap(find.text('Song C'));
    await tester.pumpAndSettle();
    expect(player.selected, c);
    expect(player.ordinarySelection, isNull);
  });
}
