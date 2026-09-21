import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _uid() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

// 记录时间戳 HH:mm:ss (与 Web/桌面端记录格式一致)
String _tsStr(DateTime t) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

DateTime _parseTs(String s) {
  final now = DateTime.now();
  final m = RegExp(r'^(\d{1,2}):(\d{1,2}):(\d{1,2})').firstMatch(s);
  if (m == null) return now;
  return DateTime(now.year, now.month, now.day, int.parse(m.group(1)!),
      int.parse(m.group(2)!), int.parse(m.group(3)!));
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

// 嗅探规则 (对齐 Web 端 sniffer.js)
class SnifferRule {
  String id;
  String name;
  String dir; // recv | send | both
  String mode; // keyword | extract
  String keyword;
  String matchEnc; // hex | text
  String dispEnc; // hex | text | ascii | utf8 | gbk
  int startOffset;
  int length;
  String lenOp; // > >= < <= =
  int lenVal; // 0 = 不限制
  bool accumulate;
  bool enabled;
  String dedupType; // none | match | all
  String sortKey; // time | value | count

  SnifferRule({
    required this.id,
    required this.name,
    this.dir = 'recv',
    this.mode = 'extract',
    this.keyword = '',
    this.matchEnc = 'hex',
    this.dispEnc = 'text',
    this.startOffset = 0,
    this.length = 0,
    this.lenOp = '=',
    this.lenVal = 0,
    this.accumulate = true,
    this.enabled = true,
    this.dedupType = 'match',
    this.sortKey = 'time',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'dir': dir,
        'mode': mode,
        'keyword': keyword,
        'matchEnc': matchEnc,
        'dispEnc': dispEnc,
        'startOffset': startOffset,
        'length': length,
        'lenOp': lenOp,
        'lenVal': lenVal,
        'accumulate': accumulate,
        'enabled': enabled,
        'dedupType': dedupType,
        'sortKey': sortKey,
      };

  factory SnifferRule.fromJson(Map<String, dynamic> j) => SnifferRule(
        id: j['id']?.toString() ?? _uid(),
        name: (j['name'] ?? '未命名规则').toString(),
        dir: (j['dir'] ?? 'recv').toString(),
        mode: (j['mode'] ?? 'extract').toString(),
        keyword: (j['keyword'] ?? '').toString(),
        matchEnc: (j['matchEnc'] ?? 'hex').toString(),
        dispEnc: (j['dispEnc'] ?? 'text').toString(),
        startOffset: _toInt(j['startOffset']),
        length: _toInt(j['length']),
        lenOp: (j['lenOp'] ?? '=').toString(),
        lenVal: _toInt(j['lenVal']),
        accumulate: j['accumulate'] != false,
        enabled: j['enabled'] != false,
        dedupType: (j['dedupType'] ?? (j['dedup'] == true ? 'match' : 'none')).toString(),
        sortKey: (j['sortKey'] ?? 'time').toString(),
      );
}

// 单条命中记录: 完整帧 + 高亮区间
class SnifferRecord {
  final String ruleId;
  final Uint8List raw;
  final int hlStart;
  final int hlEnd;
  final DateTime ts;
  SnifferRecord(this.ruleId, this.raw, this.hlStart, this.hlEnd, this.ts);
}

// 按去重聚合后的展示记录
class SnifferAgg {
  final Uint8List raw;
  final int hlStart;
  final int hlEnd;
  final int count;
  final DateTime firstTs;
  final DateTime lastTs;
  final List<SnifferRecord> refs;
  SnifferAgg(this.raw, this.hlStart, this.hlEnd, this.count, this.firstTs, this.lastTs, this.refs);
  int get hlLen => hlEnd - hlStart;
}

// 嗅探控制器: 规则匹配 + 记录聚合 + 持久化 (移植 Web 端 sniffer.js)
// storageKey 可自定义: 共享端/链接端分别使用不同键, 规则与记录互不干扰
class SnifferController extends ChangeNotifier {
  final String storageKey;
  SnifferController({this.storageKey = 'linkcom_sniffer'});
  List<SnifferRule> rules = [];
  final List<SnifferRecord> records = []; // 新→旧
  final Map<String, bool> collapsed = {}; // 规则折叠状态(持久化, 与 Web/桌面端一致)
  final List<int> _accRecv = [];
  final List<int> _accSend = [];
  Timer? _persistTimer;

  @override
  void dispose() {
    _persistTimer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(storageKey);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) {
          if (j['rules'] is List) {
            rules = (j['rules'] as List)
                .whereType<Map>()
                .map((e) => SnifferRule.fromJson(Map<String, dynamic>.from(e)))
                .toList();
          }
          if (j['records'] is List) {
            records.clear();
            records.addAll(_decodeRecords(j['records'] as List));
          }
          if (j['collapsed'] is Map) {
            collapsed.clear();
            for (final e in (j['collapsed'] as Map).entries) {
              collapsed[e.key.toString()] = e.value == true;
            }
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  // 记录持久化: 与 Web/桌面端互通({ruleId, rawHex, hl:{start,end}, ts})
  List<SnifferRecord> _decodeRecords(List list) {
    final out = <SnifferRecord>[];
    for (final e in list) {
      if (e is! Map) continue;
      final raw = hexToBytes((e['rawHex'] ?? '').toString());
      if (raw == null || raw.isEmpty) continue;
      final hl = e['hl'];
      var s = 0, en = raw.length;
      if (hl is Map) {
        s = _toInt(hl['start']);
        en = _toInt(hl['end']);
      } else if (hl is List && hl.length >= 2) {
        s = _toInt(hl[0]);
        en = _toInt(hl[1]);
      }
      s = s.clamp(0, raw.length);
      en = en.clamp(s, raw.length);
      out.add(SnifferRecord((e['ruleId'] ?? '').toString(), raw, s, en,
          _parseTs((e['ts'] ?? '').toString())));
    }
    return out;
  }

  Future<void> persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      // 记录仅保留最近 1000 条(与桌面端 to_storage(cap=1000) 一致)
      final recs = records
          .take(1000)
          .map((r) => {
                'ruleId': r.ruleId,
                'rawHex': bytesToHex(r.raw),
                'hl': {'start': r.hlStart, 'end': r.hlEnd},
                'ts': _tsStr(r.ts),
              })
          .toList();
      await p.setString(
          storageKey,
          jsonEncode({
            'rules': rules.map((e) => e.toJson()).toList(),
            'records': recs,
            'collapsed': collapsed,
          }));
    } catch (_) {}
  }

  // 记录变化后延时落盘: 避免每帧都写 SharedPreferences(Web 端为 scan 后立即 persist)
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 800), persist);
  }

  // ---------- 工具 ----------
  static Uint8List? hexToBytes(String s) {
    final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.isEmpty || clean.length.isOdd) return null;
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String bytesToHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  // 解码为显示文本; enc: hex|ascii|utf8|gbk|text(用终端编码)
  static String decodeField(Uint8List b, String enc, String termEnc) {
    if (enc == 'hex') return bytesToHex(b);
    if (enc == 'ascii') {
      return b.map((x) => (x >= 0x20 && x < 0x7f) ? String.fromCharCode(x) : '.').join();
    }
    final e = enc == 'text' ? termEnc : enc;
    try {
      if (e == 'gbk') return gbk_bytes.decode(b);
      return utf8.decode(b, allowMalformed: true);
    } catch (_) {
      return b.map((x) => (x >= 0x20 && x < 0x7f) ? String.fromCharCode(x) : '.').join();
    }
  }

  Uint8List? _keywordBytes(SnifferRule r, String termEnc) {
    final raw = r.keyword.trim();
    if (raw.isEmpty) return null;
    if (r.matchEnc == 'hex') return hexToBytes(raw);
    if (termEnc == 'gbk') {
      return Uint8List.fromList(gbk_bytes.encode(raw));
    }
    return Uint8List.fromList(utf8.encode(raw));
  }

  static int _indexOf(Uint8List data, Uint8List kw, int from) {
    outer:
    for (var i = from; i <= data.length - kw.length; i++) {
      for (var k = 0; k < kw.length; k++) {
        if (data[i + k] != kw[k]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static bool _lenOk(String op, int val, int len) {
    if (val == 0) return true;
    switch (op) {
      case '>':
        return len > val;
      case '>=':
        return len >= val;
      case '<':
        return len < val;
      case '<=':
        return len <= val;
      default:
        return len == val;
    }
  }

  // ---------- 数据投喂 ----------
  void feed(Uint8List buf, bool isTx, String termEnc) {
    if (buf.isEmpty) return;
    final dir = isTx ? 'send' : 'recv';
    final needAcc = rules.any((r) => r.enabled && r.accumulate);
    if (needAcc) {
      final acc = isTx ? _accSend : _accRecv;
      acc.addAll(buf);
      if (acc.length > 65536) acc.removeRange(0, acc.length - 65536);
      if (_scan(Uint8List.fromList(acc), dir, termEnc)) acc.clear();
    } else {
      _scan(buf, dir, termEnc);
    }
  }

  bool _scan(Uint8List data, String dir, String termEnc) {
    if (data.isEmpty) return false;
    var changed = false;
    for (final r in rules) {
      if (!r.enabled) continue;
      if (r.dir != 'both' && r.dir != dir) continue;
      if (r.mode == 'keyword') {
        final kw = _keywordBytes(r, termEnc);
        if (kw == null || kw.isEmpty) continue;
        var off = 0;
        while (off <= data.length - kw.length) {
          final pos = _indexOf(data, kw, off);
          if (pos < 0) break;
          if (_lenOk(r.lenOp, r.lenVal, kw.length)) {
            _push(r.id, data, pos, pos + kw.length);
            changed = true;
          }
          off = pos + kw.length;
        }
      } else {
        final start = r.startOffset;
        final len = r.length;
        if (len <= 0) continue;
        if (start < 0 || start + len > data.length) continue;
        if (!_lenOk(r.lenOp, r.lenVal, len)) continue;
        _push(r.id, data, start, start + len);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedulePersist(); // 记录变化后延时落盘(与 Web 端 scan 后 persist 一致)
    }
    return changed;
  }

  void _push(String ruleId, Uint8List frame, int hlStart, int hlEnd) {
    final top = records.isNotEmpty ? records.first : null;
    if (top != null &&
        top.ruleId == ruleId &&
        top.hlStart == hlStart &&
        top.hlEnd == hlEnd &&
        _sameBytes(top.raw, frame)) {
      return; // 同一数据重复扫描去抖
    }
    records.insert(0, SnifferRecord(ruleId, Uint8List.fromList(frame), hlStart, hlEnd, DateTime.now()));
    if (records.length > 20000) records.removeLast();
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------- 记录查询 (去重 + 排序) ----------
  List<SnifferAgg> aggsFor(SnifferRule rule, [String termEnc = 'utf8']) {
    final list = records.where((r) => r.ruleId == rule.id).toList();
    final dt = rule.dedupType;
    if (dt == 'none') {
      return list
          .map((r) => SnifferAgg(r.raw, r.hlStart, r.hlEnd, 1, r.ts, r.ts, [r]))
          .toList()
        ..sort((a, b) => _cmp(a, b, rule, termEnc));
    }
    String keyOf(SnifferRecord r) {
      if (dt == 'all') return bytesToHex(r.raw);
      // 命中区间越界时视为空 key(与 Web/桌面端 guard 一致)
      if (r.hlStart >= r.hlEnd || r.hlEnd > r.raw.length) return '';
      return bytesToHex(r.raw.sublist(r.hlStart, r.hlEnd));
    }

    final map = <String, SnifferAgg>{};
    final out = <SnifferAgg>[];
    for (final r in list) {
      final k = keyOf(r);
      final ex = map[k];
      if (ex != null) {
        final refs = [...ex.refs, r];
        if (refs.length > 50) refs.removeAt(0);
        final merged = SnifferAgg(ex.raw, ex.hlStart, ex.hlEnd, ex.count + 1, ex.firstTs, r.ts, refs);
        map[k] = merged;
        out[out.indexOf(ex)] = merged;
      } else {
        final e = SnifferAgg(r.raw, r.hlStart, r.hlEnd, 1, r.ts, r.ts, [r]);
        map[k] = e;
        out.add(e);
      }
    }
    // sortDir 与 Web/桌面端一致固定为 -1(降序)
    out.sort((a, b) => _cmp(a, b, rule, termEnc));
    return out;
  }

  int _cmp(SnifferAgg a, SnifferAgg b, SnifferRule rule, String termEnc) {
    int c;
    if (rule.sortKey == 'count') {
      c = a.count - b.count;
    } else if (rule.sortKey == 'value') {
      c = displayValueOf(a, rule, termEnc)
          .compareTo(displayValueOf(b, rule, termEnc));
    } else {
      c = a.lastTs.compareTo(b.lastTs);
    }
    return c * -1;
  }

  // 命中段按规则显示编码解码(记录行展示 + 「按值」排序, 与 Web/桌面端 displayValue 一致)
  String displayValueOf(SnifferAgg a, SnifferRule rule, String termEnc) {
    if (a.hlStart >= a.hlEnd || a.hlEnd > a.raw.length) return '';
    return decodeField(a.raw.sublist(a.hlStart, a.hlEnd), rule.dispEnc, termEnc);
  }

  // ---------- 变更 ----------
  void upsertRule(SnifferRule r) {
    final i = rules.indexWhere((x) => x.id == r.id);
    if (i < 0) {
      rules.add(r);
    } else {
      rules[i] = r;
    }
    notifyListeners();
    persist();
  }

  void removeRule(String id) {
    rules.removeWhere((x) => x.id == id);
    records.removeWhere((x) => x.ruleId == id);
    collapsed.remove(id);
    notifyListeners();
    persist();
  }

  void clearRecords([String? ruleId]) {
    if (ruleId == null) {
      records.clear();
    } else {
      records.removeWhere((x) => x.ruleId == ruleId);
    }
    notifyListeners();
  }

  void importRules(List<SnifferRule> rs) {
    rules = rs;
    notifyListeners();
    persist();
  }

  void setEnabled(SnifferRule r, bool v) {
    r.enabled = v;
    notifyListeners();
    persist();
  }

  // 规则折叠/展开(状态持久化, 与 Web 端 _collapsed 一致)
  void toggleCollapsed(String ruleId) {
    collapsed[ruleId] = !(collapsed[ruleId] ?? false);
    notifyListeners();
    persist();
  }

  int recordCount(String ruleId) => records.where((r) => r.ruleId == ruleId).length;
}
