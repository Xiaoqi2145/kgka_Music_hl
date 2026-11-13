import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/widgets/player_page_actions.dart';
import 'player_controller.dart';
import '../models/music_models.dart';

/// 快捷区宿主类型。竖屏位置尚未设计，先以 portraitTbd 占位；接入时只需
/// 换一个 [QuickActionPlacement] 实现并在竖屏页面加一个宿主分支。
enum QuickActionHost { belowControls, portraitTbd }

/// 某一屏幕尺寸下快捷区的显示策略。
class QuickActionPlacementSpec {
  const QuickActionPlacementSpec({
    required this.show,
    required this.maxSlots,
    required this.host,
  });

  final bool show;
  final int maxSlots;
  final QuickActionHost host;
}

/// 「在哪些屏幕显示 / 显示在哪 / 最多几个槽位」的可替换策略接口。
abstract interface class QuickActionPlacement {
  const QuickActionPlacement();

  QuickActionPlacementSpec resolve(Size size, {required bool veryTight});
}

/// 一期策略：仅横屏显示快捷区；竖屏暂不增加（接口已留）。
class LandscapeOnlyPlacement implements QuickActionPlacement {
  const LandscapeOnlyPlacement();

  @override
  QuickActionPlacementSpec resolve(Size size, {required bool veryTight}) {
    final landscape = size.width > size.height;
    if (!landscape) {
      return const QuickActionPlacementSpec(
        show: false,
        maxSlots: 0,
        host: QuickActionHost.portraitTbd,
      );
    }
    if (veryTight) {
      return const QuickActionPlacementSpec(
        show: false,
        maxSlots: 0,
        host: QuickActionHost.belowControls,
      );
    }
    final tablet = size.shortestSide >= 600;
    return QuickActionPlacementSpec(
      show: true,
      maxSlots: tablet ? 5 : 3,
      host: QuickActionHost.belowControls,
    );
  }
}

/// 一次解析的结果：快捷区渲染什么、「更多」面板要剔除什么。
class QuickActionResolution {
  const QuickActionResolution({
    required this.show,
    required this.maxSlots,
    required this.actions,
    required this.overflow,
  });

  factory QuickActionResolution.hidden() => const QuickActionResolution(
    show: false,
    maxSlots: 0,
    actions: <PlayerAction>[],
    overflow: <PlayerAction>[],
  );

  final bool show;
  final int maxSlots;

  /// 最终真正渲染出来的动作（已过滤条件 / core，并按容量截断）。
  final List<PlayerAction> actions;

  /// 因容量或条件回落「更多」面板的动作。
  final List<PlayerAction> overflow;

  /// 只取「最终真正渲染」的集合；不能取用户保存的全部选择。
  Set<PlayerActionId> get excludeIds => actions.map((a) => a.id).toSet();
}

/// 纯函数：把有序 ID 列表解析成实际渲染结果，便于 L1 单测。
QuickActionResolution resolveQuickActions({
  required List<PlayerActionId> ids,
  required List<PlayerAction> all,
  required PlayerController player,
  required Song song,
  required QuickActionPlacementSpec spec,
  bool Function(PlayerAction action)? isAvailable,
}) {
  final byId = <PlayerActionId, PlayerAction>{for (final a in all) a.id: a};
  final eligible = <PlayerAction>[];
  for (final id in ids) {
    final action = byId[id];
    if (action == null || action.core) continue; // 忽略未知 ID 与核心控件
    final usable = isAvailable?.call(action) ?? action.available(player, song);
    if (!usable) continue; // 条件不满足则回落「更多」
    if (!eligible.any((a) => a.id == id)) eligible.add(action);
  }
  if (!spec.show || spec.maxSlots <= 0) {
    return QuickActionResolution(
      show: false,
      maxSlots: spec.maxSlots,
      actions: const <PlayerAction>[],
      overflow: eligible,
    );
  }
  final shown = eligible.take(spec.maxSlots).toList();
  final overflow = eligible.skip(spec.maxSlots).toList();
  return QuickActionResolution(
    show: true,
    maxSlots: spec.maxSlots,
    actions: shown,
    overflow: overflow,
  );
}

/// 播放页快捷区配置控制器。
///
/// 沿用 `ThemeController.instance` 的全局单例先例，避免把新参数沿
/// main.dart → app_shell → mini_player → PlayerPage 整条链透传。
/// 静态 [instance] 惰性创建，Widget 测试无需先装配也不会空指针。
class PlayerPageLayoutController extends ChangeNotifier {
  PlayerPageLayoutController._();

  static PlayerPageLayoutController? _instance;
  static PlayerPageLayoutController get instance =>
      _instance ??= PlayerPageLayoutController._();

  static const String prefsKey = 'settings.player_quick_actions';

  QuickActionPlacement placement = const LandscapeOnlyPlacement();

  bool _hasCustomized = false;
  List<PlayerActionId> _saved = const <PlayerActionId>[];

  /// 键缺失时为兼容模式，行为与改造前完全一致。
  bool get hasCustomized => _hasCustomized;

  List<PlayerActionId> get saved => List.unmodifiable(_saved);

  Future<void> load([SharedPreferences? preferences]) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      final raw = prefs.getStringList(prefsKey);
      _hasCustomized = raw != null;
      _saved = _parse(raw);
      notifyListeners();
    } catch (error) {
      debugPrint('[KA Music][quick-actions] load failed: $error');
      _hasCustomized = false;
      _saved = const <PlayerActionId>[];
      notifyListeners();
    }
  }

  Future<void> setQuickActions(
    List<PlayerActionId> actions, {
    required SharedPreferences preferences,
  }) async {
    final filtered = actions
        .where((id) => kEditableActionIds.contains(id))
        .toSet()
        .toList(growable: false);
    _saved = filtered;
    _hasCustomized = true;
    notifyListeners();
    try {
      await preferences.setStringList(
        prefsKey,
        filtered.map((id) => id.name).toList(),
      );
    } catch (error) {
      // 写失败不回滚内存态：本次会话仍即时生效，下次启动回到上次成功值。
      debugPrint('[KA Music][quick-actions] save failed: $error');
    }
  }

  /// 恢复默认 = 删除键回到兼容模式（真正回滚，而非写入三个默认 ID）。
  Future<void> resetToDefault({required SharedPreferences preferences}) async {
    _saved = const <PlayerActionId>[];
    _hasCustomized = false;
    notifyListeners();
    try {
      await preferences.remove(prefsKey);
    } catch (error) {
      debugPrint('[KA Music][quick-actions] reset failed: $error');
    }
  }

  /// 供宿主快捷行与「更多」面板共用；[override] 为编辑态草稿。
  QuickActionResolution resolve({
    required Size size,
    required bool veryTight,
    required PlayerController player,
    required Song song,
    required List<PlayerAction> all,
    List<PlayerActionId>? override,
  }) {
    final spec = placement.resolve(size, veryTight: veryTight);
    if (!_hasCustomized && override == null) {
      // 兼容模式走独立早期分支，不经过新策略矩阵：仅平板横屏显示 3 个。
      final tabletLandscape =
          size.width > size.height && size.shortestSide >= 600;
      return resolveQuickActions(
        ids: kLegacyQuickActions,
        spec: QuickActionPlacementSpec(
          show: tabletLandscape,
          maxSlots: 3,
          host: QuickActionHost.belowControls,
        ),
        all: all,
        player: player,
        song: song,
      );
    }
    return resolveQuickActions(
      ids: override ?? _saved,
      spec: spec,
      all: all,
      player: player,
      song: song,
    );
  }

  static List<PlayerActionId> _parse(List<String>? raw) {
    if (raw == null) return const <PlayerActionId>[];
    final values = <String>{};
    final result = <PlayerActionId>[];
    for (final name in raw) {
      if (!values.add(name)) continue; // 去重
      for (final id in kEditableActionIds) {
        if (id.name == name) {
          result.add(id);
          break;
        }
      }
      // 未知 ID 直接忽略（版本降级 / 手改 / 未来新增动作）
    }
    return result;
  }
}
