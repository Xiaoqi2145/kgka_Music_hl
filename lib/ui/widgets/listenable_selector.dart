import 'package:flutter/widgets.dart';

/// 只在**派生值**变化时重建的订阅部件。
///
/// [ListenableBuilder] / [AnimatedBuilder] 在被监听对象每次通知时都会重建
/// 子树。本项目的 [PlayerController] 与 [AuthController] 通知点极密（播放进度
/// 之外的下载进度、歌词、定时器、音量均衡都会 `notifyListeners()`），列表里
/// 每一行如果直接订阅整个控制器，一次无关的通知就会把整屏可见行全部重跑。
///
/// 用法与 Flutter 生态里常见的 `Selector` 一致：
/// ```dart
/// ListenableSelector<PlayerController, _RowActivity>(
///   listenable: player,
///   selector: (_, player) => _RowActivity(
///     active: player.currentSong?.hash == song.hash,
///   ),
///   builder: (context, activity) => ...,
/// )
/// ```
///
/// [selector] 返回的值需要实现 `==`（建议用不可变值类 + `Object.hash`）。
class ListenableSelector<T extends Listenable, S> extends StatefulWidget {
  const ListenableSelector({
    super.key,
    required this.listenable,
    required this.selector,
    required this.builder,
  });

  final T listenable;

  /// 由被监听对象派生出一个可比较的值。
  final S Function(BuildContext context, T listenable) selector;

  /// 只在 [selector] 的结果变化时被调用。
  final Widget Function(BuildContext context, S value) builder;

  @override
  State<ListenableSelector<T, S>> createState() =>
      _ListenableSelectorState<T, S>();
}

class _ListenableSelectorState<T extends Listenable, S>
    extends State<ListenableSelector<T, S>> {
  late S _value;

  @override
  void initState() {
    super.initState();
    _value = widget.selector(context, widget.listenable);
    widget.listenable.addListener(_handleChange);
  }

  @override
  void didUpdateWidget(covariant ListenableSelector<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _value = widget.selector(context, widget.listenable);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_handleChange);
      widget.listenable.addListener(_handleChange);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_handleChange);
    super.dispose();
  }

  void _handleChange() {
    if (!mounted) return;
    final next = widget.selector(context, widget.listenable);
    if (next == _value) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}