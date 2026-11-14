import 'dart:io';

import 'package:flutter/services.dart';

/// 把下载文件发布到 Android 系统公共下载目录。
///
/// Android 10 及以上通过 MediaStore 写入「下载/KA Music」，Android 9 及以下
/// 直接写入公共下载目录并通知媒体库。发布成功后返回可长期播放和删除的定位符：
/// Android 10 及以上为 content URI，其余为绝对路径。
class AndroidDownloadStore {
  const AndroidDownloadStore();

  static const _channel = MethodChannel('kgka_music_hl/downloads');

  /// 当前平台是否需要用系统下载目录保存。
  static bool get isSupported => Platform.isAndroid;

  static bool isLocator(String value) => value.startsWith('content://');

  Future<String> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
  }) async {
    final locator = await _channel.invokeMethod<String>('publish', {
      'sourcePath': sourcePath,
      'displayName': displayName,
      'mimeType': mimeType,
    });
    if (locator == null || locator.isEmpty) {
      throw StateError('无法保存到系统下载目录');
    }
    return locator;
  }

  Future<void> delete(String locator) async {
    await _channel.invokeMethod<void>('delete', {'locator': locator});
  }

  Future<int> sizeOf(String locator) async {
    final size = await _channel.invokeMethod<int>('size', {'locator': locator});
    return size ?? 0;
  }
}
