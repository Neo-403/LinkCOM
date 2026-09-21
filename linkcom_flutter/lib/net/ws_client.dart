import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/relay_message.dart';

typedef RelayHandler = void Function(RelayMessage msg);

// 服务器地址规整: 去空格; http->ws / https->wss; 路径为空时补 /ws; 去掉末尾斜杠。
// 这样用户填 wss://host:8443/linkcom 即可, 不必手动补 /ws。
String normalizeServerUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  var u = Uri.tryParse(s);
  if (u == null) return s;
  if (u.scheme == 'http') {
    s = 'ws${s.substring(4)}';
    u = Uri.parse(s);
  } else if (u.scheme == 'https') {
    s = 'wss${s.substring(5)}';
    u = Uri.parse(s);
  }
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) path = '/ws';
  return u.replace(path: path).toString();
}

// 候选地址: 先用用户填的路径; 若它没有以 /ws 结尾, 再追加一个补 /ws 的候选。
// 服务器本身不需要 /ws 时, 第一个候选就能连上, 不会多加路径。
List<String> urlCandidates(String url) {
  final list = <String>[url];
  final u = Uri.tryParse(url);
  if (u != null && u.host.isNotEmpty && !u.path.toLowerCase().endsWith('/ws')) {
    final p = u.path.isEmpty || u.path == '/' ? '/ws' : '${u.path}/ws';
    list.add(u.replace(path: p).toString());
  }
  return list;
}

// 中继 WebSocket 客户端: 对接 server.js, 自动重连 + 心跳
class WsClient {
  WsClient({
    required String url,
    required this.onMessage,
    this.onConnected,
    this.onDisconnected,
    this.onError,
    this.onInfo,
  })  : url = normalizeServerUrl(url),
        _candidates = urlCandidates(normalizeServerUrl(url));

  final String url; // 规整后的首选地址(用于显示)
  final RelayHandler onMessage;
  final void Function()? onConnected;
  final void Function()? onDisconnected;
  final void Function(Object)? onError;
  // 提示信息(如自动补 /ws 重试), 由上层记为系统日志
  final void Function(String)? onInfo;

  final List<String> _candidates;
  int _idx = 0;
  String get effectiveUrl => _candidates[_idx];

  WebSocketChannel? _ch;
  bool _connected = false;
  bool _connecting = false;
  bool _closedByUser = false;
  bool _candConnected = false; // 当前候选地址是否曾连上过
  Timer? _reconnectTimer;
  Timer? _heartbeat;

  bool get connected => _connected;

  // 地址是否可用: 必须是 ws:// 或 wss:// 且有主机名
  bool get _urlOk {
    final u = Uri.tryParse(effectiveUrl);
    return u != null && (u.scheme == 'ws' || u.scheme == 'wss') && u.host.isNotEmpty;
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
    _candConnected = false;
    WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(Uri.parse(effectiveUrl));
    } catch (e) {
      _connecting = false;
      _afterFail();
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
      _candConnected = true;
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
    _afterFail();
  }

  // 失败后处理: 当前地址没连上过且还有候选(如补 /ws 的版本) → 立刻换下一个; 否则等 2s 重连
  void _afterFail() {
    _heartbeat?.cancel();
    if (_closedByUser) return;
    if (!_candConnected && _idx + 1 < _candidates.length) {
      _idx++;
      onInfo?.call('服务器地址自动补全为 ${_candidates[_idx]} 重试');
      _open();
      return;
    }
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
