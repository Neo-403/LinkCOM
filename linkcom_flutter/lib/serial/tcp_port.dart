import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'channel_config.dart';
import 'serial_config.dart';
import 'serial_service.dart';

// TCP 通道 (客户端 / 服务器): 与串口实现同一 SerialPort 接口,
// 因此共享端的 聚合 / 日志 / 中继转发 / 快速发送 / 快速匹配 全部无需改动。
// 另实现 ChannelLogSource: 把「已连接 / 客户端接入 / 断开」等状态以文本流上报。
// 参考桌面端 channels/tcp_client_channel.py 与 tcp_server_channel.py。

// 枚举本机 IPv4 (供 TCP 参数的网卡下拉)
// 与桌面端 net_util.list_local_ips 一致做多重兜底: 网卡枚举 -> 主机名解析 -> UDP 出口探测
Future<List<String>> listLocalIps() async {
  final out = <String>[];
  void add(Object? ip) {
    final s = ip?.toString() ?? '';
    if (s.isEmpty || s == '0.0.0.0' || s == '::') return;
    if (!out.contains(s)) out.add(s);
  }

  // 1) 网卡枚举(最全: 多网卡/多 IP 都能拿到)
  try {
    final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: true);
    for (final ni in list) {
      for (final a in ni.addresses) {
        add(a.address);
      }
    }
  } catch (_) {}

  // 2) 主机名解析兜底 (与桌面端 python 的 getaddrinfo 等价)
  if (out.isEmpty) {
    try {
      final addrs = await InternetAddress.lookup(Platform.localHostname);
      for (final a in addrs) {
        if (a.type == InternetAddressType.IPv4) add(a.address);
      }
    } catch (_) {}
  }

  // 3) 仍为空则逐个网卡接口再取一次(某些平台 IPv4 过滤会漏掉)
  if (out.isEmpty) {
    try {
      final all = await NetworkInterface.list(includeLoopback: false);
      for (final ni in all) {
        for (final a in ni.addresses) {
          if (a.type == InternetAddressType.IPv4) add(a.address);
        }
      }
    } catch (_) {}
  }

  // 与桌面端一致: 回环固定放最前(方便本机自测)
  out.remove('127.0.0.1');
  out.insert(0, '127.0.0.1');
  return out;
}

abstract class TcpPortBase implements SerialPort, ChannelLogSource {
  @override
  final SerialBackend backend = SerialBackend.tcp;
  final stateCtrl = StreamController<SerialState>.broadcast();
  final dataCtrl = StreamController<Uint8List>.broadcast();
  final _logCtrl = StreamController<String>.broadcast();

  @override
  Stream<SerialState> get state => stateCtrl.stream;
  @override
  Stream<Uint8List> get data => dataCtrl.stream;
  @override
  Stream<String> get logs => _logCtrl.stream;

  void logLine(String s) {
    if (!_logCtrl.isClosed) _logCtrl.add(s);
  }
}

// ---------- TCP 客户端 ----------
class TcpClientPort extends TcpPortBase {
  final TcpClientConfig cfg;
  Socket? _sock;
  StreamSubscription<Uint8List>? _sub;

  TcpClientPort(this.cfg);

  @override
  Future<void> open(SerialConfig _) async {
    stateCtrl.add(SerialState.opening);
    final host = cfg.remoteHost.trim();
    final port = int.tryParse(cfg.remotePort.trim()) ?? 0;
    if (host.isEmpty || port <= 0) {
      stateCtrl.add(SerialState.error);
      throw Exception('TCP 客户端需填写远端主机与端口');
    }
    final lip = cfg.localIp.trim();
    final lport = int.tryParse(cfg.localPort.trim()) ?? 0;
    try {
      final s = await Socket.connect(
        host,
        port,
        sourceAddress: (lip.isEmpty || lip == '0.0.0.0') ? null : lip,
        sourcePort: lport > 0 ? lport : 0,
        timeout: const Duration(seconds: 6),
      );
      _sock = s;
      _sub = s.listen(
        (d) => dataCtrl.add(d),
        onError: (Object e) {
          logLine('TCP 读异常: $e');
          _fail();
        },
        onDone: () {
          if (_sock != null) {
            logLine('TCP 对端关闭连接');
            _sock = null;
            stateCtrl.add(SerialState.closed);
          }
        },
      );
      logLine('TCP 已连接 -> $host:$port '
          '(本地出口 ${s.address.address}:${s.port})');
      stateCtrl.add(SerialState.open);
    } on Object catch (e) {
      _sock = null;
      stateCtrl.add(SerialState.error);
      throw Exception(_friendlyConnectError(e, lport));
    }
  }

  void _fail() {
    if (_sock == null) return;
    _sock = null;
    stateCtrl.add(SerialState.error);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final s = _sock;
    if (s == null) {
      throw Exception('TCP 未连接');
    }
    s.add(bytes);
  }

  @override
  Future<void> close() async {
    final s = _sock;
    _sock = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await s?.close();
    } catch (_) {}
    stateCtrl.add(SerialState.closed);
    logLine('TCP 客户端已关闭');
  }
}

// ---------- TCP 服务器 ----------
// 多客户端: 任一客户端的数据都合并上行; 房间下发的数据广播给所有客户端 (与桌面端一致)
class TcpServerPort extends TcpPortBase {
  final TcpServerConfig cfg;
  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSub;
  final List<Socket> _clients = [];
  // 按 socket 记录订阅: 断开时必须取消**该客户端自己**的订阅
  // (早前用 List + removeAt(last) 会误取消另一个客户端的订阅)
  final Map<Socket, StreamSubscription<Uint8List>> _subs = {};

  TcpServerPort(this.cfg);

  int get clientCount => _clients.length;

  @override
  Future<void> open(SerialConfig _) async {
    stateCtrl.add(SerialState.opening);
    final port = int.tryParse(cfg.localPort.trim()) ?? 0;
    if (port <= 0) {
      stateCtrl.add(SerialState.error);
      throw Exception('TCP 服务器需填写监听端口');
    }
    final ip = cfg.localIp.trim().isEmpty ? '0.0.0.0' : cfg.localIp.trim();
    try {
      _server = await ServerSocket.bind(ip, port);
    } on Object catch (e) {
      _server = null;
      stateCtrl.add(SerialState.error);
      throw Exception(_friendlyBindError(e, port));
    }
    _acceptSub = _server!.listen(_onClient, onError: (Object e) {
      logLine('TCP 监听异常: $e');
    });
    logLine('TCP 服务器监听中 ${_server!.address.address}:${_server!.port}');
    stateCtrl.add(SerialState.open);
  }

  void _onClient(Socket s) {
    _clients.add(s);
    logLine('TCP 客户端接入 ${s.remoteAddress.address}:${s.remotePort} '
        '(共 ${_clients.length} 个)');
    final sub = s.listen(
      (d) => dataCtrl.add(d),
      onError: (Object _) => _dropClient(s),
      onDone: () => _dropClient(s),
    );
    _subs[s] = sub;
  }

  void _dropClient(Socket s) {
    if (!_clients.remove(s)) return;
    final sub = _subs.remove(s);
    if (sub != null) {
      try {
        sub.cancel();
      } catch (_) {}
    }
    logLine('TCP 客户端断开 ${s.remoteAddress.address}:${s.remotePort} '
        '(剩 ${_clients.length} 个)');
    try {
      s.destroy();
    } catch (_) {}
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (_clients.isEmpty) {
      throw Exception('暂无 TCP 客户端接入');
    }
    for (final c in List<Socket>.of(_clients)) {
      try {
        c.add(bytes);
      } catch (_) {}
    }
  }

  @override
  Future<void> close() async {
    try {
      await _acceptSub?.cancel();
    } catch (_) {}
    _acceptSub = null;
    for (final sub in _subs.values.toList()) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    _subs.clear();
    for (final c in List<Socket>.of(_clients)) {
      try {
        c.destroy();
      } catch (_) {}
    }
    _clients.clear();
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
    stateCtrl.add(SerialState.closed);
    logLine('TCP 服务器已关闭');
  }
}

// 按通道类型构造 TCP 端口 (供共享端复用统一打开流程)
SerialPort createTcpPort(
    ShareChannel channel, TcpClientConfig client, TcpServerConfig server) {
  if (channel == ShareChannel.tcpServer) return TcpServerPort(server);
  return TcpClientPort(client);
}

// 错误信息本地化 (对齐桌面端的 WinError 10048 提示)
String _friendlyConnectError(Object e, int localPort) {
  if (e is SocketException) {
    final code = e.osError?.errorCode;
    if (code == 10048 || code == 98) {
      return 'TCP 连接失败: 本地端口 $localPort 已被占用, '
          '请改本地端口或留空随机后重试。';
    }
    return 'TCP 连接失败: ${e.osError?.message ?? e.message}';
  }
  return 'TCP 连接失败: $e';
}

String _friendlyBindError(Object e, int port) {
  if (e is SocketException) {
    final code = e.osError?.errorCode;
    if (code == 10048 || code == 98) {
      return 'TCP 监听失败: 端口 $port 已被占用。'
          '可能上一次未完全关闭, 请先「关闭通道」或换一个端口重试。';
    }
    return 'TCP 监听失败: ${e.osError?.message ?? e.message}';
  }
  return 'TCP 监听失败: $e';
}
