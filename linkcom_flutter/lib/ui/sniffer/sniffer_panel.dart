import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../sniffer/sniffer_controller.dart';
import '../widgets/active_toggle.dart';

// 文件名用时间戳: yyyyMMdd_HHmmss
String _stamp() {
  final d = DateTime.now();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${p(d.month)}${p(d.day)}_${p(d.hour)}${p(d.minute)}${p(d.second)}';
}

// 快速匹配面板: 规则列表 + 命中记录(去重/排序/高亮) + 规则编辑 (移植 Web 端 sniffer.js)
class SnifferPanel extends StatefulWidget {
  final String encoding; // 终端编码(utf8/gbk), 供 dispEnc='text' 解码
  const SnifferPanel({super.key, this.encoding = 'utf8'});
  @override
  State<SnifferPanel> createState() => _SnifferPanelState();
}

class _SnifferPanelState extends State<SnifferPanel> {
  bool _expanded = false;

  String _ts(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }

  String _modeLabel(String m) => m == 'keyword' ? '匹配关键字' : '提取';
  String _dirLabel(String d) => d == 'send' ? '仅发送' : (d == 'both' ? '全部' : '仅接收');

  @override
  Widget build(BuildContext context) {
    final sn = context.watch<SnifferController>();
    final termEnc = widget.encoding;
    final c = Theme.of(context).colorScheme;
    // 每条规则去重/排序后的记录; 摘要「记录 N」按聚合条数统计(与 Web/桌面端一致, 而非原始命中数)
    final aggMap = <String, List<SnifferAgg>>{
      for (final r in sn.rules) r.id: sn.aggsFor(r, termEnc),
    };
    final totalRec = aggMap.values.fold<int>(0, (s, l) => s + l.length);
    final enCount = sn.rules.where((r) => r.enabled).length;

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
                  const Text('快速匹配', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('规则 $enCount/${sn.rules.length} · 记录 $totalRec',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: c.onSurface.withValues(alpha: 0.6))),
                  ),
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
                        onPressed: () => _openEditor(sn, null),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('添加规则')),
                    OutlinedButton(
                        style: cs,
                        onPressed: () => _confirmClearRecords(sn),
                        child: const Text('清空记录')),
                  ],
                );
                final right = Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.end,
                  children: [
                    TextButton(
                        style: cs,
                        onPressed: () => _exportRules(sn),
                        child: const Text('导出规则')),
                    TextButton(
                        style: cs,
                        onPressed: () => _importRules(sn),
                        child: const Text('导入规则')),
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
              if (sn.rules.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('暂无规则, 点击「添加规则」新建。',
                      style: TextStyle(
                          fontSize: 12, color: c.onSurface.withValues(alpha: 0.55))),
                )
              else
                ...sn.rules.map((r) =>
                    _ruleBlock(sn, r, aggMap[r.id] ?? const [], termEnc, c)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _ruleBlock(SnifferController sn, SnifferRule r, List<SnifferAgg> aggs,
      String termEnc, ColorScheme c) {
    final collapsed = sn.collapsed[r.id] == true;
    final lenFilter = r.lenVal != 0 ? ' 长${r.lenOp}${r.lenVal}' : '';
    final dispLabel = r.dispEnc == 'hex' ? 'HEX' : '文本';
    // meta 文案与 Web 端 renderRules 完全一致(关键字模式含 匹:matchEnc→显:)
    final meta = r.mode == 'keyword'
        ? '${_dirLabel(r.dir)} | 匹配:${r.keyword.isEmpty ? '-' : r.keyword}$lenFilter'
            ' | 匹:${r.matchEnc}→显:$dispLabel'
        : '${_dirLabel(r.dir)} | 偏移:${r.startOffset} 取${r.length}字节$lenFilter'
            ' | 显:$dispLabel';
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border.all(color: c.outline.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                InkWell(
                  onTap: () => sn.toggleCollapsed(r.id),
                  child: Icon(collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 18),
                ),
                ActiveToggle(
                  active: r.enabled,
                  onChanged: (v) => sn.setEnabled(r, v),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    // Web .sn-badge: 启用=强调色实底, 未启用=透明底 + 描边
                    color: r.enabled ? c.primary : Colors.transparent,
                    border: Border.all(color: c.outline.withValues(alpha: 0.4)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(_modeLabel(r.mode),
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: r.enabled
                              ? c.onPrimary
                              : c.onSurface.withValues(alpha: 0.6))),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: r.enabled
                                  ? null
                                  : c.onSurface.withValues(alpha: 0.5))),
                      Text('$meta${r.accumulate ? ' | 累积' : ''}',
                          style: TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: c.onSurface.withValues(alpha: 0.55)),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                // Web .sn-rec-count: 数量 + 去重方式后缀
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.onSurface.withValues(alpha: 0.06),
                    border: Border.all(color: c.outline.withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                      '${aggs.length}${r.dedupType == 'match' ? ' (匹配去重)' : r.dedupType == 'all' ? ' (全匹配去重)' : ''}',
                      style: TextStyle(
                          fontSize: 10,
                          color: c.onSurface.withValues(alpha: 0.6))),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (v) {
                    if (v == 'edit') _openEditor(sn, r);
                    if (v == 'exp') _exportRuleRecords(sn, r, termEnc);
                    if (v == 'clr') sn.clearRecords(r.id);
                    if (v == 'del') sn.removeRule(r.id);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'exp', child: Text('导出记录')),
                    PopupMenuItem(value: 'clr', child: Text('清空记录')),
                    PopupMenuItem(value: 'del', child: Text('删除规则')),
                  ],
                ),
              ],
            ),
          ),
          if (!collapsed)
            if (aggs.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 0, 6, 6),
                child: Text('无匹配记录',
                    style: TextStyle(
                        fontSize: 11, color: c.onSurface.withValues(alpha: 0.45))),
              )
            else
              // Web 端展示全部聚合记录(不设行数上限)
              ...aggs.map((a) => _recRow(sn, r, a, termEnc, c)),
        ],
      ),
    );
  }

  Widget _recRow(
      SnifferController sn, SnifferRule r, SnifferAgg a, String termEnc, ColorScheme c) {
    // 与 Web 端 recordValueHtml 一致:
    //  匹配去重(dedupType=='match') → 只显示命中段, 强调色 + 底色胶囊(.hl-val)
    //  其它 → 显示整帧(截断 48 字节 + …), 命中段在其中高亮
    final full = r.dedupType != 'match';
    final hlS = a.hlStart.clamp(0, a.raw.length);
    final hlE = a.hlEnd.clamp(hlS, a.raw.length);
    final enc = r.dispEnc == 'text' ? termEnc : r.dispEnc;
    final Widget valWidget;
    if (full) {
      valWidget = RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: c.onSurface.withValues(alpha: 0.75)),
          children: _frameByteSpans(a.raw, hlS, hlE, enc, c, max: 48),
        ),
      );
    } else {
      valWidget = Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: c.primary.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
            SnifferController.decodeField(
                a.raw.sublist(hlS, hlE), r.dispEnc, termEnc),
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: c.primary),
            overflow: TextOverflow.ellipsis),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 2, 6, 2),
      child: Row(
        children: [
          Text(_ts(a.lastTs),
              style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: c.onSurface.withValues(alpha: 0.45))),
          const SizedBox(width: 8),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: valWidget),
          ),
          if (a.count > 1)
            Text('×${a.count}',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    // Web .sn-rec-cnt 用 --warn
                    color: c.brightness == Brightness.dark
                        ? const Color(0xFFFBBF24)
                        : const Color(0xFFD97706))),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => _viewFrames(sn, r, a, termEnc),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('查看帧', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  // ---------- 查看帧 ----------
  void _viewFrames(SnifferController sn, SnifferRule r, SnifferAgg a, String termEnc) {
    final refs = a.refs.isEmpty ? <SnifferRecord>[] : a.refs;
    // 显示编码跟随规则设定(text 用终端编码), 与 Web 一致
    final enc = r.dispEnc == 'text' ? termEnc : r.dispEnc;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text('帧记录 (共 ${refs.length} 次) · 编码: $enc'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(refs.length, (i) {
                  final rec = refs[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 与 Web 端 viewFrames 一致: 时间戳 + #序号
                        Text('${_ts(rec.ts)} ',
                            style: TextStyle(
                                fontSize: 10,
                                color: c.onSurface.withValues(alpha: 0.5))),
                        Text('#${i + 1} ',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: c.onSurface.withValues(alpha: 0.5))),
                        Expanded(
                          child: RichText(
                              text: TextSpan(
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: c.onSurface),
                                  children: _frameByteSpans(
                                      rec.raw, rec.hlStart, rec.hlEnd, enc, c))),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        );
      },
    );
  }

  // 完整帧逐字节渲染: 命中段用强调色 + 底色高亮(与 Web 端 .hl 一致)
  // max>0 时截断到 max 字节并以 … 结尾(Web 端记录行上限 48 字节)
  List<TextSpan> _frameByteSpans(Uint8List raw, int hlS, int hlE, String enc,
      ColorScheme c, {int max = 0}) {
    final n = (max > 0 && raw.length > max) ? max : raw.length;
    final spans = <TextSpan>[];
    for (var i = 0; i < n; i++) {
      final inHl = i >= hlS && i < hlE;
      final String s;
      if (enc == 'hex') {
        s = '${raw[i].toRadixString(16).padLeft(2, '0').toUpperCase()} ';
      } else {
        final b = raw[i];
        s = (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '·';
      }
      spans.add(TextSpan(
        text: s,
        style: inHl
            ? TextStyle(
                color: c.primary,
                backgroundColor: c.primary.withValues(alpha: 0.18))
            : TextStyle(color: c.onSurface.withValues(alpha: 0.7)),
      ));
    }
    if (max > 0 && raw.length > max) {
      spans.add(TextSpan(
          text: enc == 'hex' ? ' …' : '…',
          style: TextStyle(color: c.onSurface.withValues(alpha: 0.5))));
    }
    return spans;
  }

  // ---------- 规则编辑器 ----------
  Future<void> _openEditor(SnifferController sn, SnifferRule? rule) async {
    final r = rule ??
        SnifferRule(id: DateTime.now().microsecondsSinceEpoch.toRadixString(36), name: '');
    final nameCtl = TextEditingController(text: r.name);
    final kwCtl = TextEditingController(text: r.keyword);
    final startCtl = TextEditingController(text: '${r.startOffset}');
    final lenCtl = TextEditingController(text: '${r.length}');
    final lenValCtl = TextEditingController(text: '${r.lenVal}');
    var mode = r.mode;
    var dir = r.dir;
    var matchEnc = r.matchEnc;
    var dispEnc = r.dispEnc;
    var lenOp = r.lenOp;
    var dedupType = r.dedupType;
    var sortKey = r.sortKey;
    var accumulate = r.accumulate;
    var enabled = r.enabled;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => _CtlDisposer(
          // 控制器交给对话框子树里的小 State 释放: showDialog 返回后**不能**立刻 dispose,
          // 否则退场动画期间对话框仍会重建 -> "A TextEditingController was used after being disposed"
          controllers: [nameCtl, kwCtl, startCtl, lenCtl, lenValCtl],
          child: AlertDialog(
          title: Text(rule == null ? '添加规则' : '编辑规则'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                      controller: nameCtl,
                      decoration: const InputDecoration(labelText: '名称')),
                  const SizedBox(height: 8),
                  _dd('匹配模式', mode, const [
                    ('extract', '提取(起点偏移+长度)'),
                    ('keyword', '匹配关键字(命中即记录)')
                  ], (v) => setDlg(() => mode = v)),
                  const SizedBox(height: 8),
                  _dd('方向', dir, const [
                    ('recv', '仅接收'),
                    ('send', '仅发送'),
                    ('both', '全部')
                  ], (v) => setDlg(() => dir = v)),
                  const SizedBox(height: 8),
                  // 与 Web 版一致: 显示编码仅「文本(终端编码)」/「HEX」两种
                  _dd('显示编码', dispEnc,
                      const [('text', '文本(终端编码)'), ('hex', 'HEX')],
                      (v) => setDlg(() => dispEnc = v)),
                  if (mode == 'keyword') ...[
                    const SizedBox(height: 8),
                    _dd('匹配编码', matchEnc,
                        const [('hex', 'HEX'), ('text', '文本(终端编码)')],
                        (v) => setDlg(() => matchEnc = v)),
                    const SizedBox(height: 8),
                    TextField(
                        controller: kwCtl,
                        decoration: const InputDecoration(
                            labelText: '匹配关键字 (HEX 或文本)')),
                  ] else ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                            controller: startCtl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: '起点偏移(字节)')),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                            controller: lenCtl,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: '提取长度(字节)')),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 8),
                  Row(children: [
                    SizedBox(
                      width: 110,
                      child: _dd('长度过滤', lenOp,
                          const [('>', '>'), ('>=', '>='), ('<', '<'), ('<=', '<='), ('=', '=')],
                          (v) => setDlg(() => lenOp = v)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                          controller: lenValCtl,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: '长度值 (0=不限制)')),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: _dd('去重方式', dedupType, const [
                        ('none', '不去重'),
                        ('match', '匹配去重'),
                        ('all', '全匹配去重')
                      ], (v) => setDlg(() => dedupType = v)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _dd('排序', sortKey, const [
                        ('time', '按时间'),
                        ('value', '按值'),
                        ('count', '按次数')
                      ], (v) => setDlg(() => sortKey = v)),
                    ),
                  ]),
                  SwitchListTile(
                    value: accumulate,
                    activeColor: Colors.green,
                    onChanged: (v) => setDlg(() => accumulate = v),
                    title: const Text('跨帧累积 (流被拆开时开启)'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    value: enabled,
                    activeColor: Colors.green,
                    onChanged: (v) => setDlg(() => enabled = v),
                    title: const Text('启用'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
          ),
        ),
      ),
    );

    if (saved == true) {
      if (mode == 'keyword') {
        final kw = kwCtl.text.trim();
        if (kw.isEmpty) {
          _hint('请填写匹配关键字');
        } else if (matchEnc == 'hex' && SnifferController.hexToBytes(kw) == null) {
          _hint('匹配关键字 HEX 格式错误(需偶数位)');
        } else {
          r
            ..name = nameCtl.text.trim().isEmpty ? '未命名规则' : nameCtl.text.trim()
            ..keyword = kw
            ..mode = mode
            ..dir = dir
            ..matchEnc = matchEnc
            ..dispEnc = dispEnc
            ..lenOp = lenOp
            ..lenVal = int.tryParse(lenValCtl.text.trim()) ?? 0
            ..dedupType = dedupType
            ..sortKey = sortKey
            ..accumulate = accumulate
            ..enabled = enabled;
          sn.upsertRule(r);
        }
      } else {
        final len = int.tryParse(lenCtl.text.trim()) ?? 0;
        if (len <= 0) {
          _hint('提取模式请填写提取长度(至少 1 字节)');
        } else {
          r
            ..name = nameCtl.text.trim().isEmpty ? '未命名规则' : nameCtl.text.trim()
            ..mode = mode
            ..dir = dir
            ..dispEnc = dispEnc
            ..startOffset = int.tryParse(startCtl.text.trim()) ?? 0
            ..length = len
            ..lenOp = lenOp
            ..lenVal = int.tryParse(lenValCtl.text.trim()) ?? 0
            ..dedupType = dedupType
            ..sortKey = sortKey
            ..accumulate = accumulate
            ..enabled = enabled;
          sn.upsertRule(r);
        }
      }
    }
    // 控制器不在此处释放: 由 _CtlDisposer 随对话框子树销毁时释放(见其 dispose)
  }

  Widget _dd(String label, String value, List<(String, String)> items,
      void Function(String) onChanged) {
    final v = items.any((e) => e.$1 == value) ? value : items.first.$1;
    return DropdownButtonFormField<String>(
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      value: v,
      items: items
          .map((e) => DropdownMenuItem(
              value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis)))
          .toList(),
      onChanged: (x) {
        if (x != null) onChanged(x);
      },
    );
  }

  // 保存 JSON 文本到文件: 优先 saveFile, 平台未实现时退回选目录
  Future<void> _saveJson(String text, String fileName, String dialogTitle) async {
    String? savedPath;
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
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
        final file = File('$dir${Platform.pathSeparator}$fileName');
        await file.writeAsBytes(utf8.encode(text));
        savedPath = file.path;
      } catch (e) {
        _hint('导出失败: $e');
        return;
      }
    }
    _hint('已导出到: $savedPath');
  }

  Future<void> _exportRules(SnifferController sn) async {
    final text = const JsonEncoder.withIndent('  ')
        .convert({'rules': sn.rules.map((e) => e.toJson()).toList()});
    await _saveJson(text, 'linkcom_rules_${_stamp()}.json', '导出匹配规则');
  }

  // 仅导出某条规则的记录(格式与 Web/桌面端 exportRecords 一致)
  Future<void> _exportRuleRecords(
      SnifferController sn, SnifferRule r, String termEnc) async {
    final recs = sn.records.where((x) => x.ruleId == r.id).map((x) {
      return {
        'ts': _ts(x.ts),
        'rawHex': SnifferController.bytesToHex(x.raw),
        'hl': {'start': x.hlStart, 'end': x.hlEnd},
        'value': sn.displayValueOf(
            SnifferAgg(x.raw, x.hlStart, x.hlEnd, 1, x.ts, x.ts, [x]),
            r,
            termEnc),
      };
    }).toList();
    final safe = (r.name.isEmpty ? r.id : r.name)
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final text = const JsonEncoder.withIndent('  ')
        .convert({'rule': safe, 'dispEnc': r.dispEnc, 'records': recs});
    await _saveJson(text, 'linkcom_sniffer_$safe.json', '导出匹配记录');
  }

  Future<void> _importRules(SnifferController sn) async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final file = files.isEmpty ? null : files.first;
      if (file == null) return; // 取消
      final raw = utf8.decode(await file.readAsBytes());
      final j = jsonDecode(raw);
      final list = (j is Map ? j['rules'] : j);
      if (list is! List) throw Exception('格式不正确: 缺少 rules 数组');
      final rs = list
          .whereType<Map>()
          .map((e) => SnifferRule.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (rs.isEmpty) throw Exception('没有规则');
      sn.importRules(rs);
      _hint('已导入 ${rs.length} 条规则');
    } catch (e) {
      _hint('导入失败: $e');
    }
  }

  void _confirmClearRecords(SnifferController sn) {
    if (sn.records.isEmpty) return;
    sn.clearRecords();
    _hint('已清空全部记录');
  }

  void _hint(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// 把一组 ChangeNotifier 的生命周期绑定到对话框子树: 只有对话框真正销毁(退场动画结束后)
// 才 dispose, 避免 showDialog 返回后立刻 dispose 导致的重建期 "used after disposed"。
class _CtlDisposer extends StatefulWidget {
  final List<ChangeNotifier> controllers;
  final Widget child;
  const _CtlDisposer({required this.controllers, required this.child});
  @override
  State<_CtlDisposer> createState() => _CtlDisposerState();
}

class _CtlDisposerState extends State<_CtlDisposer> {
  @override
  void dispose() {
    for (final c in widget.controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
