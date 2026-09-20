import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show Random;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../codec/codec_util.dart';
import '../serial/serial_config.dart';
import '../serial/serial_service.dart';
import '../state/relay_session.dart';
import '../models/relay_message.dart';
import '../sniffer/sniffer_controller.dart';
import '../ui/widgets/serial_config_editor.dart';
import '../ui/widgets/collapsible_panel.dart';
import '../ui/widgets/log_view.dart';
import '../ui/quick_send_panel.dart';
import '../ui/sniffer/sniffer_panel.dart';

// 共享端: 本地串口 <-> 中继 (P1 串口层 + P3 中继转发)
// 使用 RelaySession(shareSession): 房间/连接/串口参数/日志/显示/发送 均与链接端隔离
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});
  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  SerialBackend _backend = SerialBackend.usb;
  late SerialService _svc = createSerialService(_backend);
  List<SerialPortInfo> _ports = [];
  SerialPortInfo? _selected;
  SerialPort? _port;
  // 选项配置自动保存/加载: 上次使用的连接方式(USB/蓝牙)与串口, 重启后自动恢复
  static const _kBackend = 'shareBackend';
  static const _kPortId = 'sharePortId';
  String? _savedPortId;
  final _roomCtl = TextEditingController();
  final _pwdCtl = TextEditingController();
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<RelayMessage>? _relaySub;
  StreamSubscription<SerialState>? _stateSub; // 串口状态(异常时自动停止发送)
  bool _relayOn = false;
  final _rxBuf = BytesBuilder(); // 接收聚合缓冲, 避免连续数据重建风暴
  Timer? _rxTimer;

  RelaySession get _sess => context.read<RelaySession>();

  @override
  void initState() {
    super.initState();
    final sess = context.read<RelaySession>();
    _roomCtl.text = sess.room;
    _pwdCtl.text = sess.pwd;
    _restorePortChoice();
  }

  // 恢复上次的连接方式与串口, 再枚举设备并自动选中
  Future<void> _restorePortChoice() async {
    try {
      final p = await SharedPreferences.getInstance();
      final b = p.getString(_kBackend);
      _savedPortId = p.getString(_kPortId);
      if (!mounted) return;
      if (b == SerialBackend.bluetooth.name && _backend != SerialBackend.bluetooth) {
        setState(() {
          _backend = SerialBackend.bluetooth;
          _svc = createSerialService(_backend);
        });
      }
    } catch (_) {}
    if (mounted) _refresh();
  }

  // 保存连接方式 + 当前所选串口(供下次启动自动恢复)
  Future<void> _persistPortChoice() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kBackend, _backend.name);
      final id = _selected?.id ?? _savedPortId;
      if (id == null) {
        await p.remove(_kPortId);
      } else {
        _savedPortId = id;
        await p.setString(_kPortId, id);
      }
    } catch (_) {}
  }

  // 切换串口后端(Android: USB-OTG / 蓝牙 SPP); 串口已打开时禁止切换
  void _switchBackend(SerialBackend b) {
    if (_port != null || b == _backend) return;
    setState(() {
      _backend = b;
      _svc = createSerialService(b);
      _ports = [];
      _selected = null;
    });
    unawaited(_persistPortChoice());
    _refresh();
  }

  Future<void> _refresh() async {
    final sess = _sess;
    try {
      final list = await _svc.listDevices();
      if (!mounted) return;
      setState(() {
        _ports = list;
        // 自动选中上次使用的串口(仍存在时)
        if (_selected == null && _savedPortId != null) {
          for (final p in list) {
            if (p.id == _savedPortId) {
              _selected = p;
              break;
            }
          }
        }
      });
      if (_selected != null) sess.addLog('系统', '已恢复上次串口: ${_selected!.name}');
      sess.addLog('系统', '枚举到 ${list.length} 个串口');
    } catch (e) {
      sess.addLog('系统', '枚举串口失败: $e');
    }
  }

  // 避免歧义字符(0/O/1/I/L)的随机房间码
  static String _randomRoomCode() {
    const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rnd = Random();
    return String.fromCharCodes(
        Iterable.generate(6, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }

  void _connectRelay() {
    final sess = _sess;
    // 房间码为空时自动随机一个, 避免用空房间码共享; 有内容则不随机
    if (_roomCtl.text.trim().isEmpty) {
      _roomCtl.text = _randomRoomCode();
    }
    sess.connect(
      room: _roomCtl.text.trim(),
      pwd: _pwdCtl.text,
      role: RelayRole.share,
    );
    _relaySub?.cancel();
    _relaySub = sess.relay?.messages.listen(_onRelay);
    setState(() => _relayOn = true);
  }

  void _disconnectRelay() {
    _relaySub?.cancel();
    _relaySub = null;
    _sess.disconnect();
    setState(() => _relayOn = false);
  }

  // 中继消息桥接: 链接端发来的数据写串口; 链接端改参数则应用
  void _onRelay(RelayMessage m) {
    final sess = _sess;
    if (m.t == 'ok' && _port != null) {
      // 开串口可能早于连中继 / 断线重连后重新加入: 补发串口状态与配置, 保证链接端状态同步
      sess.relay?.sendSerialState(true);
      _syncRelayConfig();
      return;
    }
    if (m.t == 'serial-data' && m.from == 'link' && m.buf != null) {
      final bytes = Uint8List.fromList(base64Decode(m.buf!));
      final p = _port;
      if (p != null) unawaited(p.write(bytes).catchError((_) {}));
      // 链接端发来的数据: 写入串口, 并记为「Link_发送」以便与共享端自身发送区分 (与 Web 共享端一致)
      final text = decodeBytes(bytes, sess.cfg.encoding);
      sess.addLog('Link_发送', text.replaceAll('\n', '⏎').replaceAll('\r', ''),
          bytes: bytes);
      context.read<SnifferController>().feed(bytes, true, sess.cfg.encoding);
    } else if (m.t == 'serial-config' && m.from == 'link') {
      // 链接端回传的完整参数(含聚合): 应用并(已开则)重开串口, 再广播使其它链接端收敛
      try {
        final cfg = m.cfg != null ? SerialConfig.fromJson(m.cfg!) : sess.cfg;
        final agg = m.agg != null ? AggConfig.fromJson(m.agg!) : sess.agg;
        sess.updateConfig(cfg, agg);
        sess.addLog('系统', '应用链接端参数: ${cfg.baudRate}/${cfg.encoding} ${agg.flushMs}ms');
        if (_port != null) _reopen();
      } catch (e) {
        sess.addLog('错误', '应用链接端参数失败: $e');
      }
    }
  }

  Future<void> _reopen() async {
    await _close();
    await _open();
  }

  Future<void> _open() async {
    if (_selected == null) return;
    final sess = _sess;
    final cfg = sess.cfg;
    try {
      _port = await _svc.connect(_selected!, cfg);
      _stateSub?.cancel();
      _stateSub = _port!.state.listen(_onPortState);
      sess.setPortOpen(true);
      _dataSub = _port!.data.listen((bytes) {
        _rxBuf.add(bytes);
        _rxTimer ??= Timer(Duration(milliseconds: sess.agg.flushMs), _flushRx);
      });
      sess.addLog('系统', '串口已打开: ${_selected!.name} @${cfg.baudRate}');
      // 通知链接端串口状态 + 当前参数
      sess.relay?.sendSerialState(true);
      _syncRelayConfig();
    } catch (e) {
      sess.addLog('系统', '打开失败: $e');
    }
  }

  void _syncRelayConfig() {
    final sess = _sess;
    sess.relay?.sendSerialConfig(sess.cfg, SerialChannelMode.serial, sess.agg);
  }

  // 时间窗口聚合后统一解码/显示/转发, 防止连续串口数据触发整页频繁重建导致卡死
  void _flushRx() {
    _rxTimer = null;
    if (!mounted || _rxBuf.isEmpty) {
      _rxBuf.clear();
      return;
    }
    final raw = Uint8List.fromList(_rxBuf.toBytes());
    _rxBuf.clear();
    final sess = _sess;
    final text = decodeBytes(raw, sess.cfg.encoding);
    sess.addLog('←接收', text.replaceAll('\n', '⏎').replaceAll('\r', ''), bytes: raw);
    context.read<SnifferController>().feed(raw, false, sess.cfg.encoding);
    sess.relay?.sendSerialData(raw);
  }

  void _cancelRx() {
    _rxTimer?.cancel();
    _rxTimer = null;
    _rxBuf.clear();
  }

  // 串口状态异常(如 Android usb_serial 报错): 立即作废端口, 使固定/轮询发送失败并停止
  void _onPortState(SerialState st) {
    if (st != SerialState.error) return;
    _sess.addLog('错误', '串口异常, 已停止发送');
    _abortPort();
  }

  // 作废当前端口(不等待底层 close), 供异常路径复用
  void _abortPort() {
    _cancelRx();
    _dataSub?.cancel();
    _dataSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    final p = _port;
    _port = null;
    if (p != null) unawaited(p.close().catchError((_) {}));
    if (mounted) setState(() {});
    final sess = _sess;
    sess.setPortOpen(false);
    sess.relay?.sendSerialState(false);
  }

  Future<void> _close() async {
    final sess = _sess;
    _cancelRx();
    _stateSub?.cancel();
    _stateSub = null;
    try {
      await _dataSub?.cancel();
    } catch (_) {}
    _dataSub = null;
    // 先置空端口并刷新 UI: 即使底层 close 抛异常(端口其实已断开)也能回到"未打开"
    final p = _port;
    _port = null;
    if (mounted) setState(() {});
    if (p != null) {
      try {
        await p.close();
      } catch (_) {
        // 端口可能已断开, 忽略关闭异常
      }
    }
    sess.setPortOpen(false);
    sess.relay?.sendSerialState(false);
  }

  Future<void> _sendInput(String text, bool hex, bool crlf) async {
    final sess = _sess;
    final sniffer = context.read<SnifferController>();
    if (_port == null) {
      sess.addLog('系统', '串口未打开, 无法发送');
      return;
    }
    final bytes =
        encodeSendInput(text, hex: hex, crlf: crlf, encoding: sess.cfg.encoding);
    if (bytes == null) {
      sess.addLog('系统', '发送失败: HEX 格式错误');
      return;
    }
    try {
      await _port!.write(bytes);
      sess.addLog('→发送', text, bytes: bytes);
      sniffer.feed(bytes, true, sess.cfg.encoding);
      // 链接端显示为 "共享端发送"
      sess.relay?.sendSerialData(bytes, kind: 'tx');
    } catch (e) {
      sess.addLog('系统', '发送失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sess = context.watch<RelaySession>();
    final c = Theme.of(context).colorScheme;
    final selId = _selected != null &&
            _ports.any((p) => p.id == _selected!.id)
        ? _selected!.id
        : null;
    // 用 SingleChildScrollView 而非 ListView: ListView 的 RenderViewport 会加双窗格语义
    // (useTwoPaneSemantics), 与内部 Tooltip 的 OverlayPortal 嫁接在 Windows 上会丢失
    // detach 通知, 触发 "Failed to update ui::AXTree ... not be in the tree" (flutter#182444)。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        // 与 Web 共享端一致: 串口配置 + 房间(中继)配置合并为一个「房间配置」折叠面板
        CollapsiblePanel(
          title: '房间配置',
          summary:
              '${sess.wsConnected ? '已连服务器' : '未连接服务器'} · ${_relayOn ? '共享中' : '未共享'}${_roomCtl.text.trim().isNotEmpty ? ' · 房间: ${_roomCtl.text.trim()}' : ''} · 在线链接: ${sess.links}',
          collapseWhen: sess.wsConnected,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (Platform.isAndroid) ...[
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('连接方式',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    SegmentedButton<SerialBackend>(
                      segments: const [
                        // 窄屏下不带图标, 避免「USB(OTG)/蓝牙SPP」标签换行
                        ButtonSegment(
                            value: SerialBackend.usb, label: Text('USB(OTG)')),
                        ButtonSegment(
                            value: SerialBackend.bluetooth, label: Text('蓝牙SPP')),
                      ],
                      selected: {_backend},
                      onSelectionChanged:
                          _port == null ? (set) => _switchBackend(set.first) : null,
                      showSelectedIcon: false, // 窄屏下去掉勾选图标, 避免标签换行
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              // 选择串口 + 打开/关闭串口 + 刷新 (宽屏同一行, 窄屏上下堆叠)
              LayoutBuilder(builder: (ctx, cons) {
                final picker = DropdownButton<String>(
                  isExpanded: true,
                  hint: const Text('选择串口'),
                  value: selId,
                  items: _ports
                      .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                      .toList(),
                  onChanged: (id) {
                    setState(() => _selected =
                        id == null ? null : _ports.firstWhere((p) => p.id == id));
                    unawaited(_persistPortChoice());
                  },
                );
                final openBtn = _port == null
                    ? ElevatedButton(onPressed: _open, child: const Text('打开串口'))
                    : OutlinedButton(
                        onPressed: _close,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.error,
                          side: BorderSide(color: c.error),
                        ),
                        child: const Text('关闭串口'));
                final refreshBtn =
                    ElevatedButton(onPressed: _refresh, child: const Text('刷新'));
                if (cons.maxWidth <= 460) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      picker,
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          openBtn,
                          const SizedBox(width: 8),
                          refreshBtn,
                        ]),
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: picker),
                    const SizedBox(width: 8),
                    openBtn,
                    const SizedBox(width: 8),
                    refreshBtn,
                  ],
                );
              }),
              const SizedBox(height: 8),
              SerialConfigEditor(
                initialCfg: sess.cfg,
                initialAgg: sess.agg,
                onApply: (cfg, agg) {
                  sess.updateConfig(cfg, agg);
                  if (_port != null) _reopen();
                },
              ),
              const Divider(),
              // 房间码 / 密码 / 开始共享 (宽屏同一行, 窄屏上下堆叠)
              LayoutBuilder(builder: (ctx, cons) {
                final roomField = TextField(
                  controller: _roomCtl,
                  decoration:
                      const InputDecoration(labelText: '房间码', isDense: true),
                );
                final pwdField = TextField(
                  controller: _pwdCtl,
                  decoration: const InputDecoration(
                      labelText: '密码(可选)', isDense: true),
                );
                final startBtn = _relayOn
                    ? OutlinedButton(
                        onPressed: _disconnectRelay,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.error,
                          side: BorderSide(color: c.error),
                        ),
                        child: const Text('停止共享'))
                    : ElevatedButton(
                        onPressed: _connectRelay, child: const Text('开始共享'));
                if (cons.maxWidth <= 460) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      roomField,
                      const SizedBox(height: 8),
                      pwdField,
                      const SizedBox(height: 8),
                      Align(
                          alignment: Alignment.centerRight, child: startBtn),
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
                    startBtn,
                  ],
                );
              }),
              const SizedBox(height: 4),
            ],
          ),
        ),
        const Divider(),
        TerminalView(
          cfg: sess.cfg,
          agg: sess.agg,
          onConfigChanged: (cfg, agg) {
            sess.updateConfig(cfg, agg);
            if (_port != null) _reopen();
          },
          canSend: _port != null,
          sendHint: '发送内容',
          onSend: _sendInput,
        ),
        // const SizedBox(height: 6), // 减小快速发送上方的间距
        QuickSendPanel(onSend: _quickSend),
        const SizedBox(height: 12),
        SnifferPanel(encoding: sess.cfg.encoding),
        ],
      ),
    );
  }

  // 返回是否发送成功(供顺序/轮询失败自动停止)
  Future<bool> _quickSend(QuickItem it) async {
    final sess = _sess;
    final sniffer = context.read<SnifferController>();
    if (_port == null) {
      sess.addLog('系统', '串口未打开, 无法快速发送: ${it.name}');
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
    try {
      await _port!.write(bytes);
      // 记录实际发送的内容(而非条目名称)
      sess.addLog('→发送', it.data, bytes: bytes);
      sniffer.feed(bytes, true, sess.cfg.encoding);
      sess.relay?.sendSerialData(bytes, kind: 'tx');
      return true;
    } catch (e) {
      sess.addLog('系统', '快速发送失败: $e');
      return false; // 写失败通常意味串口已出错/拔出
    }
  }

  @override
  void dispose() {
    _cancelRx();
    _dataSub?.cancel();
    _relaySub?.cancel();
    _stateSub?.cancel();
    _port?.close();
    _roomCtl.dispose();
    _pwdCtl.dispose();
    super.dispose();
  }
}
