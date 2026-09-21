import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../state/relay_session.dart';
import '../../serial/serial_config.dart';

// 终端视图: 显示控制 + 显示区域 + 发送区 (对齐 Web 端 terminal-head / send-bar)
// 第一行: 左 显示模式/时间戳/编码/聚合/缓冲 ; 右 自动滚动/暂停
// 显示区域: 接收/发送统计在框内右上角; 右键(桌面)/长按(手机)呼出 复制/清空/历史
// 下方: 发送区 (高度可拖拽; 右侧 发送/HEX/加\r\n; 竖屏换到第二行)
class TerminalView extends StatefulWidget {
  final SerialConfig cfg; // 编码来源
  final AggConfig agg; // 聚合/缓冲来源
  final void Function(SerialConfig, AggConfig) onConfigChanged; // 编码/聚合/缓冲变更回传
  final bool canSend;
  final Future<void> Function(String text, bool hex, bool crlf) onSend;
  final String? sendHint;
  const TerminalView({
    super.key,
    required this.cfg,
    required this.agg,
    required this.onConfigChanged,
    required this.canSend,
    required this.onSend,
    this.sendHint,
  });
  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final _scroll = ScrollController();
  int _frozenLen = -1;
  int _lastCount = 0;
  double _logHeight = 200; // 显示区域高度, 可由下方拖拽条调整
  static const double _minLogH = 90;
  static const double _maxLogH = 600;

  double _sendHeight = 96; // 发送区高度, 可由上方拖拽条调整
  double _minSendH = 96; // 运行时按平台重算: 桌面=右侧三按钮整体高度, 手机=2 行文本
  static const double _maxSendH = 280;
  bool _sendMinMeasured = false; // 最小高度只重算一次, 避免重复 setState
  final GlobalKey _buttonsKey = GlobalKey(); // 测量右侧三按钮高度, 作桌面端最小高度

  final _sendCtl = TextEditingController();
  final _flushCtl = TextEditingController();
  final _bufCtl = TextEditingController();
  late AggConfig _agg;

  static const List<(String, String)> _enc = [
    ('utf8', 'UTF-8'),
    ('gbk', 'GBK'),
  ];

  @override
  void initState() {
    super.initState();
    _agg = widget.agg;
    _syncAgg();
    // 首帧布局完成后, 按平台重算发送区最小高度(桌面=三按钮高度, 手机=2 行)
    WidgetsBinding.instance.addPostFrameCallback((_) => _recalcSendMin());
  }

  void _recalcSendMin() {
    if (!mounted || _sendMinMeasured) return;
    _sendMinMeasured = true;
    final isMobile = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.android;
    if (isMobile) {
      // 2 行文本高度 + 容器垂直内边距(6*2); 输入框用 collapsed 装饰, 内部无额外内边距
      final tp = TextPainter(
        text: const TextSpan(text: 'x', style: TextStyle(fontSize: 14)),
        textDirection: TextDirection.ltr,
      )..layout();
      _minSendH = tp.height * 2 + 12;
    } else {
      final h = _buttonsKey.currentContext?.size?.height;
      if (h != null && h > 0) _minSendH = h; // 右侧三按钮整体高度
    }
    if (_sendHeight < _minSendH) setState(() => _sendHeight = _minSendH);
  }

  void _syncAgg() {
    final f = _agg.flushMs.toString(), b = _agg.maxBufKb.toString();
    if (_flushCtl.text != f) _flushCtl.text = f;
    if (_bufCtl.text != b) _bufCtl.text = b;
  }

  @override
  void didUpdateWidget(covariant TerminalView old) {
    super.didUpdateWidget(old);
    if (widget.agg != _agg) {
      _agg = widget.agg;
      _syncAgg();
    }
  }

  void _applyAgg() {
    final f = int.tryParse(_flushCtl.text) ?? _agg.flushMs;
    final b = int.tryParse(_bufCtl.text) ?? _agg.maxBufKb;
    _agg = _agg.copyWith(flushMs: f, maxBufKb: b);
    widget.onConfigChanged(widget.cfg, _agg);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _sendCtl.dispose();
    _flushCtl.dispose();
    _bufCtl.dispose();
    super.dispose();
  }

  String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  Color _color(String dir, ColorScheme c) {
    switch (dir) {
      case '→发送':
      case 'Link_发送':
        return c.primary;
      case '←接收':
      case '共享端发送':
        return c.brightness == Brightness.dark
            ? const Color(0xFF7FE7FF)
            : const Color(0xFF00697A);
      case '错误':
        return Colors.redAccent;
      default:
        return c.onSurface.withValues(alpha: 0.65);
    }
  }

  String _ts(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  }

  String _fileStamp() {
    final t = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final sess = context.watch<RelaySession>();
    final c = Theme.of(context).colorScheme;

    if (sess.paused) {
      if (_frozenLen < 0) _frozenLen = sess.logs.length;
    } else {
      _frozenLen = -1;
    }
    final total = sess.logs.length;
    final shown = sess.paused ? _frozenLen.clamp(0, total) : total;

    if (shown != _lastCount) {
      _lastCount = shown;
      if (sess.logAutoScroll && !sess.paused) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 第一行: 显示控制(左) + 自动滚动/暂停(右)
        LayoutBuilder(builder: (ctx, cons) {
          // 窄屏(手机): 编码/聚合/缓冲整体缩小, 避免这一行控件过高过宽
          final compact = cons.maxWidth <= 460;
          // 编码/聚合/缓冲 绑成一个整体, 避免"缓冲"在窄宽度下被单独挤到第二行
          final encFields = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _encDropdown(compact),
              SizedBox(width: compact ? 3 : 6),
              _numField('聚合', 'ms', _flushCtl, _applyAgg, compact),
              SizedBox(width: compact ? 3 : 6),
              _numField('缓冲', 'KB', _bufCtl, _applyAgg, compact),
            ],
          );
          final controls = Wrap(
            spacing: compact ? 3 : 6,  // 宽屏: 6
            runSpacing: compact ? 2 : 4,  // 宽屏: 4
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _modeToggle(sess, height: _compactH),
              _toggle('时间戳', sess.logShowTs, (v) => sess.logShowTs = v,
                  height: _compactH),
              encFields,
            ],
          );
          final toggles = Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _toggle('自动滚动', sess.logAutoScroll,
                  (v) => sess.logAutoScroll = v, height: _compactH),
              _toggle('暂停', sess.paused, (v) => setState(() => sess.paused = v),
                  height: _compactH),
            ],
          );
          // 窄屏(手机): 上下堆叠, 避免显示控制被右侧按钮挤成竖排
          if (cons.maxWidth <= 460) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                controls,
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerRight, child: toggles),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: controls),
              const SizedBox(width: 8),
              toggles,
            ],
          );
        }),
        const SizedBox(height: 6),
        // 显示区域 (高度由下方拖拽条调整; 接收/发送统计在框内右上角, 清空/历史通过右键或长按显示框呼出)
        SizedBox(
          height: _logHeight,
          child: GestureDetector(
            // 桌面右键 / 手机长按 -> 呼出 清空/历史 菜单
            onSecondaryTapDown: (d) => _showDisplayMenu(d.globalPosition, sess, shown),
            onLongPressStart: (d) => _showDisplayMenu(d.globalPosition, sess, shown),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: c.outline.withValues(alpha: 0.25)),
                borderRadius: BorderRadius.circular(6),
                color: c.surface,
              ),
              child: Stack(
                children: [
                  shown == 0
                      ? Center(
                          child: Text('暂无数据',
                              style: TextStyle(
                                  color: c.onSurface.withValues(alpha: 0.5))))
                      : SingleChildScrollView(
                          controller: _scroll,
                          // 顶部留白避免与右上角 接收/发送 统计重叠
                          padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = shown > 3000 ? shown - 3000 : 0;
                                  i < shown;
                                  i++)
                                _line(sess.logs[i], sess, c),
                            ],
                          ),
                        ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Row(
                      children: [
                        _stat('接收', _fmtBytes(sess.rxBytes), c),
                        const SizedBox(width: 4),
                        _stat('发送', _fmtBytes(sess.txBytes), c),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 显示区 / 发送区 之间的可拖拽分隔条
        _dragHandle(c),
        const SizedBox(height: 6),
        // 发送区
        _sendArea(context, sess, c),
      ],
    );
  }

  // 显示区与发送区之间的可拖拽分隔条: 上下拖动调整显示区域高度
  Widget _dragHandle(ColorScheme c) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          setState(() {
            _logHeight = (_logHeight + d.delta.dy).clamp(_minLogH, _maxLogH);
          });
        },
        child: Container(
          height: 16,
          alignment: Alignment.center,
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.onSurface.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );

  Widget _sendArea(BuildContext context, RelaySession sess, ColorScheme c) {
    // 发送按钮(宽/窄两种排列共用)
    Widget sendBtn() => ElevatedButton(
          onPressed: widget.canSend ? _doSend : null,
          child: const Text('发送'),
        );
    // 宽屏: 右侧竖排三行 (发送 / HEX / 加\r\n), 与多行文本框高度对齐; 该列用于测量最小高度
    final buttonsWide = Column(
      key: _buttonsKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        sendBtn(),
        const SizedBox(height: 6),
        _toggle('HEX', sess.sendHex, (v) => sess.sendHex = v),
        const SizedBox(height: 6),
        _toggle(r'\r\n', sess.sendCrlf, (v) => sess.sendCrlf = v),
      ],
    );
    // 窄屏(竖屏): 单行 —— HEX、加\r\n 在左, 发送占右侧剩余宽度(比原来更宽, 便于触控)
    final buttonsNarrow = Row(
      children: [
        _toggle('HEX', sess.sendHex, (v) => sess.sendHex = v),
        const SizedBox(width: 6),
        _toggle(r'\r\n', sess.sendCrlf, (v) => sess.sendCrlf = v),
        const SizedBox(width: 8),
        Expanded(child: sendBtn()),
      ],
    );
    // 发送区下方可拖拽条: 向下拖变高、向上拖变矮(正常直觉)
    final handle = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        setState(() {
          _sendHeight = (_sendHeight + d.delta.dy).clamp(_minSendH, _maxSendH);
        });
      },
      child: Container(
        height: 14,
        alignment: Alignment.center,
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: c.onSurface.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
    // 键盘行为(平台相关):
    //  - 桌面: textInputAction=send, 回车=发送; Ctrl/Shift+回车=换行(不触发提交)
    //  - 手机: textInputAction=newline, 回车=换行, 仅点击"发送"按钮才发送
    final isMobile = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.android;
    final field = Container(
      height: _sendHeight,
      decoration: BoxDecoration(
        border: Border.all(color: c.outline.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: TextField(
        controller: _sendCtl,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        enabled: widget.canSend,
        textInputAction: isMobile ? TextInputAction.newline : TextInputAction.send,
        onSubmitted: (_) => _doSend(),
        decoration: InputDecoration.collapsed(
            hintText: widget.sendHint ?? '发送内容'),
      ),
    );
    return LayoutBuilder(
      builder: (ctx, cons) {
        final wide = cons.maxWidth > 520;
        // 两个分支用不同 Key, 结构切换时整块替换, 避免复用导致的 InheritedElement 依赖错乱
        if (wide) {
          return Column(
            key: const ValueKey('send-wide'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 8),
                  buttonsWide,
                ],
              ),
              const SizedBox(height: 4),
              handle, // 宽屏: 拖拽条在整行下方
            ],
          );
        }
        return Column(
          key: const ValueKey('send-narrow'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            const SizedBox(height: 4),
            handle, // 竖屏: 拖拽条紧贴输入框下方(而非发送按钮下方)
            const SizedBox(height: 8),
            buttonsNarrow,
          ],
        );
      },
    );
  }

  void _doSend() {
    if (!widget.canSend) return;
    final t = _sendCtl.text;
    if (t.isEmpty) return;
    widget.onSend(t, context.read<RelaySession>().sendHex,
        context.read<RelaySession>().sendCrlf);
    // 发送后不自动清空, 便于二次编辑/重发
  }

  // 显示框右键(桌面)/长按(手机)呼出的菜单: 复制 / 清空 / 导出历史
  void _showDisplayMenu(Offset pos, RelaySession sess, int shown) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'copy', child: Text('复制可见内容')),
        PopupMenuItem(value: 'copyAll', child: Text('复制全部')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'clear', child: Text('清空')),
        PopupMenuItem(value: 'export', child: Text('导出历史')),
      ],
    ).then((v) {
      if (v == 'copy') {
        _copyLogs(sess, shown, all: false);
      } else if (v == 'copyAll') {
        _copyLogs(sess, shown, all: true);
      } else if (v == 'clear') {
        sess.clearLogs();
      } else if (v == 'export') {
        _exportHistory(sess, shown);
      }
    });
  }

  // 显示内容的纯文本(与导出格式一致): [时间戳] [方向] 文本 [HEX]
  String _plainText(RelaySession sess, int from, int to) {
    final sb = StringBuffer();
    for (var i = from; i < to; i++) {
      final e = sess.logs[i];
      final ts = sess.logShowTs ? '${_ts(e.ts)} ' : '';
      final hex =
          (sess.logShowHex && e.bytes != null) ? ' HEX: ${_hex(e.bytes!)}' : '';
      sb.writeln('$ts[${e.dir}] ${e.text}$hex');
    }
    return sb.toString();
  }

  // 长按/右键菜单复制: all=true 复制全部日志, 否则复制当前显示(最近 3000 行)的内容
  Future<void> _copyLogs(RelaySession sess, int shown,
      {required bool all}) async {
    final start = all ? 0 : (shown > 3000 ? shown - 3000 : 0);
    final text = _plainText(sess, start, shown);
    if (text.trim().isEmpty) {
      _toast('没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制 ${shown - start} 行');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _exportHistory(RelaySession sess, int shown) async {
    final sb = StringBuffer();
    final start = shown > 3000 ? shown - 3000 : 0;
    for (var i = start; i < shown; i++) {
      final e = sess.logs[i];
      final ts = sess.logShowTs ? '${_ts(e.ts)} ' : '';
      final hex = (sess.logShowHex && e.bytes != null) ? ' HEX: ${_hex(e.bytes!)}' : '';
      sb.writeln('$ts[${e.dir}] ${e.text}$hex');
    }
    String? savedPath;
    try {
      // file_picker 13 在 Windows 上 saveFile() 尚未实现(抛 UnimplementedError), 下方走选目录兜底
      final uri = await FilePicker.saveFile(
        dialogTitle: '导出历史',
        fileName: 'linkcom_history_${_fileStamp()}.txt',
        bytes: utf8.encode(sb.toString()),
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (uri == null) return; // 用户取消, 不再弹第二个目录框
      savedPath = uri.toFilePath();
    } on UnimplementedError {
      savedPath = null; // 平台不支持 saveFile, 转选目录兜底
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
      return;
    }
    if (savedPath == null) {
      // 兜底: 选目录后自行写入文件 (Windows 上 getDirectoryPath 已实现)
      try {
        final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
        if (dir == null) return; // 用户取消
        final name = 'linkcom_history_${_fileStamp()}.txt';
        final file = File('$dir${Platform.pathSeparator}$name');
        await file.writeAsBytes(utf8.encode(sb.toString()));
        savedPath = file.path;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('导出失败: $e')));
        }
        return;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出历史: $savedPath')));
    }
  }

  // 按标题文字宽度计算最小宽度(与串口配置下拉一致): 框宽刚好够显示标题+箭头, 内容长了由 IntrinsicWidth 自动扩展
  double _labelMinWidth(String label, [bool compact = false]) {
    final tp = TextPainter(
      text: TextSpan(text: label, style: TextStyle(fontSize: compact ? 14 : 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width + (compact ? 16 : 40);
  }

  // 编码下拉: 与串口配置(波特率等)一致 — 名称 labelText 浮在框上, 框内显示值
  // compact(手机): 字号/内边距/箭头整体缩小
  // 定高统一下拉/输入框: 下拉框(DropdownButtonFormField)自然高度比 TextField 大(含箭头),
  // 若不强制等高会出现 编码 比 聚合/缓冲 高一截。这里对两种模式都强制同一高度, 保证三者等高。
  // 高度需 >= 下拉框自然高度, 否则下拉框会溢出而文本框被压矮, 导致不等高。
  static const double _compactH = 40;

  Widget _encDropdown(bool compact) {
    final c = Theme.of(context).colorScheme;
    final field = IntrinsicWidth(
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: _labelMinWidth('编码', compact)),
          child: DropdownButtonFormField<String>(
            isExpanded: false,
            isDense: true,
            iconSize: compact ? 16 : 24,
            dropdownColor: c.surface,
            style: TextStyle(fontSize: compact ? 14 : 14, color: c.onSurface),
            decoration: InputDecoration(
              isDense: true,
              labelText: '编码',
              labelStyle:
                  TextStyle(fontSize: compact ? 14 : 14, color: c.onSurface),
              // 与左侧胶囊(_compactH)严格等高(不用浮动 label + 加垂直内边距撑到 _compactH)
              contentPadding: const EdgeInsets.fromLTRB(8, 12, 4, 12),
            ),
            value: _enc.any((e) => e.$1 == widget.cfg.encoding)
                ? widget.cfg.encoding
                : _enc.first.$1,
            items: _enc
                .map((e) => DropdownMenuItem(
                    value: e.$1,
                    child: Text(e.$2,
                        style: TextStyle(
                            fontSize: compact ? 11 : 12, color: c.onSurface))))
                .toList(),
            onChanged: (v) {
              if (v != null) widget.onConfigChanged(widget.cfg.copyWith(encoding: v), _agg);
            },
          ),
        ),
      );
    return SizedBox(height: _compactH, child: field);
  }

  // 聚合/缓冲输入框: 与波特率下拉一致 — 名称 labelText 浮在框上, 框内显示值, 单位作后缀
  Widget _numField(String label, String unit, TextEditingController ctl,
      void Function() onApply, bool compact, {double height = _compactH}) {
    final c = Theme.of(context).colorScheme;
    final field = IntrinsicWidth(
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: _labelMinWidth(label, compact)),
        child: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          style: TextStyle(fontSize: compact ? 16 : 16),
          onSubmitted: (_) => onApply(),
          decoration: InputDecoration(
            isDense: true,
            labelText: label,
            labelStyle:
                TextStyle(fontSize: compact ? 14 : 14, color: c.onSurface),
            suffixText: unit,
            suffixStyle: compact ? const TextStyle(fontSize: 10) : null,
            // 与编码下拉一致: 名称 labelText 浮在框上; 垂直内边距撑到 _compactH 等高
            contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          ),
        ),
      ),
    );
    return SizedBox(height: height, child: field);
  }

  Widget _stat(String label, String value, ColorScheme c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text('$label $value',
            style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: c.onSurface)),
      );

  // 统一「颜色激活」胶囊: 固定高度, 不显示 √; 激活=绿色填充+绿描边, 未激活=仅描边。
  // 固定高度(_compactH)可与 编码/聚合/缓冲 输入框严格等高, 避免窄屏高低不齐。
  Widget _pill(String label, bool active, VoidCallback onTap,
      {double height = 32}) {
    final c = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color:
              active ? Colors.green.withValues(alpha: 0.18) : Colors.transparent,
          border: Border.all(
              color: active
                  ? Colors.green.shade600
                  : c.outline.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(8),
        ),
        // widthFactor:1.0 => 宽度贴合文字(不撑满整行); heightFactor 不设 => 撑满 height 并垂直居中
        child: Center(
          widthFactor: 1.0,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: active ? Colors.green.shade700 : c.onSurface)),
        ),
      ),
    );
  }

  Widget _toggle(String label, bool value, void Function(bool) onChanged,
          {double height = 32}) =>
      _pill(label, value, () => onChanged(!value), height: height);

  // 文本/HEX 合并为单一控件: 点击循环切换 文本 -> HEX -> 双显
  Widget _modeToggle(RelaySession sess, {double height = 32}) {
    const labels = {LogMode.text: '文本', LogMode.hex: 'HEX', LogMode.both: '双显'};
    final m = sess.logMode;
    return _pill(
        labels[m]!,
        false,
        () => sess.logMode = LogMode.values[(m.index + 1) % LogMode.values.length],
        height: height);
  }

  Widget _line(LogEntry e, RelaySession sess, ColorScheme c) {
    final textColor = _color(e.dir, c);
    final header = <Widget>[
      if (sess.logShowTs)
        Text('${_ts(e.ts)} ',
            style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: c.onSurface.withValues(alpha: 0.45))),
      Text('[${e.dir}]: ',
          style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: textColor)),
    ];
    final textStyle = TextStyle(
        fontSize: 12, fontFamily: 'monospace', color: c.onSurface);
    final hexStyle = TextStyle(
        fontSize: 11,
        fontFamily: 'monospace',
        color: c.onSurface.withValues(alpha: 0.6));

    final showText = sess.logShowText || e.bytes == null;
    final showHex = sess.logShowHex && e.bytes != null;
    final both = showText && showHex; // 仅双显时 HEX 折到第二行

    final children = <Widget>[];
    if (showText) {
      // 文本: 时间 [方向]: 内容  (同行, 内容可换行)
      children.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...header,
          Expanded(child: Text(e.text, style: textStyle)),
        ],
      ));
    } else {
      // 仅 HEX: 时间 [方向]: HEX 同一行(不折到第二行)
      children.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...header,
          Expanded(child: Text(_hex(e.bytes!), style: hexStyle)),
        ],
      ));
    }
    if (both) {
      // 仅双显时 HEX 显示在下一行
      children.add(Text(_hex(e.bytes!), style: hexStyle));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
