import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../services/artwork_cache_service.dart';

/// 把 [ArtworkCacheService] 的磁盘缓存包装成 [ImageProvider]。
///
/// 与 [Image.network] 的区别：
/// 1. 同一 URL 只发起一次网络请求 —— 命中磁盘缓存直接解码，未命中则交给
///    [ArtworkCacheService] 下载，在途请求由服务内部共享（[ArtworkCacheService.load]）。
/// 2. 离线可用 —— 已经缓存过的封面即使断网也能渲染，不会退化成占位图。
///
/// 播放页背景图与同屏的 [Artwork] 使用同一个 URL，改用它即可复用
/// [ArtworkCacheService] 已有的那次下载，不额外增加缓存条目。
class CachedArtworkImage extends ImageProvider<CachedArtworkImage> {
  const CachedArtworkImage(this.url);

  /// 远程图片地址，与 [ArtworkCacheService] 的缓存键一致。
  final String url;

  @override
  Future<CachedArtworkImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CachedArtworkImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    CachedArtworkImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1,
      debugLabel: 'CachedArtworkImage("${key.url}")',
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('URL: ${key.url}'),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    CachedArtworkImage key,
    ImageDecoderCallback decode,
  ) async {
    final file = await ArtworkCacheService.instance.load(key.url);
    if (file == null) {
      // 清掉失败记录，下次重新解析时允许重试（例如刚恢复网络）。
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('缩略图获取失败：${key.url}');
    }
    if (await file.length() == 0) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('缩略图文件为空：${file.path}');
    }
    return decode(await ui.ImmutableBuffer.fromFilePath(file.path));
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is CachedArtworkImage && other.url == url;
  }

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'CachedArtworkImage("$url")';
}
