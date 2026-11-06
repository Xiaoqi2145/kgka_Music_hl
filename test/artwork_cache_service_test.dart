import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/artwork_cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late DateTime now;
  late int attempts;
  late _CountingHttpClientFactory httpFactory;

  ArtworkCacheService service({Duration? retryAfter}) =>
      ArtworkCacheService.forTest(
        directory: directory,
        now: () => now,
        failureRetryAfter: retryAfter,
        maxCacheBytes: 1024 * 1024 * 1024,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    directory = await Directory.systemTemp.createTemp('ka_artwork_service-');
    now = DateTime(2026, 1, 1, 12);
    attempts = 0;
    HttpOverrides.global = null;
    httpFactory = _CountingHttpClientFactory(() => attempts++);
    HttpOverrides.global = _CountingHttpOverrides(httpFactory);
  });

  tearDown(() async {
    HttpOverrides.global = null;
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('failed artwork is cached until its retry window expires', () async {
    final cache = service(retryAfter: const Duration(minutes: 1));
    const url = 'http://127.0.0.1:0/failed.png';

    expect(await cache.load(url), isNull);
    expect(await cache.load(url), isNull);
    expect(await cache.load(url), isNull);
    expect(attempts, 1);

    now = now.add(const Duration(minutes: 1, seconds: 1));
    expect(await cache.load(url), isNull);
    expect(attempts, 2);
  });

  test(
    'cache hit does not write file mtime and invalidation permits retry',
    () async {
      final cache = service();
      const url = 'http://127.0.0.1:0/cover.png';
      final file = await cache.fileFor(url);
      await file.writeAsBytes(<int>[1, 2, 3]);
      final before = await file.lastModified();

      now = now.add(const Duration(minutes: 10));
      expect(await cache.load(url), isNotNull);
      expect(await file.lastModified(), before);

      await cache.invalidate(url);
      expect(await cache.load(url), isNull);
      expect(attempts, 1);
      now = now.add(const Duration(minutes: 1, seconds: 1));
      expect(await cache.load(url), isNull);
      expect(attempts, 2);
    },
  );
}

class _CountingHttpOverrides extends HttpOverrides {
  _CountingHttpOverrides(this.factory);

  final _CountingHttpClientFactory factory;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _CountingHttpClient(factory);
}

class _CountingHttpClientFactory {
  _CountingHttpClientFactory(this.onRequest);

  final void Function() onRequest;
}

class _CountingHttpClient implements HttpClient {
  _CountingHttpClient(this.factory);

  final _CountingHttpClientFactory factory;
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    factory.onRequest();
    return Future<HttpClientRequest>.error(
      const SocketException('simulated artwork failure'),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
