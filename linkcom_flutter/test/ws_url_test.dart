import 'package:flutter_test/flutter_test.dart';
import 'package:linkcom/net/ws_client.dart';

// 服务器地址规整 / 自动补 /ws 的行为约定
void main() {
  group('normalizeServerUrl', () {
    test('路径为空或只有根路径时补 /ws', () {
      expect(normalizeServerUrl('wss://nas.example.com:8443'),
          'wss://nas.example.com:8443/ws');
      expect(normalizeServerUrl('wss://nas.example.com:8443/'),
          'wss://nas.example.com:8443/ws');
      expect(normalizeServerUrl('ws://192.168.1.10:8080'),
          'ws://192.168.1.10:8080/ws');
    });

    test('已有路径时保留, 仅去掉末尾斜杠', () {
      expect(normalizeServerUrl('wss://h/linkcom/ws'), 'wss://h/linkcom/ws');
      expect(normalizeServerUrl('wss://h/linkcom/ws/'), 'wss://h/linkcom/ws');
      expect(normalizeServerUrl('wss://h:8443/linkcom'), 'wss://h:8443/linkcom');
    });

    test('http/https 自动转 ws/wss', () {
      expect(normalizeServerUrl('https://h:8443/linkcom/ws'),
          'wss://h:8443/linkcom/ws');
      expect(normalizeServerUrl('http://h:8080/'), 'ws://h:8080/ws');
    });

    test('首尾空格被去掉, 空串原样返回', () {
      expect(normalizeServerUrl('  ws://h:9000/ws  '), 'ws://h:9000/ws');
      expect(normalizeServerUrl('   '), '');
    });
  });

  group('urlCandidates', () {
    test('路径不带 /ws 时追加补 /ws 的候选 (服务器不需要则不会用到)', () {
      expect(urlCandidates('wss://h:8443/linkcom'),
          ['wss://h:8443/linkcom', 'wss://h:8443/linkcom/ws']);
    });

    test('已以 /ws 结尾时只有一个候选 (不会多加路径)', () {
      expect(urlCandidates('wss://h:8443/linkcom/ws'),
          ['wss://h:8443/linkcom/ws']);
      expect(urlCandidates('wss://h:8443/ws'), ['wss://h:8443/ws']);
    });
  });
}
