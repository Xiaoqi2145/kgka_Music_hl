import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/download_service.dart';

void main() {
  late Directory directory;
  late DownloadService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ka_play_cache_test');
    service = DownloadService();
  });

  tearDown(() async {
    service.dispose();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('prunes least recently accessed cache first', () async {
    final oldFile = File('${directory.path}/old.mp3')
      ..writeAsBytesSync([1, 2, 3]);
    final recentFile = File('${directory.path}/recent.mp3')
      ..writeAsBytesSync([4, 5, 6]);
    final removed = await service.prunePlayCache([
      (
        cacheKey: 'old',
        filePath: oldFile.path,
        size: 3,
        cachedAt: DateTime(2020),
      ),
      (
        cacheKey: 'recent',
        filePath: recentFile.path,
        size: 3,
        cachedAt: DateTime(2025),
      ),
    ], maxBytes: 3);

    expect(removed, {'old'});
    expect(await oldFile.exists(), isFalse);
    expect(await recentFile.exists(), isTrue);
  });

  test('preserves the active file even if it exceeds the cap', () async {
    final activeFile = File('${directory.path}/active.mp3')
      ..writeAsBytesSync([1, 2, 3]);
    final removed = await service.prunePlayCache(
      [
        (
          cacheKey: 'active',
          filePath: activeFile.path,
          size: 3,
          cachedAt: DateTime(2020),
        ),
      ],
      excludePaths: {activeFile.path},
      maxBytes: 1,
    );

    expect(removed, isEmpty);
    expect(await activeFile.exists(), isTrue);
  });
}
