import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Small disk cache for remote artwork.
///
/// Artwork is kept separately from JSON data so an offline session can still
/// render covers that were shown before. In-flight downloads are shared to
/// avoid waking the network once per list tile.
class ArtworkCacheService {
  ArtworkCacheService._();

  static final ArtworkCacheService instance = ArtworkCacheService._();
  final Map<String, Future<File?>> _pending = <String, Future<File?>>{};
  Directory? _directory;

  Future<Directory> _getDirectory() async {
    final current = _directory;
    if (current != null) return current;
    final base = await getTemporaryDirectory();
    final directory = Directory('${base.path}/ka_music_artwork');
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }

  Future<File> _fileFor(String url) async {
    final directory = await _getDirectory();
    final key = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    return File('${directory.path}/$key.img');
  }

  Future<File?> load(String url) {
    final existing = _pending[url];
    if (existing != null) return existing;
    final future = _load(url);
    _pending[url] = future;
    unawaited(future.whenComplete(() => _pending.remove(url)));
    return future;
  }

  Future<File?> _load(String url) async {
    final file = await _fileFor(url);
    if (await file.exists() && await file.length() > 0) return file;

    final temporary = File('${file.path}.part');
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.followRedirects = true;
        request.maxRedirects = 3;
        final response = await request.close().timeout(
          const Duration(seconds: 12),
        );
        if (response.statusCode < 200 || response.statusCode >= 300)
          return null;
        await response.pipe(temporary.openWrite());
        if (!await temporary.exists() || await temporary.length() == 0)
          return null;
        if (await file.exists()) await file.delete();
        return await temporary.rename(file.path);
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      return null;
    }
  }
}
