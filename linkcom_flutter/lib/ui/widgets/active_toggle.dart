import 'package:flutter/material.dart';

/// 固定尺寸的“激活”指示块: 激活时填充主题色(无 √ 勾选图标), 不激活时仅描边。
/// 宽度恒定, 不会因状态切换而改变尺寸。
class ActiveToggle extends StatelessWidget {
  final bool active;
  final ValueChanged<bool>? onChanged;
  final double size;

  const ActiveToggle({
    super.key,
    required this.active,
    this.onChanged,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!active),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: active ? Colors.green.withValues(alpha: 0.18) : Colors.transparent,
          border: Border.all(
            color: active ? Colors.green.shade600 : c.outline.withValues(alpha: 0.6),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}
