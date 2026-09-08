import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/artwork_cache_service.dart';
import 'package:kgka_music_hl/ui/widgets/cached_artwork_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用 Flutter 自己编码一张 PNG，避免依赖外部测试资源。
Future<Uint8List> _pngBytes() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(2, 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 解析一次 provider，返回解码后的图片。
Future<ui.Image> _decode(ImageProvider<Object> provider) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) completer.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory cacheDir;
  late HttpServer server;
  late Uint8List png;
  late String baseUrl;
  var requestCount = 0;

  setUpAll(() async {
    // TestWidgetsFlutterBinding 默认把所有 HttpClient 请求挡成 400，
    // 这里恢复真实请求，让测试能连本地 HttpServer。
    HttpOverrides.global = null;
    // path_provider 在测试环境走方法通道，这里直接返回临时目录。
    cacheDir = await Directory.systemTemp.createTemp('ka_artwork_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => cacheDir.path,
        );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    png = await _pngBytes();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    unawaited(
      () async {
        await for (final request in server) {
          requestCount++;
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('image', 'png')
            ..add(png);
          await request.response.close();
        }
      }(),
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
    if (cacheDir.existsSync()) await cacheDir.delete(recursive: true);
  });

  test('相同 URL 的 provider 相等，可共享内存缓存', () {
    const a = CachedArtworkImage('http://example.com/a.png');
    const b = CachedArtworkImage('http://example.com/a.png');
    const c = CachedArtworkImage('http://example.com/b.png');
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });

  test('同一 URL 并发加载只发起一次网络请求', () async {
    final url = '$baseUrl/concurrent.png';
    final before = requestCount;
    final files = await Future.wait(
      List.generate(5, (_) => ArtworkCacheService.instance.load(url)),
    );
    expect(requestCount - before, equals(1));
    expect(files.whereType<File>().map((f) => f.path).toSet(), hasLength(1));
  });

  test('CachedArtworkImage 解码磁盘缓存，二次解析不再请求网络', () async {
    final url = '$baseUrl/provider.png';
    final before = requestCount;

    final first = await _decode(CachedArtworkImage(url));
    expect(first.width, equals(2));
    expect(first.height, equals(2));
    expect(requestCount - before, equals(1));

    // 清掉内存缓存，验证磁盘命中路径不会再次发起请求。
    PaintingBinding.instance.imageCache.evict(CachedArtworkImage(url));
    final second = await _decode(CachedArtworkImage(url));
    expect(second.width, equals(2));
    expect(requestCount - before, equals(1));
  });
}
