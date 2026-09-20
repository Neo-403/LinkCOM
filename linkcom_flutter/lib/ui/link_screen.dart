import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../codec/codec_util.dart';
import '../models/relay_message.dart';
import '../state/relay_session.dart';
import '../sniffer/sniffer_controller.dart';
import '../ui/widgets/serial_config_editor.dart';
import '../ui/widgets/collapsible_panel.dart';
import '../ui/widgets/log_view.dart';
import '../ui/quick_send_panel.dart';
import '../ui/sniffer/sniffer_panel.dart';

// 链接端: 中继 -> 串口 (P3 连接房间, 接收/发送)
// 使用 RelaySession(linkSession): 与共享端房间/连接/日志/显示/发送完全隔离,
// 因此共享端可一直保持共享, 链接端同时连接另一房间使用。
class LinkScreen extends StatefulWidget {
  const LinkScreen({super.key});
  @override
  State<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<LinkScreen> {
  final _roomCtl = TextEditingController();
  final _pwdCtl = TextEditingController();
  StreamSubscription<RelayMessage>? _relaySub;
  bool _relayOn = false;

  @override
  void initState() {
    super.initState();
    final sess = context.read<RelaySession>();
    _roomCtl.text = sess.room;
    _pwdCtl.text = sess.pwd;
  }

  void _connect() {
    final sess = context.read<RelaySession>();
    sess.connect(
      room: _roomCtl.text.trim(),
      pwd: _pwdCtl.text,
      role: RelayRole.link,
    );
    _relaySub?.cancel();
    _relaySub = sess.relay?.messages.listen(_onRelay);
    setState(() => _relayOn = true);
  }

  void _disconnect() {
    _relaySub?.cancel();
    _relaySub = null;
    context.read<RelaySession>().disconnect();
    setState(() => _relayOn = false);
  }

  // 共享端发来的串口数据 -> 显示 (server 转发时 from='share')
  void _onRelay(RelayMessage m) {
    final sess = context.read<RelaySession>();
    if (m.t == 'serial-data' && m.from == 'share' && m.buf != null) {
      final bytes = base64Decode(m.buf!);
      final text = decodeBytes(bytes, sess.cfg.encoding);
      // 共享端主动发送(kind='tx')显示为「共享端发送」, 通道回执(串口收到的数据)显示为「←接收」(与 Web 链接端一致)
      final dir = m.kind == 'tx' ? '共享端发送' : '←接收';
      sess.addLog(dir, text.replaceAll('\n', '⏎').replaceAll('\r', ''), bytes: bytes);
      context.read<SnifferController>().feed(bytes, false, sess.cfg.encoding);
    }
  }

  Future<void> _sendInput(String text, bool hex, bool crlf) async {
    final sess = context.read<RelaySession>();
    if (!sess.canSend) {
      sess.addLog('系统', '当前不可发送(等待共享端串口)');
      return;
    }
    final bytes =
        encodeSendInput(text, hex: hex, crlf: crlf, encoding: sess.cfg.encoding);
    if (bytes == null) {
      sess.addLog('系统', '发送失败: HEX 格式错误');
      return;
    }
    // 服务器转发给共享端写串口
    sess.relay?.sendSerialData(bytes);
    sess.addLog('Link_发送', text, bytes: bytes);
    context.read<SnifferController>().feed(bytes, true, sess.cfg.encoding);
  }

  @override
  Widget build(BuildContext context) {
    final sess = context.watch<RelaySession>();
    final c = Theme.of(context).colorScheme;
    // 同共享端: 避免 ListView 双窗格语义(useTwoPaneSemantics)与 Tooltip 嫁接冲突
    // 导致的 Windows AXTree 报错 (flutter#182444)
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        // 与 Web 链接端一致: 房间(中继)配置 + 串口参数合并为一个「房间配置」折叠面板
        CollapsiblePanel(
          title: '房间配置',
          summary:
              '${!sess.wsConnected ? '未连接服务器' : (_relayOn ? '已连接房间' : '已连服务器')} · 房间: ${_roomCtl.text.trim().isNotEmpty ? _roomCtl.text.trim() : '-'} · 共享端: ${!_relayOn ? '离线' : (sess.sharePortOpen ? '在线' : '串口未打开')}',
          collapseWhen: sess.wsConnected,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 5), // 房间码行下移, 避免浮动标签与面板摘要重叠被裁切
              // 房间码 / 密码 / 连接 同一行 (与共享端一致)
              // 房间码 / 密码 / 连接 (宽屏同一行, 窄屏上下堆叠)
              LayoutBuilder(builder: (ctx, cons) {
                final roomField = TextField(
                  controller: _roomCtl,
                  decoration: const InputDecoration(labelText: '房间码'),
                );
                final pwdField = TextField(
                  controller: _pwdCtl,
                  decoration: const InputDecoration(labelText: '密码(可选)'),
                );
                final connBtn = _relayOn
                    ? OutlinedButton(
                        onPressed: _disconnect,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.error,
                          side: BorderSide(color: c.error),
                        ),
                        child: const Text('断开'))
                    : ElevatedButton(
                        onPressed: _connect, child: const Text('连接房间'));
                if (cons.maxWidth <= 460) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      roomField,
                      const SizedBox(height: 8),
                      pwdField,
                      const SizedBox(height: 8),
                      Align(alignment: Alignment.centerRight, child: connBtn),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: roomField),
                    const SizedBox(width: 8),
                    Expanded(child: pwdField),
                    const SizedBox(width: 8),
                    connBtn,
                  ],
                );
              }),
              const SizedBox(height: 8),
              SerialConfigEditor(
                initialCfg: sess.cfg,
                initialAgg: sess.agg,
                onApply: (cfg, agg) => sess.updateConfig(cfg, agg),
              ),
            ],
          ),
        ),
        const Divider(),
        TerminalView(
          cfg: sess.cfg,
          agg: sess.agg,
          onConfigChanged: (cfg, agg) => sess.updateConfig(cfg, agg),
          canSend: sess.canSend,
          sendHint: sess.canSend ? '发送内容' : '等待共享端开启串口...',
          onSend: _sendInput,
        ),
        // const SizedBox(height: 6), // 减小快速发送上方的间距
        QuickSendPanel(onSend: _quickSend, storageKey: 'linkcom_quicksend_link'),
        const SizedBox(height: 12),
        SnifferPanel(encoding: sess.cfg.encoding),
        ],
      ),
    );
  }

  // 返回是否发送成功(供顺序/轮询失败自动停止): 共享端离线/串口未开 或 HEX 错误时返回 false
  Future<bool> _quickSend(QuickItem it) async {
    final sess = context.read<RelaySession>();
    final sniffer = context.read<SnifferController>();
    if (!sess.canSend) {
      sess.addLog('系统', '当前不可发送(等待共享端串口): ${it.name}');
      return false;
    }
    final bytes = it.hex
        ? parseHexBytes(it.data)
        : Uint8List.fromList(
            encodeString(it.crlf ? '${it.data}\r\n' : it.data, sess.cfg.encoding));
    if (bytes == null) {
      sess.addLog('系统', '快速发送失败: HEX 格式错误 (${it.name})');
      return false;
    }
    sess.relay?.sendSerialData(bytes);
    // 记录实际发送的内容(而非条目名称)
    sess.addLog('Link_发送', it.data, bytes: bytes);
    sniffer.feed(bytes, true, sess.cfg.encoding);
    return true;
  }

  @override
  void dispose() {
    _relaySub?.cancel();
    _roomCtl.dispose();
    _pwdCtl.dispose();
    super.dispose();
  }
}
