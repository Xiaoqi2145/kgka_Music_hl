import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_taglib/flutter_taglib.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/download_tag_writer.dart';

void main() {
  const song = Song(
    id: 'tag',
    hash: 'tag',
    title: '月虹蝶',
    artist: 'NEEDY GIRL OVERDOSE / KOTOKO / Aiobahn +81',
    albumName: '月虹蝶',
  );

  test('writes title, artist, album and cover into an mp3', () async {
    final work = File('diagnostics/tag-writer-test.mp3');
    addTearDown(() async {
      if (await work.exists()) await work.delete();
    });
    await work.writeAsBytes([0x49, 0x44, 0x33, 1, 2, 3]);
    final png = Uint8List.fromList([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ]);
    await const DownloadTagWriter().applyWithCover(
      path: work.path,
      song: song,
      coverBytes: png,
    );
    final read = TagLibFile.open(work.path)!;
    addTearDown(read.close);
    expect(read.title, '月虹蝶');
    expect(read.artist, contains('KOTOKO'));
    expect(read.album, '月虹蝶');
    expect(read.hasCover, isTrue);
  });
}