import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/ui/widgets/artwork.dart';
import 'package:kgka_music_hl/ui/widgets/listenable_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ListenableSelector', () {
    testWidgets('派生值不变时不重建子树', (tester) async {
      final listenable = ValueNotifier<int>(0);
      addTearDown(listenable.dispose);
      var builds = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ListenableSelector<ValueNotifier<int>, bool>(
            listenable: listenable,
            selector: (_, value) => value.value.isEven,
            builder: (context, value) {
              builds++;
              return Text('$value', textDirection: TextDirection.ltr);
            },
          ),
        ),
      );
      expect(builds, equals(1));
      expect(find.text('true'), findsOneWidget);

      // 通知了，但派生值没变 → 不重建。
      listenable.value = 2;
      await tester.pump();
      expect(builds, equals(1));

      // 派生值变了 → 重建。
      listenable.value = 3;
      await tester.pump();
      expect(builds, equals(2));
      expect(find.text('false'), findsOneWidget);
    });

    testWidgets('卸载后不再响应通知', (tester) async {
      final listenable = ValueNotifier<int>(0);
      addTearDown(listenable.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ListenableSelector<ValueNotifier<int>, int>(
            listenable: listenable,
            selector: (_, value) => value.value,
            builder: (context, value) =>
                Text('$value', textDirection: TextDirection.ltr),
          ),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(home: Text('gone', textDirection: TextDirection.ltr)),
      );

      // 若监听没有正确摘除，这里会抛 "used after dispose"。
      listenable.value = 42;
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Artwork', () {
    test('解码边长按显示尺寸与设备像素比换算', () {
      // 128dp 封面在 3x 屏上按 384px 解码，而不是按原始分辨率解出整张大图。
      expect(artworkDecodePixels(size: 128, devicePixelRatio: 3), 384);
      expect(artworkDecodePixels(size: 44, devicePixelRatio: 2.5), 110);
      expect(artworkDecodePixels(size: 50, devicePixelRatio: 1), 50);
      // 父级用 expand 约束时不给提示。
      expect(
        artworkDecodePixels(size: double.infinity, devicePixelRatio: 3),
        isNull,
      );
      expect(artworkDecodePixels(size: 0, devicePixelRatio: 3), isNull);
      expect(artworkDecodePixels(size: -10, devicePixelRatio: 3), isNull);
      expect(
        artworkDecodePixels(size: 128, devicePixelRatio: double.nan),
        isNull,
      );
      // 超大尺寸兜底，避免撑爆内存。
      expect(artworkDecodePixels(size: 2000, devicePixelRatio: 3), 2048);
    });

    testWidgets('每张封面自带重绘边界', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Artwork(size: 44)),
        ),
      );
      expect(find.byType(RepaintBoundary), findsWidgets);
    });
  });
}