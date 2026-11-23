import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/app_theme.dart';

/// 预览截图工具。
///
/// 目的：让 screenshots/ 里的预览图**由真实 widget 渲染**。真机截图一旦 UI
/// 改动就会集体过期；跑一遍 `flutter test --update-goldens` 就能拿到当前版本。
///
/// 两个必须处理的坑：
/// 1. flutter_test 默认用 Ahem 字体（全是实心方块），要先装载真实字体；
/// 2. widget test 跑在伪造时钟里，`Image.file` 的磁盘读取与解码永远不会推进，
///    必须把「搭树 + 等待」放进 [WidgetTester.runAsync]，否则截出来封面是空白。
class ScreenshotHarness {
  const ScreenshotHarness._();

  /// 与真机一致的单屏逻辑尺寸（1.5K 屏，dpr 3）。
  static const double deviceWidth = 420;
  static const double deviceHeight = 912;
  static const double devicePixelRatio = 3;

  static Future<void> loadFonts() async {
    await _loadFamily('NotoSansSC', const [
      r'C:\Windows\Fonts\Noto Sans SC (TrueType).otf',
      r'C:\Windows\Fonts\Noto Sans SC Medium (TrueType).otf',
      r'C:\Windows\Fonts\Noto Sans SC Bold (TrueType).otf',
    ]);
    await _loadFamily('MaterialIcons', const [
      r'D:\SDK\Flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    ]);
  }

  static Future<void> _loadFamily(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var loaded = false;
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
      loaded = true;
    }
    if (loaded) await loader.load();
  }

  /// 截图用主题：与 app 默认皮肤一致，只是字体换成真实中文字体。
  static ThemeData theme({required bool dark}) {
    final base = dark ? AppTheme.dark() : AppTheme.light();
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
    );
  }

  /// 让页面看起来是「被推入的二级页」：标题栏会出现返回箭头，
  /// 与用户从缓存管理点进缓存歌曲列表的真实路径一致。
  static Widget _routeHost(Widget child, {required bool pushedRoute}) {
    if (!pushedRoute) return child;
    return Navigator(
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.expand()),
        ),
        MaterialPageRoute<void>(builder: (_) => child),
      ],
    );
  }

  static Future<void> capture(
    WidgetTester tester, {
    required Widget child,
    required String path,
    bool dark = false,
    double width = deviceWidth,
    double height = deviceHeight,
    double textScale = 1,
    double scrollBy = 0,
    bool pushedRoute = false,
  }) async {
    tester.view
      ..physicalSize = ui.Size(width * devicePixelRatio, height * devicePixelRatio)
      ..devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme(dark: dark),
      builder: (context, root) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: const EdgeInsets.only(top: 28),
          viewPadding: const EdgeInsets.only(top: 28),
        ),
        child: root!,
      ),
      home: _routeHost(child, pushedRoute: pushedRoute),
    );

    // 真实事件循环里搭树并等待：封面从缓存目录读取 + 解码都发生在这里。
    await tester.runAsync(() async {
      await tester.pumpWidget(app);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    if (scrollBy != 0) {
      await tester.drag(find.byType(Scrollable).first, Offset(0, -scrollBy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
    }

    final directory = Directory('screenshots');
    if (!directory.existsSync()) directory.createSync(recursive: true);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../screenshots/$path'),
    );
  }
}
