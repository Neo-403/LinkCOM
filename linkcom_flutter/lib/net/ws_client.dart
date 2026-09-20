import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/relay_message.dart';

typedef RelayHandler = void Function(RelayMessage msg);

// 中继 WebSocket 客户端: 对接 server.js, 自动重连 + 心跳
class WsClient {
  WsClient({
    required this.url,
    required this.onMessage,
    this.onConnected,
    this.onDisconnected,
    this.onError,
  });
  final String url;
  final RelayHandler onMessage;
  final void Function()? onConnected;
  final void Function()? onDisconnected;
  final void Function(Object)? onError;

  WebSocketChannel? _ch;
  bool _connected = false;
  bool _connecting = false;
  bool _closedByUser = false;
  Timer? _reconnectTimer;
  Timer? _heartbeat;

  bool get connected => _connected;

  // 地址是否可用: 必须是 ws:// 或 wss:// 且有主机名
  bool get _urlOk {
    final u = Uri.tryParse(url.trim());
    return u != null &&
        (u.scheme == 'ws' || u.scheme == 'wss') &&
        u.host.isNotEmpty;
  }

  void connect() {
    _closedByUser = false;
    if (_connected || _connecting) return; // 已连/连接中: 不重复建连
    _open();
  }

  void _open() {
    if (_connected || _connecting) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // 空/非法地址直接不连接: 否则 WebSocketChannel 会抛出未捕获的
    // WebSocketChannelException(经 ready future 异步抛出, try/catch 与 stream.onError 都拦不住)。
    // 也不自动重连, 待地址在设置页修正后由上层 RelaySession 重建连接。
    if (!_urlOk) {
      _connected = false;
      _connecting = false;
      onDisconnected?.call();
      onError?.call(ArgumentError(
          '中继服务器地址无效: "$url" (需以 ws:// 或 wss:// 开头)'));
      return;
    }
    WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      _connecting = false;
      _scheduleReconnect();
      return;
    }
    _ch = ch;
    _connecting = true;
    ch.stream.listen(
      (raw) {
        try {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          onMessage(RelayMessage.fromJson(j));
        } catch (_) {
          /* 忽略非法消息 */
        }
      },
      onDone: () {
        _connecting = false;
        _handleDown();
      },
      onError: (e) {
        _connecting = false;
        _handleDown(error: e);
      },
    );
    // 等握手真正完成再置为"已连接"并回调 onConnected:
    // 否则尚未连上也会乐观置真, 导致 UI(房间配置 collapseWhen)/服务器历史 误判。
    ch.ready.then((_) {
      if (_closedByUser) return;
      _connecting = false;
      if (_connected) return;
      _connected = true;
      _startHeartbeat();
      onConnected?.call();
    }).catchError((Object e) {
      _connecting = false;
      _handleDown(error: e);
    });
  }

  // 连接断开/失败: 仅当原先确为"已连接"才回调 onDisconnected, 避免未连上就误报
  void _handleDown({Object? error}) {
    final was = _connected;
    _connected = false;
    if (was) onDisconnected?.call();
    if (error != null) onError?.call(error);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _heartbeat?.cancel();
    if (_closedByUser) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), _open);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_connected) sendRaw({'t': 'ping'});
    });
  }

  void send(RelayMessage msg) {
    if (!_connected || _ch == null) return;
    _ch!.sink.add(jsonEncode({...msg.toJson(), 't': msg.t}));
  }

  void sendRaw(Map<String, dynamic> m) {
    if (!_connected || _ch == null) return;
    _ch!.sink.add(jsonEncode(m));
  }

  void dispose() {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    _ch?.sink.close();
  }
}
