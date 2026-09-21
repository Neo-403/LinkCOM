import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../net/relay_controller.dart';
import '../net/ws_client.dart' show normalizeServerUrl;
import '../models/relay_message.dart';
import '../serial/serial_config.dart';

// 单条日志(共享端/链接端各持一套, 互不干扰)
class LogEntry {
  final DateTime ts;
  final String dir; // 发送 / 接收 / 系统 / 错误
  final String text;
  final Uint8List? bytes; // 原始字节(用于 HEX 显示); 系统/错误日志为 null
  LogEntry(this.ts, this.dir, this.text, [this.bytes]);
}

// 日志显示模式: 文本 / HEX / 双显(文本+HEX)
enum LogMode { text, hex, both }

// 每个板块(共享端/链接端)独立的持久化键名: 避免两端互相覆盖
class SessionStorageKeys {
  final String room;
  final String pwd;
  final String cfg;
  final String agg;
  final String logMode;
  final String logShowTs;
  final String logAutoScroll;
  final String sendHex;
  final String sendCrlf;
  const SessionStorageKeys({
    required this.room,
    required this.pwd,
    required this.cfg,
    required this.agg,
    required this.logMode,
    required this.logShowTs,
    required this.logAutoScroll,
    required this.sendHex,
    required this.sendCrlf,
  });
}

// 单个板块(共享端或链接端)的中继会话: 房间码/密码/连接状态/串口参数/日志/显示/发送选项
// 全部独立, 因此共享端可一直保持共享, 链接端同时连另一房间互不影响。
class RelaySession extends ChangeNotifier {
  final SessionStorageKeys keys;
  // 服务器地址属于全局(两端共用), 运行时读取
  final String Function() getServerUrl;
  // 成功连上服务器后回调(用于记录全局服务器历史)
  final void Function(String url)? onServerConnected;

  RelaySession({
    required this.keys,
    required this.getServerUrl,
    this.onServerConnected,
  });

  // ---------- 持久化字段 ----------
  String _room = '';
  String get room => _room;
  set room(String v) {
    if (_room == v) return;
    _room = v;
    notifyListeners();
    _put(keys.room, v);
  }

  String _pwd = '';
  String get pwd => _pwd;
  set pwd(String v) {
    if (_pwd == v) return;
    _pwd = v;
    notifyListeners();
    _put(keys.pwd, v);
  }

  // 本板块的串口参数: 共享端=真实串口参数(权威); 链接端=接收/回传的参数
  SerialConfig _cfg = const SerialConfig(baudRate: 115200, encoding: 'utf8');
  SerialConfig get cfg => _cfg;
  AggConfig _agg = const AggConfig();
  AggConfig get agg => _agg;

  // 日志显示模式: 文本 / HEX / 双显(持久化)
  LogMode _logMode = LogMode.text;
  LogMode get logMode => _logMode;
  set logMode(LogMode v) {
    if (_logMode == v) return;
    _logMode = v;
    notifyListeners();
    _put(keys.logMode, v.name);
  }

  bool get logShowText => _logMode == LogMode.text || _logMode == LogMode.both;
  bool get logShowHex => _logMode == LogMode.hex || _logMode == LogMode.both;

  bool _logShowTs = false;
  bool get logShowTs => _logShowTs;
  set logShowTs(bool v) {
    if (_logShowTs == v) return;
    _logShowTs = v;
    notifyListeners();
    _put(keys.logShowTs, v);
  }

  bool _logAutoScroll = true;
  bool get logAutoScroll => _logAutoScroll;
  set logAutoScroll(bool v) {
    if (_logAutoScroll == v) return;
    _logAutoScroll = v;
    notifyListeners();
    _put(keys.logAutoScroll, v);
  }

  bool _sendHex = false;
  bool get sendHex => _sendHex;
  set sendHex(bool v) {
    if (_sendHex == v) return;
    _sendHex = v;
    notifyListeners();
    _put(keys.sendHex, v);
  }

  bool _sendCrlf = true;
  bool get sendCrlf => _sendCrlf;
  set sendCrlf(bool v) {
    if (_sendCrlf == v) return;
    _sendCrlf = v;
    notifyListeners();
    _put(keys.sendCrlf, v);
  }

  // ---------- 运行时字段 ----------
  RelayController? relay;
  RelayRole? role;
  bool _autoJoin = false; // connect=true 时连上即 join 房间; autoConnectServer=false 仅建 WS
  bool wsConnected = false;
  bool joined = false;
  bool sharePortOpen = false;
  int links = 0;
  final List<LogEntry> logs = [];
  int rxBytes = 0;
  int txBytes = 0;
  bool paused = false;
  StreamSubscription<RelayMessage>? _relaySub;
  DateTime? _lastErrAt;

  Timer? _urlApplyTimer;

  // 综合: 已加入房间 + 共享端串口已打开, 才允许发送
  bool get canSend => joined && sharePortOpen;

  // 读取本板块持久化设置并自动探测服务器(仅建 WS, 不加入房间, 用于显示连接状态)
  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _room = p.getString(keys.room) ?? _room;
      _pwd = p.getString(keys.pwd) ?? _pwd;
      final c = p.getString(keys.cfg);
      if (c != null) {
        try {
          _cfg = SerialConfig.fromJson(jsonDecode(c));
        } catch (_) {}
      }
      final a = p.getString(keys.agg);
      if (a != null) {
        try {
          _agg = AggConfig.fromJson(jsonDecode(a));
        } catch (_) {}
      }
      final lm = p.getString(keys.logMode);
      if (lm != null) {
        _logMode = LogMode.values
            .firstWhere((m) => m.name == lm, orElse: () => _logMode);
      }
      _logShowTs = p.getBool(keys.logShowTs) ?? _logShowTs;
      _logAutoScroll = p.getBool(keys.logAutoScroll) ?? _logAutoScroll;
      _sendHex = p.getBool(keys.sendHex) ?? _sendHex;
      _sendCrlf = p.getBool(keys.sendCrlf) ?? _sendCrlf;
    } catch (_) {}
    notifyListeners();
    autoConnectServer();
  }

  // 启动/地址变更后: 仅建立 WS 连接(不加入房间), 用于显示「已连服务器/未连接服务器」状态
  void autoConnectServer() {
    if (relay != null || role != null) return;
    _autoJoin = false;
    _relaySub?.cancel();
    final url = getServerUrl();
    relay = RelayController(
      url: url,
      onConnected: () {
        wsConnected = true;
        onServerConnected?.call(url);
        if (_autoJoin) relay?.join();
        notifyListeners();
      },
      onDisconnected: () {
        wsConnected = false;
        notifyListeners();
      },
      onError: (e) {
        // 仅服务器探测: 不显示失败日志, 仅反映 wsConnected 状态
        if (_autoJoin) _logRelayError(e);
      },
      onInfo: (m) => addLog('系统', m),
    );
    _relaySub = relay!.messages.listen(_onRelay);
    relay!.connect(room: '', pwd: '', role: RelayRole.link); // 仅建 WS, 不 join 房间
  }

  // 连接并加入房间(共享端用 share, 链接端用 link)
  void connect(
      {required String room, required String pwd, required RelayRole role}) {
    this.room = room;
    this.pwd = pwd;
    this.role = role;
    _autoJoin = true;
    final url = getServerUrl();
    if (relay == null || relay!.url != url) {
      // 地址变化 / 首次连接: 重建 WS 并重新挂载消息监听
      relay?.dispose();
      _relaySub?.cancel();
      relay = RelayController(
        url: url,
        onConnected: () {
          wsConnected = true;
          onServerConnected?.call(url);
          if (_autoJoin) relay?.join();
          notifyListeners();
        },
        onDisconnected: () {
          wsConnected = false;
          notifyListeners();
        },
        onError: (e) => _logRelayError(e),
        onInfo: (m) => addLog('系统', m),
      );
      _relaySub = relay!.messages.listen(_onRelay);
    }
    // 复用已有 WS(如启动探测连接)时, 先更新目标房间/角色, 避免用空房间 join;
    // 已有消息监听保持有效(不取消, 否则会话将不再处理中继消息)
    relay!.setTarget(room: room, pwd: pwd, role: role);
    if (relay!.connected) {
      relay!.join();
      notifyListeners();
    } else {
      relay!.connect(room: room, pwd: pwd, role: role);
    }
    addLog('系统',
        '连接中继: ${normalizeServerUrl(url)} (房间 $room, 角色 ${role.name})');
  }

  void disconnect() {
    _urlApplyTimer?.cancel();
    _autoJoin = false;
    relay?.sendBye();
    relay?.dispose();
    relay = null;
    _relaySub?.cancel();
    _relaySub = null;
    joined = false;
    sharePortOpen = false;
    links = 0;
    role = null;
    wsConnected = false;
    notifyListeners();
    addLog('系统', '已断开中继');
  }

  // 服务器地址变更后: 本板块若有活跃连接则重建以刷新状态(防抖 700ms)
  void onServerUrlChanged() {
    if (relay == null) return;
    _urlApplyTimer?.cancel();
    _urlApplyTimer = Timer(const Duration(milliseconds: 700), () {
      if (relay == null) return;
      if (role != null) {
        connect(room: room, pwd: pwd, role: role!);
      } else {
        relay?.dispose();
        relay = null;
        _relaySub?.cancel();
        autoConnectServer();
      }
    });
  }

  void _onRelay(RelayMessage m) {
    // 串口数据由共享端/链接端各自的 UI 层处理, 这里跳过以免每条数据都触发整页重建
    if (m.t == 'serial-data') return;
    switch (m.t) {
      case 'ok':
        joined = true;
        if (m.peers != null) {
          sharePortOpen = m.peers?['sharePortOpen'] == true;
          links = (m.peers?['links'] as int?) ?? 0;
        }
        // 链接端加入后立即向服务器查询权威串口状态, 双保险消除"连接时不同步"
        if (role == RelayRole.link) relay?.sendSerialStateQuery();
        addLog('系统', '加入房间成功: ${m.room}');
        break;
      case 'err':
        addLog('错误', m.msg ?? '未知错误');
        break;
      case 'peers':
        sharePortOpen = m.peers?['sharePortOpen'] == true;
        links = (m.peers?['links'] as int?) ?? 0;
        break;
      case 'serial-state':
        sharePortOpen = m.portOpen ?? sharePortOpen;
        break;
      case 'serial-config':
        // 链接端接收共享端下发的串口参数 + 通道类型(共享端收到链接端回传由 ShareScreen 负责)
        if (role == RelayRole.link && m.from == 'share') {
          try {
            if (m.cfg != null) _cfg = SerialConfig.fromJson(m.cfg!);
            if (m.agg != null) _agg = AggConfig.fromJson(m.agg!);
          } catch (e) {
            addLog('错误', '解析串口配置失败: $e');
          }
          // 共享端为 TCP 时不会下发 cfg, 只有 mode; 据此切换链接端的参数面板
          final cm = switch (m.mode) {
            'tcpClient' => SerialChannelMode.tcpClient,
            'tcpServer' => SerialChannelMode.tcpServer,
            'serial' => SerialChannelMode.serial,
            _ => null,
          };
          if (cm != null) _channelMode = cm;
          if (m.portOpen != null) sharePortOpen = m.portOpen!;
        }
        break;
      case 'closed':
        sharePortOpen = false; // 共享端已断开, 避免残留"串口已开"
        links = 0;
        addLog('系统', '对端断开: ${m.msg ?? ''}');
        break;
    }
    notifyListeners();
  }

  void _logRelayError(Object e) {
    final now = DateTime.now();
    if (_lastErrAt != null && now.difference(_lastErrAt!).inSeconds < 5) {
      return;
    }
    _lastErrAt = now;
    addLog('错误', '中继连接失败: $e');
  }

  void addLog(String dir, String text, {Uint8List? bytes}) {
    if (bytes != null) {
      // 字节计数按方向语义归类(与 Web 一致): 本端/链接端发出的算发送, 收到的算接收
      if (dir == '←接收' || dir == '共享端发送') {
        rxBytes += bytes.length;
      } else if (dir == '→发送' || dir == 'Link_发送') {
        txBytes += bytes.length;
      }
    }
    logs.add(LogEntry(DateTime.now(), dir, text, bytes));
    if (logs.length > 5000) logs.removeAt(0);
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    rxBytes = 0;
    txBytes = 0;
    notifyListeners();
  }

  // 共享端: 设置本机串口打开状态
  void setPortOpen(bool v) {
    if (sharePortOpen == v) return;
    sharePortOpen = v;
    notifyListeners();
  }

  // 更新本板块串口参数: 共享端向所有链接端广播; 链接端回传共享端 (按当前角色)
  void updateConfig(SerialConfig cfg, AggConfig agg) {
    _cfg = cfg;
    _agg = agg;
    notifyListeners();
    _putJson(keys.cfg, cfg.toJson());
    _putJson(keys.agg, agg.toJson());
    if (role == RelayRole.share && joined) {
      relay?.sendSerialConfig(cfg, channelMode, agg);
    } else if (role == RelayRole.link && joined) {
      relay?.sendSerialConfigLink(cfg, agg, channelMode);
    }
  }

  // 共享端当前通道类型(串口 / TCP 客户端 / TCP 服务器); 链接端保存共享端下发的类型
  SerialChannelMode _channelMode = SerialChannelMode.serial;
  SerialChannelMode get channelMode => _channelMode;
  void setChannelMode(SerialChannelMode m) {
    if (_channelMode == m) return;
    _channelMode = m;
    notifyListeners();
  }

  Future<void> _put(String k, Object v) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (v is String) {
        await p.setString(k, v);
      } else if (v is int) {
        await p.setInt(k, v);
      } else if (v is bool) {
        await p.setBool(k, v);
      }
    } catch (_) {}
  }

  Future<void> _putJson(String k, Map<String, dynamic> v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(k, jsonEncode(v));
    } catch (_) {}
  }

  @override
  void dispose() {
    _urlApplyTimer?.cancel();
    _relaySub?.cancel();
    relay?.dispose();
    super.dispose();
  }
}
