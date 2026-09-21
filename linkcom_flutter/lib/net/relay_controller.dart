import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'ws_client.dart';
import '../models/relay_message.dart';
import '../serial/serial_config.dart';

// 中继控制器: 封装 WsClient, 暴露广播流 + 便捷发送方法
// 与 server.js 协议一致 (t: join/ok/err/peers/serial-data/serial-state/serial-config/closed/bye)
class RelayController {
  final String url;
  final void Function()? onConnected;
  final void Function()? onDisconnected;
  final void Function(Object)? onError;
  final void Function(String)? onInfo;
  final StreamController<RelayMessage> _incoming =
      StreamController<RelayMessage>.broadcast();
  late final WsClient _ws;
  RelayRole? role;
  bool joined = false;
  String? _room;
  String? _pwd;

  RelayController(
      {required this.url,
      this.onConnected,
      this.onDisconnected,
      this.onError,
      this.onInfo}) {
    _ws = WsClient(
      url: url,
      onMessage: (m) => _incoming.add(m),
      onConnected: () => onConnected?.call(),
      onDisconnected: () => onDisconnected?.call(),
      onError: (e) => onError?.call(e),
      onInfo: (m) => onInfo?.call(m),
    );
  }

  Stream<RelayMessage> get messages => _incoming.stream;
  bool get connected => _ws.connected;
  // 实际使用的地址(已规整: http->ws、必要时补 /ws)
  String get effectiveUrl => _ws.effectiveUrl;

  void connect({required String room, required String pwd, required RelayRole role}) {
    this.role = role;
    _room = room;
    _pwd = pwd;
    _ws.connect(); // 连接建立后由 onConnected -> join() 发送 join
  }

  // 仅更新目标房间/角色(不重连): 复用一个已建立的 WS(如启动探测连接)时使用, 避免用空房间 join
  void setTarget({required String room, required String pwd, required RelayRole role}) {
    this.role = role;
    _room = room;
    _pwd = pwd;
  }

  // 初次连接与断线自动重连后都调用, 重新加入房间以确保 ok 与串口状态同步
  void join() {
    if (_room != null && role != null) {
      _ws.send(msgJoin(_room!, role!, pwd: _pwd ?? ''));
    }
  }

  void sendSerialData(Uint8List bytes, {String? kind}) => _ws.send(RelayMessage(
      'serial-data', {'buf': base64Encode(bytes), 'kind': kind}));

  void sendSerialState(bool open) => _ws.send(msgSerialState(open));

  // 链接端加入后向服务器查询当前权威串口状态, 消除漏发/时序导致的不同步
  void sendSerialStateQuery() => _ws.send(msgSerialStateQuery());

  // chan: 共享端物理通道(com/classic/ble), 供链接端区分真串口与蓝牙(仅 serial 模式携带)
  void sendSerialConfig(SerialConfig cfg, SerialChannelMode mode, AggConfig agg,
          {String? chan}) =>
      _ws.send(msgSerialConfig(cfg, mode, agg, chan: chan));

  // 链接端回传配置给共享端, 服务器转发时带 from='link'
  // withCfg 仅当共享端是真串口(COM)时为 true; 否则只同步聚合参数
  void sendSerialConfigLink(SerialConfig cfg, AggConfig agg, SerialChannelMode mode,
          {bool withCfg = false}) =>
      _ws.send(msgSerialConfigLink(cfg, agg, mode, withCfg: withCfg));

  void sendBye() => _ws.send(msgBye());

  void dispose() {
    _ws.dispose();
    _incoming.close();
  }
}
