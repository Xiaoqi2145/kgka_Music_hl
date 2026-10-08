import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/playlist_mutation_serializer.dart';

void main() {
  test('mutations run strictly one at a time', () async {
    final serializer = PlaylistMutationSerializer();
    final log = <String>[];
    final gate = Completer<void>();

    // 第一个变更持有一个未完成的 await（模拟 setAudioSources 的平台往返）。
    final first = serializer.run(() async {
      log.add('load:start');
      await gate.future;
      log.add('load:end');
      return 'loaded';
    });
    // 第二个变更在它之后排队：其「检查长度」必须看到 load 完成后的状态。
    final second = serializer.run(() async {
      log.add('remove:check');
      return 'removed';
    });

    await Future<void>.delayed(Duration.zero);
    // 关键不变量：第二个变更不得在第一个完成前开始，否则长度检查读到的是
    // 过期的 sequenceState，removeAt(0) 会删掉刚加载的唯一音源。
    expect(
      log,
      ['load:start'],
      reason: '第二个变更必须等待第一个变更结束',
    );

    gate.complete();
    expect(await first, 'loaded');
    expect(await second, 'removed');
    expect(log, ['load:start', 'load:end', 'remove:check']);
  });

  test('a failing mutation does not stall the chain', () async {
    final serializer = PlaylistMutationSerializer();
    final first = serializer.run<void>(() async {
      throw StateError('remove failed');
    });
    await expectLater(first, throwsStateError);
    // 链必须继续可用：一次失败不得让后续所有变更都无法开始。
    final second = await serializer.run(() async => 'ok');
    expect(second, 'ok');
  });

  test('results and errors stay with their own caller', () async {
    final serializer = PlaylistMutationSerializer();
    final order = <int>[];
    final futures = [
      for (var i = 0; i < 5; i++)
        serializer.run(() async {
          await Future<void>.delayed(Duration(milliseconds: 5 - i));
          order.add(i);
          if (i == 3) throw StateError('boom $i');
          return i;
        }),
    ];
    for (var i = 0; i < 5; i++) {
      if (i == 3) {
        await expectLater(futures[i], throwsStateError);
      } else {
        expect(await futures[i], i, reason: '每个调用者拿到自己的结果');
      }
    }
    expect(order, [0, 1, 2, 3, 4], reason: '串行顺序即入队顺序');
  });
}
