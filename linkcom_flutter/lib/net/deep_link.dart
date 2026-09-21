import '../serial/channel_config.dart';

// 深链解析 (与桌面端 desktop/url_scheme.py 对齐)
//   linkcom://?room=ROOM&pwd=PWD&server=ws://host:port&mode=link|serial|tcpClient|tcpServer
// 同时兼容 Web 分享链接:
//   http(s)://host[:port][/path]/?mode=link&room=ROOM&pwd=PWD
//   (由 host/path 反推 ws(s)://host[:port][/path]/ws 作为服务器地址)
class DeepLink {
  final String? room;
  final String? pwd;
  final String? server; // ws(s)://...
  final String? mode; // link | serial | tcpClient | tcpServer

  const DeepLink({this.room, this.pwd, this.server, this.mode});

  // mode=link 表示「打开链接端」
  bool get isLink => mode == 'link';

  // 共享端通道类型 (mode=serial/classic/ble/tcpClient/tcpServer)
  ShareChannel? get shareChannel => switch (mode) {
        'tcpClient' => ShareChannel.tcpClient,
        'tcpServer' => ShareChannel.tcpServer,
        'serial' => ShareChannel.com,
        'classic' => ShareChannel.classic,
        'ble' => ShareChannel.ble,
        _ => null,
      };
}

DeepLink? parseDeepLink(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://').firstMatch(s);
  if (m == null) return null;
  final scheme = m.group(1)!.toLowerCase();
  var rest = s.substring(m.end);
  String? server;
  final q = rest.indexOf('?');

  if (scheme == 'linkcom') {
    rest = q >= 0 ? rest.substring(q + 1) : rest;
  } else if (scheme == 'http' || scheme == 'https') {
    var path = q >= 0 ? rest.substring(0, q) : rest;
    rest = q >= 0 ? rest.substring(q + 1) : '';
    // 网页入口 -> WebSocket 端点
    if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);
    path = path.replaceAll(RegExp(r'/+$'), '');
    server = '${scheme == 'https' ? 'wss' : 'ws'}://$path/ws';
  } else {
    return null;
  }

  final params = <String, String>{};
  for (final kv in rest.split('&')) {
    if (kv.isEmpty) continue;
    final i = kv.indexOf('=');
    if (i < 0) continue;
    try {
      params[Uri.decodeComponent(kv.substring(0, i))] =
          Uri.decodeComponent(kv.substring(i + 1));
    } catch (_) {
      // 非法百分号编码: 原样保留(深链来自外部 intent/命令行, 不能让解析异常拖垮启动)
      params[kv.substring(0, i)] = kv.substring(i + 1);
    }
  }
  if (params.isEmpty) return null;
  return DeepLink(
    room: params['room'],
    pwd: params['pwd'],
    server: params['server'] ?? server,
    mode: params['mode'],
  );
}
