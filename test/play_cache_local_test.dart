import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/download_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late HttpServer server;

  setUp(() async {
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('ka_play_cache_local_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final bytes = [0x49, 0x44, 0x33, 1, 2, 3];
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'audio',
          'mpeg',
          charset: null,
        )
        ..headers.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });

  test('playback cache stays inside the cache directory', () async {
    final service = DownloadService();
    addTearDown(service.dispose);
    const song = Song(id: 'cache', hash: 'cache', title: '缓存', artist: '歌手');
    final url =
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/cache.mp3';
    final path = await service.cacheForPlayback(
      song: song,
      quality: AudioQuality.high,
      url: url,
    );
    final cacheDir = await service.playCacheDir();
    expect(File(path).parent.path, cacheDir.path);
    expect(await File(path).length(), greaterThan(0));
    expect(await service.getPlayCacheDirSize(), greaterThan(0));
    String normalize(String value) => value.replaceAll('\\', '/');
    expect(
      cacheDir.listSync().whereType<File>().map(
        (file) => normalize(file.path),
      ),
      contains(normalize(path)),
    );
  });
}