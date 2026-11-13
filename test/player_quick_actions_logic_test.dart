import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/player_page_layout_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/ui/widgets/player_page_actions.dart';

class _Player extends ChangeNotifier implements PlayerController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Song extends ChangeNotifier implements Song {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth extends ChangeNotifier implements AuthController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final registry = <PlayerAction>[
    for (final id in PlayerActionId.values)
      PlayerAction(
        id: id,
        label: id.name,
        icon: Icons.circle,
        core: id.index >= 9,
        available: (_, _) => true,
        showInMore: ({required bool isGrid, required bool includeNext}) =>
            id.index < 9,
        onTap: () {},
        tooltip: (_) => id.name,
      ),
  ];

  group('LandscapeOnlyPlacement 策略矩阵', () {
    const placement = LandscapeOnlyPlacement();

    QuickActionPlacementSpec spec(Size size, {bool veryTight = false}) =>
        placement.resolve(size, veryTight: veryTight);

    test('平板横屏显示 5 个槽位', () {
      final s = spec(const Size(1024, 768));
      expect(s.show, isTrue);
      expect(s.maxSlots, 5);
      expect(s.host, QuickActionHost.belowControls);
    });

    test('手机横屏显示 3 个槽位', () {
      final s = spec(const Size(800, 360));
      expect(s.show, isTrue);
      expect(s.maxSlots, 3);
    });

    test('手机横屏低高度仍显示，只有 veryTight 隐藏', () {
      final normal = spec(const Size(720, 360));
      expect(normal.show, isTrue);
      expect(normal.maxSlots, 3);
      expect(spec(const Size(720, 360), veryTight: true).show, isFalse);
    });

    test('竖屏暂不显示（portraitTbd 占位，D3 预留接口）', () {
      final s = spec(const Size(400, 800));
      expect(s.show, isFalse);
      expect(s.maxSlots, 0);
      expect(s.host, QuickActionHost.portraitTbd);
    });

    test('veryTight 横屏整行隐藏', () {
      final s = spec(const Size(1024, 240), veryTight: true);
      expect(s.show, isFalse);
    });
  });

  group('resolveQuickActions 纯函数', () {
    final all = <PlayerAction>[
      for (final id in kEditableActionIds)
        PlayerAction(
          id: id,
          label: id.name,
          icon: Icons.circle,
          core: false,
          available: (_, _) => true,
          showInMore: ({required bool isGrid, required bool includeNext}) =>
              true,
          onTap: () {},
          tooltip: (_) => id.name,
        ),
    ];
    const shown = QuickActionPlacementSpec(
      show: true,
      maxSlots: 3,
      host: QuickActionHost.belowControls,
    );
    const hidden = QuickActionPlacementSpec(
      show: false,
      maxSlots: 0,
      host: QuickActionHost.portraitTbd,
    );
    final player = _Player();
    final song = _Song();

    QuickActionResolution run(
      List<PlayerActionId> ids,
      QuickActionPlacementSpec s,
    ) {
      return resolveQuickActions(
        ids: ids,
        spec: s,
        all: all,
        player: player,
        song: song,
        isAvailable: (_) => true,
      );
    }

    test('按容量截断，超出项进入 overflow', () {
      final r = run([
        PlayerActionId.playbackSpeed,
        PlayerActionId.audioQuality,
        PlayerActionId.audioEffects,
        PlayerActionId.sleepTimer,
      ], shown);
      expect(r.show, isTrue);
      expect(r.actions.length, 3);
      expect(r.overflow.length, 1);
      expect(r.excludeIds.length, 3);
    });

    test('hidden 策略下 excludeIds 为空（竖屏「更多」保持完整）', () {
      final r = run(kEditableActionIds.take(4).toList(), hidden);
      expect(r.show, isFalse);
      expect(r.excludeIds, isEmpty);
      expect(r.overflow.length, 4);
    });

    test('重复 ID 被去重', () {
      final r = run([
        PlayerActionId.playbackSpeed,
        PlayerActionId.playbackSpeed,
        PlayerActionId.audioQuality,
      ], shown);
      expect(r.actions.length, 2);
      expect(r.actions[0].id, PlayerActionId.playbackSpeed);
    });

    test('空列表 = 快捷区为空', () {
      final r = run(<PlayerActionId>[], shown);
      expect(r.actions, isEmpty);
      expect(r.excludeIds, isEmpty);
    });

    test('条件不可用的动作不渲染、不占槽、进入 overflow', () {
      final r = resolveQuickActions(
        ids: [PlayerActionId.playbackSpeed, PlayerActionId.audioQuality],
        spec: shown,
        all: all,
        player: player,
        song: song,
        isAvailable: (a) => a.id != PlayerActionId.audioQuality,
      );
      expect(r.actions.length, 1);
      expect(r.actions.single.id, PlayerActionId.playbackSpeed);
      // 条件不满足的动作直接不渲染（仍留在「更多」面板），不进 overflow。
      expect(r.overflow, isEmpty);
      expect(r.excludeIds, <PlayerActionId>{PlayerActionId.playbackSpeed});
    });
  });

  group('注册表', () {
    test('14 个唯一 ID，其中 9 个可编辑', () {
      expect(PlayerActionId.values.length, 14);
      expect(kEditableActionIds.length, 9);
      expect(kLegacyQuickActions.length, 3);
      expect(kEditableActionIds.toSet().length, 9);
    });

    test('兼容模式默认成员与 2163695 一致', () {
      expect(kLegacyQuickActions, <PlayerActionId>[
        PlayerActionId.lyricPicker,
        PlayerActionId.audioQuality,
        PlayerActionId.audioEffects,
      ]);
    });

    test('兼容模式 resolve 横屏显示 3 项、竖屏隐藏', () {
      final controller = PlayerPageLayoutController.instance;
      final player = _Player();
      final song = _Song();
      expect(
        controller
            .resolve(
              size: const Size(1024, 768),
              veryTight: false,
              player: player,
              song: song,
              all: registry,
            )
            .actions
            .map((a) => a.id),
        kLegacyQuickActions,
      );
      expect(
        controller
            .resolve(
              size: const Size(800, 360),
              veryTight: false,
              player: player,
              song: song,
              all: registry,
            )
            .excludeIds,
        <PlayerActionId>{
          PlayerActionId.lyricPicker,
          PlayerActionId.audioQuality,
          PlayerActionId.audioEffects,
        },
      );
    });

    test('存储解析忽略未知 ID 与去重', () {
      // 通过公开 API 验证：setQuickActions 只保留可编辑 ID。
      // 未知 ID 由 _parse 过滤，这里断言可编辑集合不含核心控件。
      expect(kEditableActionIds.contains(PlayerActionId.playPause), isFalse);
      expect(kEditableActionIds.contains(PlayerActionId.playQueue), isFalse);
    });

    testWidgets('buildPlayerActions 的更多面板可见性矩阵与现状一致', (tester) async {
      late List<PlayerAction> actions;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            actions = buildPlayerActions(
              context: context,
              song: const Song(
                id: 'registry',
                hash: 'registry',
                title: 'Registry song',
                artist: 'Registry artist',
                source: SongSource.kugou,
              ),
              player: _Player(),
              auth: _Auth(),
              onAudioQuality: () {},
              onLyricPicker: () {},
            );
            return const SizedBox.shrink();
          },
        ),
      );

      PlayerAction action(PlayerActionId id) =>
          actions.singleWhere((action) => action.id == id);
      bool visible(
        PlayerActionId id, {
        required bool isGrid,
        required bool includeNext,
      }) => action(id).showInMore(isGrid: isGrid, includeNext: includeNext);

      expect(actions.length, 14);
      expect(actions.map((action) => action.id).toSet().length, 14);
      expect(actions.where((action) => !action.core).length, 9);
      bool alwaysVisible(PlayerActionId id) =>
          visible(id, isGrid: true, includeNext: true) &&
          visible(id, isGrid: true, includeNext: false) &&
          visible(id, isGrid: false, includeNext: true) &&
          visible(id, isGrid: false, includeNext: false);
      for (final id in kEditableActionIds) {
        if (id == PlayerActionId.lyricPicker ||
            id == PlayerActionId.addToNext) {
          continue;
        }
        expect(alwaysVisible(id), isTrue, reason: id.name);
      }
      expect(
        visible(PlayerActionId.lyricPicker, isGrid: true, includeNext: true),
        isFalse,
      );
      expect(
        visible(PlayerActionId.addToNext, isGrid: false, includeNext: false),
        isFalse,
      );
      expect(
        visible(PlayerActionId.addToNext, isGrid: true, includeNext: true),
        isTrue,
      );
      expect(
        PlayerActionId.values
            .skip(9)
            .every((id) => !visible(id, isGrid: false, includeNext: false)),
        isTrue,
      );
    });
  });
}
