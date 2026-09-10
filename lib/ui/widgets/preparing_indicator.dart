import 'package:flutter/material.dart';

/// 音源正在解析或替换（尚未提交）时的加载指示器。
///
/// 提交之前界面没有其它中间态，点击是否生效只能靠它表达。
class PreparingIndicator extends StatelessWidget {
  const PreparingIndicator({
    super.key,
    required this.color,
    this.size = 14,
    this.strokeWidth = 2,
  });

  final Color color;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        strokeCap: StrokeCap.round,
        color: color,
      ),
    );
  }
}
