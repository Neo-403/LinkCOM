import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../background/bg_service.dart';
import '../sniffer/sniffer_controller.dart';
import 'relay_session.dart';

// 兼容历史引用: LogEntry / LogMode / RelaySession 由 relay_session.dart 提供
export 'relay_session.dart' show LogEntry, LogMode, RelaySession;

// 应用级(全局)状态: 中继服务器地址(两端共用) + 地址历史 + 主题。
// 共享端与链接端各自的会话(房间/连接/串口参数/日志/显示/发送)分别由 shareSession / linkSession 持有,
// 二者完全隔离, 因此共享端可一直保持共享, 链接端可同时连接另一个房间。
class AppState extends ChangeNotifier {
  // ---------- 全局: 中继服务器地址(两端共用) ----------
  String _serverUrl = 'ws://localhost:8080/ws';
  String get serverUrl => _serverUrl;
  set serverUrl(String v) {
    final nv = v.trim();
    if (_serverUrl == nv) return;
    _serverUrl = nv;
    notifyListeners();
    _put('serverUrl', nv);
    // 地址变更后让两端各自刷新连接状态
    shareSession.onServerUrlChanged();
    linkSession.onServerUrlChanged();
  }

  // 中继服务器地址历史(最近 5 个, 持久化)
  List<String> _serverHistory = const [];
  List<String> get serverHistory => _serverHistory;

  // ---------- 全局: 主题 ----------
  int _themeMode = 0; // 0=自动 1=白天 2=黑夜
  int get themeModeInt => _themeMode;
  ThemeMode get themeMode => ThemeMode.values[_themeMode.clamp(0, 2)];
  set themeMode(int v) {
    if (_themeMode == v) return;
    _themeMode = v;
    notifyListeners();
    _put('themeMode', v);
  }

  // ---------- 两个板块各自的独立会话 ----------
  late final RelaySession shareSession;
  late final RelaySession linkSession;

  // ---------- 两个板块各自的嗅探(规则/记录) ----------
  late final SnifferController shareSniffer;
  late final SnifferController linkSniffer;

  AppState() {
    shareSession = RelaySession(
      keys: const SessionStorageKeys(
        room: 'room',
        pwd: 'pwd',
        cfg: 'shareCfg',
        agg: 'shareAgg',
        logMode: 'logMode',
        logShowTs: 'logShowTs',
        logAutoScroll: 'logAutoScroll',
        sendHex: 'sendHex',
        sendCrlf: 'sendCrlf',
      ),
      getServerUrl: () => _serverUrl,
      onServerConnected: _recordServerHistory,
    );
    linkSession = RelaySession(
      keys: const SessionStorageKeys(
        room: 'linkRoom',
        pwd: 'linkPwd',
        cfg: 'linkCfg',
        agg: 'linkAgg',
        logMode: 'linkLogMode',
        logShowTs: 'linkLogShowTs',
        logAutoScroll: 'linkLogAutoScroll',
        sendHex: 'linkSendHex',
        sendCrlf: 'linkSendCrlf',
      ),
      getServerUrl: () => _serverUrl,
      onServerConnected: _recordServerHistory,
    );
    // 共享端沿用旧键(保留用户已存规则); 链接端独立一份, 记录/规则互不干扰
    shareSniffer = SnifferController(storageKey: 'linkcom_sniffer');
    linkSniffer = SnifferController(storageKey: 'linkcom_sniffer_link');
    // 前台保活由两个板块共同决定: 任一在共享/连接即保持, 全部断开才停止
    shareSession.addListener(_syncKeepAlive);
    linkSession.addListener(_syncKeepAlive);
    _loadPrefs();
  }

  bool _keepAliveOn = false;
  // Android 前台保活: 任一端处于共享/连接中即保持前台服务, 两端都断开才停止。
  // (拆分为两会话后, 不能再由单个会话的断开去停止保活, 否则会误停仍在共享的另一端)
  void _syncKeepAlive() {
    final want = shareSession.role != null || linkSession.role != null;
    if (want == _keepAliveOn) return;
    _keepAliveOn = want;
    if (want) {
      unawaited(startKeepAlive());
    } else {
      unawaited(stopKeepAlive());
    }
  }

  // 记录成功连过的服务器地址到历史(去重置顶, 最多 5 个)
  void _recordServerHistory(String url) {
    final u = url.trim();
    if (u.isEmpty) return;
    final list = [u, ..._serverHistory.where((e) => e != u)].take(5).toList();
    if (list.length == _serverHistory.length) {
      var same = true;
      for (var i = 0; i < list.length; i++) {
        if (list[i] != _serverHistory[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _serverHistory = list;
    _put('serverHistory', jsonEncode(list));
    notifyListeners();
  }

  void removeServerHistory(String url) {
    final list = _serverHistory.where((e) => e != url).toList();
    if (list.length == _serverHistory.length) return;
    _serverHistory = list;
    _put('serverHistory', jsonEncode(list));
    notifyListeners();
  }

  void clearServerHistory() {
    if (_serverHistory.isEmpty) return;
    _serverHistory = const [];
    _put('serverHistory', jsonEncode(const <String>[]));
    notifyListeners();
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      _serverUrl = p.getString('serverUrl') ?? _serverUrl;
      final sh = p.getString('serverHistory');
      if (sh != null) {
        try {
          _serverHistory =
              (jsonDecode(sh) as List).map((e) => e as String).toList();
        } catch (_) {}
      }
      _themeMode = p.getInt('themeMode') ?? _themeMode;
      notifyListeners();
    } catch (_) {
      // 持久化不可用时不阻塞启动
    }
    // 加载两个板块各自的会话设置并各自探测服务器
    await shareSession.load();
    await linkSession.load();
    await shareSniffer.load();
    await linkSniffer.load();
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
}
