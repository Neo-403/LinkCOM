import 'package:flutter/material.dart';

/// 可折叠配置面板: 标题栏点击展开/收起, [collapseWhen] 由 false 变 true 时自动收起。
/// 展开态用 [AnimatedCrossFade], 子节点始终挂载(保留内部编辑状态)。
/// 注意: 不含 ListView, 避免与内部 Tooltip 嫁接触发 Windows AXTree 报错 (flutter#182444)。
class CollapsiblePanel extends StatefulWidget {
  final String title;
  final String? summary;
  final Widget child;
  final bool initiallyExpanded;
  final bool collapseWhen;
  final EdgeInsetsGeometry? childPadding;
  const CollapsiblePanel({
    super.key,
    required this.title,
    this.summary,
    required this.child,
    this.initiallyExpanded = true,
    this.collapseWhen = false,
    this.childPadding,
  });
  @override
  State<CollapsiblePanel> createState() => _CollapsiblePanelState();
}

class _CollapsiblePanelState extends State<CollapsiblePanel> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded && !widget.collapseWhen;
  }

  @override
  void didUpdateWidget(covariant CollapsiblePanel old) {
    super.didUpdateWidget(old);
    if (widget.collapseWhen && !old.collapseWhen) {
      setState(() => _expanded = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 标题保持固有宽度(不再被摘要挤压成竖排); 摘要占剩余宽度并按需省略
                  Text(widget.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  if (widget.summary != null && widget.summary!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(widget.summary!,
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: widget.childPadding ??
                  const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: widget.child,
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}
