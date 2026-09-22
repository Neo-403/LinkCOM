import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show Random;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../codec/codec_util.dart';
import '../serial/channel_config.dart';
import '../serial/serial_config.dart';
import '../serial/serial_service.dart';
import '../serial/tcp_port.dart';
import '../state/app_state.dart';
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
  // 通道类型: COM(串口) / BLE(蓝牙) / TCP 客户端 / TCP 服务器
  ShareChannel _channel = ShareChannel.com;
  late SerialService _svc = createSerialService(_backend);
  List<SerialPortInfo> _ports = []; // 界面实际展示的列表(可能已过滤)
  List<SerialPortInfo> _allPorts = []; // listDevices 的完整结果(BLE 过滤前)
  bool _showPaired = false; // BLE: 是否显示"已配对但未广播(可能不在附近)"的设备
  SerialPortInfo? _selected;
  SerialPort? _port;
  // TCP 参数 (输入框; 打开通道时读取)
  final _tcRemoteHost = TextEditingController();
  final _tcRemotePort = TextEditingController();
  final _tcLocalPort = TextEditingController();
  final _tsLocalPort = TextEditingController();
  String _tcLocalIp = '';
  String _tsLocalIp = '';
  List<String> _localIps = [];
  // 选项配置自动保存/加载: 上次使用的通道/串口/TCP 参数, 重启后自动恢复
  static const _kBackend = 'shareBackend';
  static const _kPortId = 'sharePortId';
  static const _kChannel = 'shareChannel'; // 旧键(语义已变)
  static const _kChannelV2 = 'shareChannel2';
  static const _kTcpClient = 'shareTcpClient';
  static const _kTcpServer = 'shareTcpServer';
  String? _savedPortId;
  final _roomCtl = TextEditingController();
  final _pwdCtl = TextEditingController();
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<RelayMessage>? _relaySub;
  StreamSubscription<SerialState>? _stateSub; // 串口状态(异常时自动停止发送)
  StreamSubscription<String>? _logSub; // TCP 通道状态文本
  bool _relayOn = false;
  bool _opening = false; // 防重入: 连点「打开」会多次 connect 去抢同一个蓝牙设备
  final _rxBuf = BytesBuilder(); // 接收聚合缓冲, 避免连续数据重建风暴
  Timer? _rxTimer;

  RelaySession get _sess => context.read<RelaySession>();

  // 设备后端由通道类型推导 (经典蓝牙 -> SPP, BLE -> GATT, 其余 -> 串口 COM/USB)
  SerialBackend get _backend => switch (_channel) {
        ShareChannel.classic => SerialBackend.bluetooth,
        ShareChannel.ble => SerialBackend.ble,
        _ => SerialBackend.usb,
      };

  // 桌面端三段(COM/TCP 客户端/TCP 服务器); 移动端五段(多出 经典蓝牙 / BLE)
  List<ShareChannel> _channelSegments() => Platform.isAndroid
      ? const [
          ShareChannel.com,
          ShareChannel.classic,
          ShareChannel.ble,
          ShareChannel.tcpClient,
          ShareChannel.tcpServer,
        ]
      : const [
          ShareChannel.com,
          ShareChannel.tcpClient,
          ShareChannel.tcpServer,
        ];

  // 窄屏(手机)统一控件高度: 5 段按钮文案会换行, 需要更高的按钮, 其余按钮一并加高
  bool get _phone => MediaQuery.sizeOf(context).width < 720;
  double get _ctlH => _phone ? 48 : 40;

  TcpClientConfig _tcpClientCfg() => TcpClientConfig(
        localIp: _tcLocalIp.trim(),
        localPort: _tcLocalPort.text.trim(),
        remoteHost: _tcRemoteHost.text.trim(),
        remotePort: _tcRemotePort.text.trim(),
      );

  TcpServerConfig _tcpServerCfg() => TcpServerConfig(
        localIp: _tsLocalIp.trim(),
        localPort: _tsLocalPort.text.trim(),
      );

  @override
  void initState() {
    super.initState();
    final sess = context.read<RelaySession>();
    _roomCtl.text = sess.room;
    _pwdCtl.text = sess.pwd;
    _restorePortChoice();
  }

  // 旧版 shareChannel 值 -> 新版通道
  static String? _legacyChannel(String? old) => switch (old) {
        'ble' => ShareChannel.classic.name, // 旧版 ble = 经典蓝牙 SPP
        'usb' => ShareChannel.com.name,
        null => null,
        _ => old,
      };

  // 恢复上次的通道/串口/TCP 参数, 再枚举设备并自动选中
  Future<void> _restorePortChoice() async {
    // 网卡枚举单独 try: 即便失败也不影响其余配置的恢复(否则下拉里一个 IP 都没有)
    var ips = <String>[];
    try {
      ips = await listLocalIps();
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      final b = p.getString(_kBackend);
      // 新版键优先; 旧键里 'ble' 当时表示「经典蓝牙 SPP」, 语义与新版不同
      final ch = p.getString(_kChannelV2) ?? _legacyChannel(p.getString(_kChannel));
      final tc = p.getString(_kTcpClient);
      final ts = p.getString(_kTcpServer);
      _savedPortId = p.getString(_kPortId);
      if (!mounted) return;
      setState(() {
        _localIps = ips;
        ShareChannel? c;
        if (ch != null) {
          for (final e in ShareChannel.values) {
            if (e.name == ch) {
              c = e;
              break;
            }
          }
        }
        // 兼容旧版本只存了 backend 的情况
        c ??= (b == SerialBackend.bluetooth.name ? ShareChannel.ble : null);
        if (c != null) _channel = c;
        _svc = createSerialService(_backend);
        if (tc != null) {
          final v =
              TcpClientConfig.fromJson(jsonDecode(tc) as Map<String, dynamic>);
          _tcLocalIp = v.localIp;
          _tcLocalPort.text = v.localPort;
          _tcRemoteHost.text = v.remoteHost;
          _tcRemotePort.text = v.remotePort;
        }
        if (ts != null) {
          final v =
              TcpServerConfig.fromJson(jsonDecode(ts) as Map<String, dynamic>);
          _tsLocalIp = v.localIp;
          _tsLocalPort.text = v.localPort;
        }
      });
      if (ips.isNotEmpty) {
        _sess.addLog('系统', '本机 IP: ${ips.join(', ')}');
      }
    } catch (_) {}
    if (mounted) _refresh();
    // 首次没枚举到(如启动瞬间网卡未就绪)时再补一次
    if (mounted && ips.isEmpty) unawaited(_reloadLocalIps());
  }

  // 重新枚举本机网卡 IP (换网/首次启动拿不到时用)
  Future<void> _reloadLocalIps() async {
    try {
      final ips = await listLocalIps();
      if (!mounted || ips.isEmpty) return;
      setState(() => _localIps = ips);
      _sess.addLog('系统', '本机 IP: ${ips.join(', ')}');
    } catch (_) {}
  }

  // 保存通道 + 当前所选串口 + TCP 参数(供下次启动自动恢复)
  Future<void> _persistPortChoice() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kChannelV2, _channel.name);
      await p.setString(_kBackend, _backend.name);
      final id = _selected?.id ?? _savedPortId;
      if (id == null) {
        await p.remove(_kPortId);
      } else {
        _savedPortId = id;
        await p.setString(_kPortId, id);
      }
      await p.setString(_kTcpClient, jsonEncode(_tcpClientCfg().toJson()));
      await p.setString(_kTcpServer, jsonEncode(_tcpServerCfg().toJson()));
    } catch (_) {}
  }

  // 切换通道类型(通道已打开时禁止); 需要设备列表的通道要重建服务并重新枚举/扫描
  void _switchChannel(ShareChannel ch) {
    if (_port != null || ch == _channel) return;
    setState(() {
      _channel = ch;
      _svc = createSerialService(_backend);
      _ports = [];
      _selected = null;
    });
    unawaited(_persistPortChoice());
    if (ch.needsPicker) {
      _refresh();
    } else if (_localIps.isEmpty) {
      // 进入 TCP 通道时补一次网卡枚举(换网/首次启动可能拿不到)
      unawaited(_reloadLocalIps());
    }
  }

  // BLE: 默认隐藏"已配对但未广播"的设备(它们多半不在附近, 会把列表塞满);
  // 其它通道或打开了开关则全量展示。不重新扫描, 切换开关是瞬时的。
  void _applyPortFilter() {
    _ports = (_channel.isBle && !_showPaired)
        ? _allPorts.where((p) => p.raw['pairedSilent'] != true).toList()
        : List<SerialPortInfo>.of(_allPorts);
    // 选中的设备被过滤掉时必须清空, 否则 DropdownButton 的 value 匹配不到 item 会断言
    if (_selected != null && !_ports.any((p) => p.id == _selected!.id)) {
      _selected = null;
    }
  }

  Future<void> _refresh() async {
    final sess = _sess;
    try {
      final raw = await _svc.listDevices();
      if (!mounted) return;
      setState(() {
        _allPorts = raw;
        _applyPortFilter();
        // BLE: 附近一个都没扫到、但有"已配对(未广播)"的设备(HC-04 这类双模模块配对/连过之后
        // 就不再广播) → 自动显示出来, 免得用户以为设备没被找到
        if (_channel.isBle &&
            !_showPaired &&
            _ports.isEmpty &&
            _allPorts.isNotEmpty) {
          _showPaired = true;
          _applyPortFilter();
        }
        // 自动选中上次使用的设备(仍存在时)
        if (_selected == null && _savedPortId != null) {
          for (final p in _ports) {
            if (p.id == _savedPortId) {
              _selected = p;
              break;
            }
          }
          // 上次的设备恰好被"已配对过滤"挡住: 自动打开开关, 保证能恢复
          if (_selected == null && !_showPaired &&
              _allPorts.any((p) => p.id == _savedPortId)) {
            _showPaired = true;
            _applyPortFilter();
            _selected = _ports.firstWhere((p) => p.id == _savedPortId);
          }
        }
      });
      if (_selected != null) {
        sess.addLog('系统', '已恢复上次${_channel.isBle ? '设备' : '串口'}: ${_selected!.name}');
      }
      final hidden = _allPorts.length - _ports.length;
      sess.addLog('系统',
          _channel.isBle ? '扫描到 ${_allPorts.length} 个 BLE 设备' : '枚举到 ${_allPorts.length} 个串口');
      if (_channel.isBle && hidden > 0) {
        sess.addLog('系统', '已隐藏 $hidden 个已配对(未广播)设备, 点右侧漏斗图标可显示');
      }
      if (_channel.isBle && _allPorts.isEmpty) {
        sess.addLog('系统', '提示: 若一直是 0, 请确认手机蓝牙已开、附近有 BLE 设备; '
            '安卓 11 及以下还需打开「定位」才能扫到 BLE');
      }
    } catch (e) {
      sess.addLog('错误', '${_channel.isBle ? 'BLE 扫描' : '枚举串口'}失败: $e');
    }
  }

  // 房间配置面板右上角摘要: 窄屏(手机)精简为关键状态, 宽屏保留完整说明
  String _summary(RelaySession sess) {
    final room = _roomCtl.text.trim();
    if (MediaQuery.sizeOf(context).width <= 600) {
      return '${sess.wsConnected ? '已连' : '未连'} · ${_relayOn ? '共享中' : '未共享'}'
          '${room.isEmpty ? '' : ' · $room'} · 链接${sess.links}';
    }
    return '${sess.wsConnected ? '已连服务器' : '未连接服务器'}'
        ' · ${_relayOn ? '共享中' : '未共享'}'
        '${room.isEmpty ? '' : ' · 房间: $room'} · 在线链接: ${sess.links}';
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
      // 与 Web/桌面端一致: 暂停时不进行快速匹配(旁路监听停止)
      if (!sess.paused) {
        context.read<SnifferController>().feed(bytes, true, sess.cfg.encoding);
      }
    } else if (m.t == 'serial-config' && m.from == 'link') {
      // 链接端回传的完整参数(含聚合): 应用并(已开则)重开串口, 再广播使其它链接端收敛
      try {
        final cfg = m.cfg != null ? SerialConfig.fromJson(m.cfg!) : sess.cfg;
        final agg = m.agg != null ? AggConfig.fromJson(m.agg!) : sess.agg;
        sess.updateConfig(cfg, agg);
        sess.addLog('系统', '应用链接端参数: ${cfg.baudRate}/${cfg.encoding} ${agg.flushMs}ms');
        // 仅串口通道参数变化需要重开通道; TCP 只同步聚合参数
        if (_port != null && _channel.isSerial) _reopen();
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
    if (_opening) return; // 正在打开中, 忽略重复点击
    _opening = true;
    final sess = _sess;
    var cfg = sess.cfg;
    // 安卓 USB-OTG 底层 CH340/CH341 驱动的数据位/停止位是空实现 → 归一到 8/1,
    // 让界面显示与实际一致(避免链接端/日志里出现假的 6 位、7 位)
    if (Platform.isAndroid &&
        _channel == ShareChannel.com &&
        (cfg.dataBits != 8 || cfg.stopBits != StopBits.one)) {
      cfg = cfg.copyWith(dataBits: 8, stopBits: StopBits.one);
      sess.updateConfig(cfg, sess.agg);
    }
    unawaited(_persistPortChoice());
    try {
      final SerialPort p;
      // 需要设备列表的通道(COM / 经典蓝牙 / BLE)都走 SerialService.connect;
      // 只有 TCP 用 createTcpPort (注意: BLE 不属于 isSerial, 之前误入 TCP 分支)
      if (_channel.needsPicker) {
        if (_selected == null) return;
        p = await _svc.connect(_selected!, cfg);
      } else {
        // TCP 通道: 无串口参数, 参数在构造时带入
        p = createTcpPort(_channel, _tcpClientCfg(), _tcpServerCfg());
        await p.open(cfg);
      }
      _attachPort(p, cfg);
    } catch (e) {
      sess.addLog('系统', '打开失败: $e');
    } finally {
      _opening = false;
    }
  }

  // 端口就绪后统一接线: 状态 / 数据(聚合) / TCP 状态文本 / 中继上报
  void _attachPort(SerialPort p, SerialConfig cfg) {
    final sess = _sess;
    _port = p;
    _stateSub?.cancel();
    _stateSub = p.state.listen(_onPortState);
    sess.setPortOpen(true);
    _dataSub = p.data.listen((bytes) {
      _rxBuf.add(bytes);
      _rxTimer ??= Timer(Duration(milliseconds: sess.agg.flushMs), _flushRx);
    });
    // 端口自身上报的状态文本 → 日志:
    //   TCP: 已连接 / 客户端接入 / 断开;  BLE: 服务/特征值清单 + 选中的收发特征值
    _logSub?.cancel();
    _logSub = null;
    if (p is ChannelLogSource) {
      // 显式转换: SerialPort 与 ChannelLogSource 无继承关系, 不会自动类型提升
      _logSub =
          (p as ChannelLogSource).logs.listen((s) => sess.addLog('系统', s));
    }
    sess.addLog(
        '系统',
        // 只有真正的串口才打印波特率(蓝牙链路上波特率无效, 打印出来会误导)
        _channel == ShareChannel.com
            ? '串口已打开: ${_selected!.name} @${cfg.baudRate}'
            : '${_channel.label}通道已打开: ${_selected?.name ?? '-'}');
    // 通知链接端通道状态 + 当前参数/通道类型
    sess.relay?.sendSerialState(true);
    _syncRelayConfig();
    if (mounted) setState(() {});
  }

  // BLE 收发特征值手动选择: 非标模块被自动挑错时在这里改(即时生效, 按设备 MAC 记住)
  Widget _bleCharRow(ColorScheme c) {
    final ctl = _port as BleCharControl;
    final opts = ctl.charOptions;
    if (opts.isEmpty) return const SizedBox.shrink();
    final txOpts = opts.where((o) => o.canWrite).toList();
    final rxOpts = opts.where((o) => o.canNotify).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('BLE 收发特征值',
              style: TextStyle(
                  fontSize: 12, color: c.onSurface.withValues(alpha: 0.6))),
          _bleCharPick('发送', ctl.txUuid, txOpts,
              (v) => ctl.selectChars(txUuid: v)),
          _bleCharPick('接收', ctl.rxUuid, rxOpts,
              (v) => ctl.selectChars(rxUuid: v)),
          TextButton(
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () async {
              await ctl.selectChars(auto: true);
              if (mounted) setState(() {});
            },
            child: const Text('恢复自动', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _bleCharPick(String label, String? cur, List<BleCharOption> opts,
      Future<void> Function(String) onPick) {
    final ids = [for (final o in opts) o.uuid];
    final v = (cur != null && ids.contains(cur)) ? cur : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: const TextStyle(fontSize: 12)),
        DropdownButton<String>(
          value: v,
          hint: const Text('未选', style: TextStyle(fontSize: 12)),
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          items: [
            for (final o in opts)
              DropdownMenuItem(
                  value: o.uuid,
                  child: Text(o.label, style: const TextStyle(fontSize: 12))),
          ],
          onChanged: (x) async {
            if (x == null) return;
            await onPick(x);
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }

  void _syncRelayConfig() {
    final sess = _sess;
    final mode = _channel.relayMode;
    sess.setChannelMode(mode, chan: _channel.name);
    // TCP 模式下不下发 COM 参数(与 Web 端一致: 仅 serial 带 cfg)
    sess.relay?.sendSerialConfig(sess.cfg, mode, sess.agg);
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
    // 暂停时不进行快速匹配(与 Web/桌面端一致)
    if (!sess.paused) {
      context.read<SnifferController>().feed(raw, false, sess.cfg.encoding);
    }
    sess.relay?.sendSerialData(raw);
  }

  void _cancelRx() {
    _rxTimer?.cancel();
    _rxTimer = null;
    _rxBuf.clear();
  }

  // 通道状态: 异常(如 Android usb_serial 报错) 或自行结束(如 TCP 对端关闭)时作废端口,
  // 使固定/轮询发送失败并停止, 并让链接端看到"未打开"
  void _onPortState(SerialState st) {
    if (st == SerialState.error) {
      _sess.addLog('错误', '${_channel.isSerial ? '串口' : '通道'}异常, 已停止发送');
      _abortPort();
      return;
    }
    if (st == SerialState.closed && _port != null) {
      // _close() 会先置空 _port 再关闭, 所以这里只处理"通道自己断了"的情况
      _sess.addLog('系统', '${_channel.label}通道已断开');
      _abortPort();
    }
  }

  // 作废当前端口(不等待底层 close), 供异常路径复用
  void _abortPort() {
    _cancelRx();
    _dataSub?.cancel();
    _dataSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _logSub?.cancel();
    _logSub = null;
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
    _logSub?.cancel();
    _logSub = null;
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
      if (!sess.paused) sniffer.feed(bytes, true, sess.cfg.encoding);
      // 链接端显示为 "共享端发送"
      sess.relay?.sendSerialData(bytes, kind: 'tx');
    } catch (e) {
      sess.addLog('系统', '发送失败: $e');
    }
  }

  // 一键分享: 复制「含房间码/密码的链接端网页链接」并可直接打开
  // (与 Web share.js / 桌面端 _build_share_links 生成的链接格式一致)
  String _shareWebUrl(String room, String pwd) {
    var base = _sess.getServerUrl().trim();
    if (base.startsWith('wss://')) {
      base = 'https://${base.substring(6)}';
    } else if (base.startsWith('ws://')) {
      base = 'http://${base.substring(5)}';
    }
    // WS 端点后缀 /ws 换成网页入口
    if (base.endsWith('/ws')) base = base.substring(0, base.length - 3);
    base = base.replaceAll(RegExp(r'/+$'), '');
    final buf = StringBuffer('mode=link&room=${Uri.encodeComponent(room)}');
    if (pwd.isNotEmpty) buf.write('&pwd=${Uri.encodeComponent(pwd)}');
    return '$base/?$buf';
  }

  // linkcom:// 深链(安卓可直接唤起 App 并进入链接端; 桌面端可交给已注册的客户端)
  String _shareLinkcomUrl(String room, String pwd) {
    final b = StringBuffer('linkcom://?room=${Uri.encodeComponent(room)}');
    if (pwd.isNotEmpty) b.write('&pwd=${Uri.encodeComponent(pwd)}');
    b.write('&server=${Uri.encodeComponent(_sess.getServerUrl().trim())}');
    b.write('&mode=link');
    return b.toString();
  }

  Future<void> _shareLink() async {
    final room = _roomCtl.text.trim();
    if (room.isEmpty) {
      _hint('请先填写并连接房间码后再分享链接');
      return;
    }
    final pwd = _pwdCtl.text;
    final web = _shareWebUrl(room, pwd);
    // 安卓: 复制 linkcom:// 深链(点开直进链接端 App); 桌面: 复制网页链接(浏览器可用)
    final clip = Platform.isAndroid ? _shareLinkcomUrl(room, pwd) : web;
    await Clipboard.setData(ClipboardData(text: clip));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('分享链接已复制: $clip'),
      action: SnackBarAction(
        label: '打开网页端',
        onPressed: () => unawaited(launchUrl(Uri.parse(web))),
      ),
    ));
  }

  void _hint(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // 打开/关闭通道按钮 (TCP 通道); 窄屏时复用同一按钮移到「开始共享」左侧
  Widget _channelOpenBtn(ColorScheme c, {bool compact = false}) =>
      _port == null
          ? ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding:
                    compact ? const EdgeInsets.symmetric(horizontal: 10) : null,
                visualDensity: compact ? VisualDensity.compact : null,
                tapTargetSize:
                    compact ? MaterialTapTargetSize.shrinkWrap : null,
                minimumSize: Size(0, _ctlH),
              ),
              onPressed: _open,
              child: const Text('打开通道'))
          : OutlinedButton(
              onPressed: _close,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.error,
                side: BorderSide(color: c.error),
                padding:
                    compact ? const EdgeInsets.symmetric(horizontal: 10) : null,
                visualDensity: compact ? VisualDensity.compact : null,
                tapTargetSize:
                    compact ? MaterialTapTargetSize.shrinkWrap : null,
                minimumSize: Size(0, _ctlH),
              ),
              child: const Text('关闭通道'));

  // TCP 参数表单 (+ 宽屏时的打开/关闭通道按钮)
  Widget _tcpPanel(ColorScheme c) {
    final isClient = _channel == ShareChannel.tcpClient;
    final open = _port != null;
    Widget portField(String label, TextEditingController ctl, String hint) =>
        SizedBox(
          width: 120,
          child: TextField(
            controller: ctl,
            enabled: !open,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: label, hintText: hint, isDense: true),
          ),
        );
    // 窄屏时「打开/关闭通道」移到底部「开始共享」左侧, 这里不渲染
    return LayoutBuilder(builder: (ctx, cons) {
      final narrow = cons.maxWidth <= 460;
      return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (isClient) ...[
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _tcRemoteHost,
                  enabled: !open,
                  decoration: const InputDecoration(
                      labelText: '远端主机', isDense: true),
                ),
              ),
              portField('远端端口', _tcRemotePort, ''),
            ],
            _ipField(
              isClient ? '本地出口IP' : '监听IP',
              isClient ? _tcLocalIp : _tsLocalIp,
              open,
              isClient ? '(默认)' : '0.0.0.0 (全部)',
              (v) => setState(() {
                if (isClient) {
                  _tcLocalIp = v;
                } else {
                  _tsLocalIp = v;
                }
              }),
            ),
            if (isClient)
              portField('本地端口', _tcLocalPort, '留空随机')
            else
              portField('监听端口', _tsLocalPort, ''),
            if (!narrow) _channelOpenBtn(c),
          ],
        ),
        // const SizedBox(height: 6),
        // Text(
        //   isClient
        //       ? '作为 TCP 客户端连接远端设备; 本地出口 IP/端口用于多网卡场景(可留空)。'
        //       : '本机监听端口; 多个客户端的数据合并上行, 下发数据广播给所有客户端。',
        //   style:
        //       TextStyle(fontSize: 11, color: c.onSurface.withValues(alpha: 0.6)),
        // ),
      ],
      );
    });
  }

  // 网卡 IP 下拉 (首项为「默认/全部」, 其余为本机 IPv4)
  Widget _ipField(String label, String value, bool disabled, String none,
      ValueChanged<String> onChanged) {
    final items = <String>['', ..._localIps];
    if (value.isNotEmpty && !items.contains(value)) items.add(value);
    return SizedBox(
      width: 170,
      child: DropdownButtonFormField<String>(
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        dropdownColor: Theme.of(context).colorScheme.surface,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        value: value,
        items: [
          for (final ip in items)
            DropdownMenuItem(value: ip, child: Text(ip.isEmpty ? none : ip)),
        ],
        onChanged: disabled ? null : (x) => onChanged(x ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sess = context.watch<RelaySession>();
    // 深链指定的通道(可能晚于本页首帧到达): 依赖它以便到达时立即切换
    final pendingChannel =
        context.select<AppState, ShareChannel?>((a) => a.pendingShareChannel);
    if (pendingChannel != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final app = context.read<AppState>();
        final ch = app.pendingShareChannel;
        app.pendingShareChannel = null;
        if (ch != null && ch != _channel && _port == null) _switchChannel(ch);
      });
    }
    final c = Theme.of(context).colorScheme;
    final selId = _selected != null &&
            _ports.any((p) => p.id == _selected!.id)
        ? _selected!.id
        : null;
    // 用 SingleChildScrollView 而非 ListView: ListView 的 RenderViewport 会加双窗格语义
    // (useTwoPaneSemantics), 与内部 Tooltip 的 OverlayPortal 嫁接在 Windows 上会丢失
    // detach 通知, 触发 "Failed to update ui::AXTree ... not be in the tree" (flutter#182444)。
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        // 与 Web 共享端一致: 串口配置 + 房间(中继)配置合并为一个「房间配置」折叠面板
        CollapsiblePanel(
          title: '房间配置',
          summary: _summary(sess),
          collapseWhen: sess.wsConnected,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 通道类型: 桌面三段(COM / TCP 客户端 / TCP 服务器), 移动端四段(多一个蓝牙 BLE)
              // 无前置文字; expandedInsets 让 SegmentedButton 撑满整行, 各段等宽、文字居中
              SegmentedButton<ShareChannel>(
                expandedInsets: EdgeInsets.zero,
                segments: [
                  // 窄屏 5 段: 字号收小 + 允许两行居中, 否则 "TCP 客户端" 会被截断
                  for (final ch in _channelSegments())
                    ButtonSegment(
                        value: ch,
                        label: Text(ch.shortLabel,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 11))),
                ],
                selected: {_channel},
                onSelectionChanged: _port == null
                    ? (set) => _switchChannel(set.first)
                    : null,
                showSelectedIcon: false, // 窄屏去掉勾选图标, 避免标签换行
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
              const SizedBox(height: 8),
              // 选择设备 + 打开/关闭 + 刷新/扫描 (串口 & 经典蓝牙 & BLE; 窄屏按钮紧凑化)
              if (_channel.needsPicker)
                LayoutBuilder(builder: (ctx, cons) {
                final narrow = cons.maxWidth <= 460;
                final btnPad = narrow
                    ? const EdgeInsets.symmetric(horizontal: 10)
                    : null;
                final btnDensity = narrow ? VisualDensity.compact : null;
                final btnTap = narrow ? MaterialTapTargetSize.shrinkWrap : null;
                final ble = _channel.isBle;
                final minSize = Size(0, _ctlH);
                final picker = DropdownButton<String>(
                  isExpanded: true,
                  hint: Text(ble ? '选择 BLE 设备' : '选择串口'),
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
                    ? ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          padding: btnPad,
                          visualDensity: btnDensity,
                          tapTargetSize: btnTap,
                          minimumSize: minSize,
                        ),
                        onPressed: _open,
                        child: Text(ble ? '连接' : '打开串口'))
                    : OutlinedButton(
                        onPressed: _close,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.error,
                          side: BorderSide(color: c.error),
                          padding: btnPad,
                          visualDensity: btnDensity,
                          tapTargetSize: btnTap,
                          minimumSize: minSize,
                        ),
                        child: Text(ble ? '断开' : '关闭串口'));
                final refreshBtn = ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: btnPad,
                      visualDensity: btnDensity,
                      tapTargetSize: btnTap,
                      minimumSize: minSize,
                    ),
                    onPressed: _refresh,
                    child: Text(ble ? '扫描' : '刷新'));
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: picker),
                    const SizedBox(width: 8),
                    openBtn,
                    const SizedBox(width: 8),
                    refreshBtn,
                    // BLE: 切换是否显示"已配对但未广播"的设备(默认隐藏, 见 _applyPortFilter)
                    if (ble)
                      IconButton(
                        tooltip: _showPaired ? '隐藏已配对(未广播)设备' : '显示已配对(未广播)设备',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                        iconSize: 18,
                        color: _showPaired ? c.primary : null,
                        icon: Icon(
                            _showPaired ? Icons.filter_alt : Icons.filter_alt_off),
                        onPressed: () => setState(() {
                          _showPaired = !_showPaired;
                          _applyPortFilter();
                        }),
                      ),
                  ],
                );
              }),
              // COM 物理参数(波特率/数据位/停止位/校验/流控)只对真正的串口通道有意义:
              // 经典蓝牙(SPP)/BLE 链路上不存在这些参数(波特率由模块自身 UART 决定), 故不显示。
              // 编码/聚合/缓冲 仍在下方终端工具条里(见 TerminalView)。
              // BLE: 手动指定收发特征值(适配各式模块; 连上后可用, 即时生效并按设备记住)
              if (_channel.isBle && _port is BleCharControl) _bleCharRow(c),
              if (_channel.usesComParams) ...[
                const SizedBox(height: 8),
                SerialConfigEditor(
                  initialCfg: sess.cfg,
                  initialAgg: sess.agg,
                  // 安卓 USB-OTG(CH340/CH341) 数据位/停止位改不了 → 那一项置灰并说明
                  noDataStopBits: Platform.isAndroid &&
                      _channel == ShareChannel.com,
                  onApply: (cfg, agg) {
                    sess.updateConfig(cfg, agg);
                    if (_port != null) _reopen();
                  },
                ),
              ],
              if (_channel.isTcp) _tcpPanel(c),
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
                          minimumSize: Size(0, _ctlH),
                        ),
                        child: const Text('停止共享'))
                    : ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            minimumSize: Size(0, _ctlH)),
                        onPressed: _connectRelay,
                        child: const Text('开始共享'));
                // 共享中: 在共享按钮左侧额外显示「一键分享」(分享图标)
                final Widget? shareBtn = _relayOn
                    ? IconButton(
                        tooltip: '一键分享房间链接',
                        icon: const Icon(Icons.share_outlined),
                        constraints: BoxConstraints(
                            minWidth: _ctlH, minHeight: _ctlH),
                        onPressed: () => unawaited(_shareLink()),
                      )
                    : null;
                if (cons.maxWidth <= 460) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 窄屏: 房间码 + 密码 同一行
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: roomField),
                          const SizedBox(width: 8),
                          Expanded(child: pwdField),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // 窄屏(开始共享单独一行): TCP 的「打开/关闭通道」左对齐, 分享+开始共享右对齐
                      Row(
                        children: [
                          // 仅 TCP 用这里的「打开/关闭通道」(COM/蓝牙/BLE 打开按钮在设备行里)
                          if (_channel.isTcp)
                            _channelOpenBtn(c, compact: true),
                          const Spacer(),
                          if (shareBtn != null) shareBtn,
                          startBtn,
                        ],
                      ),
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
                    if (shareBtn != null) shareBtn,
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
      if (!sess.paused) sniffer.feed(bytes, true, sess.cfg.encoding);
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
    _logSub?.cancel();
    _port?.close();
    _roomCtl.dispose();
    _pwdCtl.dispose();
    _tcRemoteHost.dispose();
    _tcRemotePort.dispose();
    _tcLocalPort.dispose();
    _tsLocalPort.dispose();
    super.dispose();
  }
}
