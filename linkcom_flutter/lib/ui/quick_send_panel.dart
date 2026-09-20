import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _uid() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

// 文件名用时间戳: yyyyMMdd_HHmmss
String _stamp() {
  final d = DateTime.now();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${p(d.month)}${p(d.day)}_${p(d.hour)}${p(d.minute)}${p(d.second)}';
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

// 单条快速发送项 (对齐 Web 端 quick.js)
class QuickItem {
  String id;
  String name;
  bool hex;
  bool crlf;
  String data;
  int delay; // 本条发送后延迟(ms)
  bool checked; // 是否参与顺序/轮询
  QuickItem({
    required this.id,
    required this.name,
    this.hex = false,
    this.crlf = true,
    this.data = '',
    this.delay = 0,
    this.checked = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hex': hex,
        'crlf': crlf,
        'data': data,
        'delay': delay,
        'checked': checked,
      };

  factory QuickItem.fromJson(Map<String, dynamic> j) => QuickItem(
        id: j['id']?.toString() ?? _uid(),
        name: (j['name'] ?? '未命名').toString(),
        hex: j['hex'] == true,
        crlf: j['crlf'] != false,
        data: (j['data'] ?? '').toString(),
        delay: _toInt(j['delay']).clamp(0, 1 << 30),
        checked: j['checked'] != false,
      );
}

// 快速发送面板: 增删改 + 单发/顺序/轮询 + 延迟 + 持久化 (移植 Web 端 quick.js)
class QuickSendPanel extends StatefulWidget {
  // 返回是否发送成功: 失败(串口报错/断开等)时顺序/轮询会自动停止
  final Future<bool> Function(QuickItem) onSend;
  final String storageKey;
  const QuickSendPanel({super.key, required this.onSend, this.storageKey = 'linkcom_quicksend'});
  @override
  State<QuickSendPanel> createState() => _QuickSendPanelState();
}

class _QuickSendPanelState extends State<QuickSendPanel> {
  List<QuickItem> _items = [];
  bool _expanded = true;
  Timer? _runTimer;
  String _runMode = 'stop'; // stop | seq | poll
  int _runIndex = 0;
  List<QuickItem> _runList = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(widget.storageKey);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map && j['items'] is List) {
          final list = (j['items'] as List)
              .whereType<Map>()
              .map((e) => QuickItem.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (mounted) setState(() => _items = list);
        }
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          widget.storageKey,
          jsonEncode({'version': 1, 'items': _items.map((e) => e.toJson()).toList()}));
    } catch (_) {}
  }

  void _hint(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 发送 ----------
  Future<bool> _sendOne(QuickItem it) => widget.onSend(it);

  void _runSeq() {
    _stopRun();
    _runList = _items.where((x) => x.checked).toList();
    if (_runList.isEmpty) {
      _hint('没有勾选的条目, 无法顺序发送');
      return;
    }
    setState(() {
      _runMode = 'seq';
      _runIndex = 0;
    });
    _step();
  }

  void _runPoll() {
    _stopRun();
    _runList = _items.where((x) => x.checked).toList();
    if (_runList.isEmpty) {
      _hint('没有勾选的条目, 无法轮询发送');
      return;
    }
    setState(() {
      _runMode = 'poll';
      _runIndex = 0;
    });
    _step();
  }

  Future<void> _step() async {
    if (_runMode == 'stop') return;
    if (_runIndex >= _runList.length) {
      if (_runMode == 'poll') {
        _runIndex = 0;
      } else {
        _stopRun();
        _hint('顺序发送完成');
        return;
      }
    }
    final it = _runList[_runIndex];
    final ok = await _sendOne(it);
    if (_runMode == 'stop') return; // 发送期间被手动停止
    if (!ok) {
      // 串口报错/断开导致发送失败: 立即停止, 杜绝顺序/轮询空转卡死
      _stopRun();
      _hint('发送失败, 已自动停止: ${it.name}');
      return;
    }
    _runIndex++;
    if (mounted) setState(() {});
    final gap = it.delay.clamp(0, 600000);
    _runTimer = Timer(Duration(milliseconds: gap), _step);
  }

  void _stopRun() {
    _runTimer?.cancel();
    _runTimer = null;
    if (!mounted) return;
    setState(() {
      _runMode = 'stop';
      _runIndex = 0;
      _runList = [];
    });
  }

  // ---------- 增删改 ----------
  void _remove(QuickItem it) {
    setState(() => _items.remove(it));
    _save();
  }

  Future<void> _openEditor(QuickItem? item) async {
    // 控制器交给对话框自己的 State 持有与释放(不能在 showDialog 返回后立刻 dispose,
    // 否则对话框退场时还会重建一次 -> "A TextEditingController was used after being disposed")
    final res = await showDialog<QuickItem>(
      context: context,
      builder: (_) => _QuickEditor(item: item),
    );
    if (res == null || !mounted) return;
    setState(() {
      if (item == null) {
        _items.add(res);
      } else {
        item
          ..name = res.name
          ..data = res.data
          ..hex = res.hex
          ..crlf = res.crlf
          ..delay = res.delay;
      }
    });
    _save();
  }

  // ---------- 导入/导出 (本地文件 JSON) ----------
  Future<void> _export() async {
    final text = const JsonEncoder.withIndent('  ')
        .convert({'version': 1, 'items': _items.map((e) => e.toJson()).toList()});
    String? savedPath;
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: '导出快速发送',
        fileName: 'linkcom_quick_${_stamp()}.json',
        bytes: utf8.encode(text),
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (uri == null) return; // 取消
      savedPath = uri.toFilePath();
    } on UnimplementedError {
      savedPath = null; // 平台未实现 saveFile, 转选目录兜底
    } catch (e) {
      _hint('导出失败: $e');
      return;
    }
    if (savedPath == null) {
      try {
        final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
        if (dir == null) return;
        final file =
            File('$dir${Platform.pathSeparator}linkcom_quick_${_stamp()}.json');
        await file.writeAsBytes(utf8.encode(text));
        savedPath = file.path;
      } catch (e) {
        _hint('导出失败: $e');
        return;
      }
    }
    _hint('已导出到: $savedPath');
  }

  Future<void> _import() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final file = files.isEmpty ? null : files.first;
      if (file == null) return; // 取消
      final raw = utf8.decode(await file.readAsBytes());
      final j = jsonDecode(raw);
      final list = (j is Map ? j['items'] : j);
      if (list is! List) throw Exception('格式不正确: 缺少 items 数组');
      final items = list
          .whereType<Map>()
          .map((e) => QuickItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (items.isEmpty) throw Exception('没有条目');
      setState(() => _items = items);
      _save();
      _hint('已导入 ${items.length} 条');
    } catch (e) {
      _hint('导入失败: $e');
    }
  }

  void _clearAll() {
    if (_items.isEmpty) return;
    _stopRun();
    setState(() => _items = []);
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final checkedCount = _items.where((x) => x.checked).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(_expanded ? Icons.expand_more : Icons.chevron_right, size: 18),
                  const SizedBox(width: 4),
                  const Text('快速发送',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _items.isEmpty
                          ? '暂无条目, 点击「添加」'
                          : '共 ${_items.length} 条, 已勾选 $checkedCount 条',
                      style: TextStyle(
                          fontSize: 11, color: c.onSurface.withValues(alpha: 0.6)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _runState(c),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              LayoutBuilder(builder: (ctx, cons) {
                final narrow = cons.maxWidth <= 460;
                // 窄屏: 按钮适当缩放(更紧凑 padding/字号), 少占行
                final cs = narrow
                    ? const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        padding: WidgetStatePropertyAll(
                            EdgeInsets.symmetric(horizontal: 10)),
                        textStyle:
                            WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                      )
                    : null;
                final left = Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    FilledButton.tonalIcon(
                        style: cs,
                        onPressed: () => _openEditor(null),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('添加')),
                    OutlinedButton(
                        style: cs, onPressed: _runSeq, child: const Text('顺序发送')),
                    OutlinedButton(
                        style: cs, onPressed: _runPoll, child: const Text('轮询发送')),
                    OutlinedButton(
                        style: cs, onPressed: _stopRun, child: const Text('停止')),
                  ],
                );
                final right = Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.end,
                  children: [
                    TextButton(style: cs, onPressed: _export, child: const Text('导出')),
                    TextButton(style: cs, onPressed: _import, child: const Text('导入')),
                    TextButton(style: cs, onPressed: _clearAll, child: const Text('清空')),
                  ],
                );
                // 窄屏(手机): 上下堆叠, 避免左侧按钮被右侧挤成竖排
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      left,
                      const SizedBox(height: 4),
                      Align(alignment: Alignment.centerRight, child: right),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: 8),
                    right,
                  ],
                );
              }),
              const SizedBox(height: 4),
              if (_items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('暂无快速发送条目, 点击「添加」新建。',
                      style: TextStyle(
                          fontSize: 12, color: c.onSurface.withValues(alpha: 0.55))),
                )
              else
                ..._items.map((it) => _itemRow(it, c)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _runState(ColorScheme c) {
    late final String txt;
    late final Color col;
    if (_runMode == 'seq') {
      txt = '顺序中($_runIndex/${_runList.length})';
      col = c.primary;
    } else if (_runMode == 'poll') {
      txt = '轮询中($_runIndex)';
      col = const Color(0xFF7FE7FF);
    } else {
      txt = '空闲';
      col = c.onSurface.withValues(alpha: 0.5);
    }
    return Text(txt, style: TextStyle(fontSize: 11, color: col));
  }

  Widget _itemRow(QuickItem it, ColorScheme c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Checkbox(
              value: it.checked,
              visualDensity: VisualDensity.compact,
              onChanged: (v) {
                setState(() => it.checked = v ?? false);
                _save();
              },
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名称 + 类型(文本/HEX): 类型紧跟名称之后
                Row(
                  children: [
                    Flexible(
                      child: Text(it.name,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (it.hex ? c.tertiary : c.primary)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(it.hex ? 'HEX' : '文本',
                          style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: it.hex ? c.tertiary : c.primary)),
                    ),
                  ],
                ),
                Text(it.data,
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: c.onSurface.withValues(alpha: 0.6)),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 延迟: 内容多时自动扩展宽度
          IntrinsicWidth(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 62),
              child: TextFormField(
                key: ValueKey('delay_${it.id}'), // 键不含 delay, 避免输入时重建丢焦点
                initialValue: '${it.delay}',
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 11),
                decoration: const InputDecoration(
                    isDense: true,
                    labelText: '延迟',
                    suffixText: 'ms',
                    labelStyle: TextStyle(fontSize: 10)),
                // 修改即生效(无需回车): 轮询/顺序会立即采用新延迟; 越界值在发送时 clamp
                onChanged: (v) {
                  it.delay = int.tryParse(v.trim()) ?? 0;
                  _save();
                },
              ),
            ),
          ),
          // 更多(位于延迟之后)
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              if (v == 'edit') _openEditor(it);
              if (v == 'del') _remove(it);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'del', child: Text('删除')),
            ],
          ),
          // 发送(置于最末)
          IconButton(
            tooltip: '发送',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.send, size: 18),
            onPressed: () => _sendOne(it),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _runTimer?.cancel();
    super.dispose();
  }
}

// 快速发送 添加/编辑 对话框: 控制器由本 State 持有, 随对话框真正销毁而释放。
// 关键: 不能在 showDialog 返回后立刻 dispose —— 对话框退场动画期间仍会重建一次,
// 会抛 "A TextEditingController was used after being disposed"(并级联 _dependents.isEmpty)。
class _QuickEditor extends StatefulWidget {
  final QuickItem? item;
  const _QuickEditor({this.item});
  @override
  State<_QuickEditor> createState() => _QuickEditorState();
}

class _QuickEditorState extends State<_QuickEditor> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _dataCtl;
  late final TextEditingController _delayCtl;
  late bool _hex;
  late bool _crlf;

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    _nameCtl = TextEditingController(text: it?.name ?? '');
    _dataCtl = TextEditingController(text: it?.data ?? '');
    _delayCtl = TextEditingController(text: '${it?.delay ?? 500}');
    _hex = it?.hex ?? false;
    _crlf = it?.crlf ?? true;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _dataCtl.dispose();
    _delayCtl.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _nameCtl.text.trim().isEmpty ? '未命名' : _nameCtl.text.trim();
    final delay = int.tryParse(_delayCtl.text.trim()) ?? 0;
    Navigator.pop(
        context,
        QuickItem(
          id: widget.item?.id ?? _uid(),
          name: name,
          data: _dataCtl.text,
          hex: _hex,
          crlf: _crlf,
          delay: delay < 0 ? 0 : delay,
          checked: widget.item?.checked ?? true,
        ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? '添加快速发送' : '编辑快速发送'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: _nameCtl,
                decoration: const InputDecoration(labelText: '名称')),
            const SizedBox(height: 12), // 与下方数据框拉开距离, 避免「数据」浮动标题与名称框重叠
            TextField(
              controller: _dataCtl,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                  labelText: _hex ? '数据 (HEX, 如 AA BB CC)' : '数据 (文本)'),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _hex,
              onChanged: (v) => setState(() => _hex = v ?? false),
              title: const Text('HEX 发送'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: _crlf,
              onChanged: (v) => setState(() => _crlf = v ?? false),
              title: const Text('文本末尾追加 \\r\\n'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
            TextField(
              controller: _delayCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '本条后延迟(ms)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _confirm, child: const Text('保存')),
      ],
    );
  }
}
