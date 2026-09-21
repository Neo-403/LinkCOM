// 中继服务器连通性探测(不改动任何状态, 不发业务数据):
//   dart run tool/ws_probe.dart wss://nas.918178.xyz:8443/linkcom/ws [房间码]
// 与 App 内部走同一条 dart:io WebSocket 通道, 用于确认 地址/证书/协议 是否可用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'wss://nas.918178.xyz:8443/linkcom/ws';
  final room = args.length > 1 ? args[1] : 'PROBE1';
  stdout.writeln('连接: $url (房间 $room)');

  final sw = Stopwatch()..start();
  WebSocket ws;
  try {
    ws = await WebSocket.connect(url).timeout(const Duration(seconds: 15));
  } catch (e) {
    stdout.writeln('握手失败(${sw.elapsedMilliseconds}ms): $e');
    exitCode = 1;
    return;
  }
  stdout.writeln('握手成功(${sw.elapsedMilliseconds}ms)');

  var got = 0;
  final done = Completer<void>();
  ws.listen((d) {
    got++;
    stdout.writeln('收到: $d');
    if (!done.isCompleted) done.complete();
  }, onDone: () {
    stdout.writeln('连接被关闭');
    if (!done.isCompleted) done.complete();
  }, onError: (e) {
    stdout.writeln('连接错误: $e');
    if (!done.isCompleted) done.complete();
  });

  ws.add(jsonEncode({'t': 'join', 'room': room, 'role': 'link', 'pwd': ''}));
  stdout.writeln('已发送 join, 等待响应...');
  await done.future.timeout(const Duration(seconds: 8), onTimeout: () {});
  stdout.writeln(got > 0
      ? 'OK: 服务器有响应, 中继可用'
      : '未收到任何响应(检查房间/协议或反代配置)');
  await ws.close();
  exitCode = got > 0 ? 0 : 2;
}
