import 'package:flutter/material.dart';
import '../../serial/serial_config.dart';

// 共享端/链接端共用的串口参数编辑器: 任意一端修改即回调 onApply, 由上层负责持久化与中继同步
class SerialConfigEditor extends StatefulWidget {
  final SerialConfig initialCfg;
  final AggConfig initialAgg;
  final void Function(SerialConfig, AggConfig) onApply;
  final bool enabled;
  const SerialConfigEditor({
    super.key,
    required this.initialCfg,
    required this.initialAgg,
    required this.onApply,
    this.enabled = true,
  });
  @override
  State<SerialConfigEditor> createState() => _SerialConfigEditorState();
}

class _SerialConfigEditorState extends State<SerialConfigEditor> {
  static const List<int> _bauds = [
    1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600
  ];
  static const List<int> _dataBits = [5, 6, 7, 8];
  // 停止位: 与 Web 版一致 (1 / 1.5 / 2), 用字符串编码承载 1.5
  static const List<(String, String)> _stopBits = [
    ('1', '1'),
    ('1.5', '1.5'),
    ('2', '2'),
  ];
  static const List<(String, String)> _parity = [
    ('none', 'None(无校验)'),
    ('odd', 'Odd(奇校验)'),
    ('even', 'Even(偶校验)'),
    ('mark', 'Mark(标记)'),
    ('space', 'Space(空位)'),
  ];
  // 流控: 与 Web 版一致 (None/XON-XOFF/RTS-CTS)
  static const List<(String, String)> _flow = [
    ('none', 'None(无)'),
    ('software', 'XON/XOFF(软件流控)'),
    ('hardware', 'RTS/CTS(硬件流控)'),
  ];

  static String _stopCode(StopBits s) =>
      s == StopBits.onePointFive ? '1.5' : (s == StopBits.two ? '2' : '1');
  static StopBits _stopEnum(String v) =>
      v == '1.5' ? StopBits.onePointFive : (v == '2' ? StopBits.two : StopBits.one);

  late SerialConfig _cfg;
  late AggConfig _agg;

  @override
  void initState() {
    super.initState();
    _cfg = widget.initialCfg;
    _agg = widget.initialAgg;
  }

  @override
  void didUpdateWidget(covariant SerialConfigEditor old) {
    super.didUpdateWidget(old);
    _cfg = widget.initialCfg;
    _agg = widget.initialAgg;
  }

  // 编码/聚合/缓冲已移至终端视图, 此处仅编辑串口参数, 聚合配置原样透传
  void _emit(SerialConfig cfg) {
    _cfg = cfg;
    widget.onApply(cfg, _agg);
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _num('波特率', _cfg.baudRate, _bauds, en,
                (v) => _emit(_cfg.copyWith(baudRate: v))),
            _num('数据位', _cfg.dataBits, _dataBits, en,
                (v) => _emit(_cfg.copyWith(dataBits: v))),
            _str('停止位', _stopCode(_cfg.stopBits), _stopBits, en,
                (v) => _emit(_cfg.copyWith(stopBits: _stopEnum(v)))),
            _str('校验', _cfg.parity.name, _parity, en,
                (v) => _emit(_cfg.copyWith(parity: Parity.values.firstWhere((e) => e.name == v)))),
            _str('流控', _cfg.flowControl.name, _flow, en,
                (v) => _emit(_cfg.copyWith(flowControl: FlowControl.values.firstWhere((e) => e.name == v)))),
          ],
        ),
      ],
    );
  }

  // 按标题文字宽度计算最小宽度, 保证浮动标题完整显示, 框宽不超出必要范围
  double _labelMinWidth(String label) {
    final tp = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width + 40; // 下拉箭头(~24) + 左右内边距余量
  }

  // 名称用 labelText 浮在框上(与房间码一致: 有值时名称在框上, 内容在框内)
  // 框宽 = max(标题宽度, 内容宽度): 刚好够显示标题与输入内容, 内容长了自动扩展
  Widget _num<T>(String label, T value, List<T> items, bool en, void Function(T) onChanged) =>
      IntrinsicWidth(
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: _labelMinWidth(label)),
          child: DropdownButtonFormField<T>(
            isExpanded: false,
            decoration: InputDecoration(labelText: label, isDense: true),
            value: items.contains(value) ? value : items.first,
            items: items
                .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                .toList(),
            onChanged: en
                ? (v) {
                    if (v != null) onChanged(v);
                  }
                : null,
          ),
        ),
      );

  Widget _str(String label, String value, List<(String, String)> items, bool en,
      void Function(String) onChanged) {
    final v = items.any((e) => e.$1 == value) ? value : items.first.$1;
    return IntrinsicWidth(
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: _labelMinWidth(label)),
        child: DropdownButtonFormField<String>(
          isExpanded: false,
          decoration: InputDecoration(labelText: label, isDense: true),
          value: v,
          items: items
              .map((e) => DropdownMenuItem(value: e.$1, child: Text(e.$1)))
              .toList(),
          onChanged: en
              ? (x) {
                  if (x != null) onChanged(x);
                }
              : null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
