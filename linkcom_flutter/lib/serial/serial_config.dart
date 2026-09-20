// 串口参数模型 (与 Web 端 serial-config 一致)

// 容错解析: Web 端 <select> 下发的是字符串("115200"), Flutter 端是数字, 两者都要能解析
int _asInt(dynamic v, int def) {
  if (v == null) return def;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final s = v.trim();
    return int.tryParse(s) ?? double.tryParse(s)?.toInt() ?? def;
  }
  return def;
}

double _asDouble(dynamic v, double def) {
  if (v == null) return def;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim()) ?? def;
  return def;
}

// 归一化编码名: "UTF-8"/"utf8" -> "utf8"
String _normEnc(dynamic v) {
  final s = (v ?? 'utf8').toString().toLowerCase().replaceAll('-', '').replaceAll('_', '');
  if (s.contains('gbk') || s.contains('gb2312') || s.contains('gb18030')) return 'gbk';
  return 'utf8';
}

enum Parity { none, odd, even, mark, space }

enum StopBits { one, onePointFive, two }

enum FlowControl { none, software, hardware }

class SerialConfig {
  final int baudRate;
  final int dataBits;
  final Parity parity;
  final StopBits stopBits;
  final FlowControl flowControl;
  final String encoding; // utf8 | gbk

  const SerialConfig({
    this.baudRate = 9600,
    this.dataBits = 8,
    this.parity = Parity.none,
    this.stopBits = StopBits.one,
    this.flowControl = FlowControl.none,
    this.encoding = 'utf8',
  });

  Map<String, dynamic> toJson() => {
        'baudRate': baudRate,
        'dataBits': dataBits,
        'parity': parity.name,
        'stopBits': stopBits == StopBits.one
            ? 1
            : (stopBits == StopBits.onePointFive ? 1.5 : 2),
        'flowControl': flowControl.name, // none | software | hardware (与 Web 一致)
        'encoding': encoding,
      };

  SerialConfig copyWith({
    int? baudRate,
    int? dataBits,
    Parity? parity,
    StopBits? stopBits,
    FlowControl? flowControl,
    String? encoding,
  }) =>
      SerialConfig(
        baudRate: baudRate ?? this.baudRate,
        dataBits: dataBits ?? this.dataBits,
        parity: parity ?? this.parity,
        stopBits: stopBits ?? this.stopBits,
        flowControl: flowControl ?? this.flowControl,
        encoding: encoding ?? this.encoding,
      );

  factory SerialConfig.fromJson(Map<String, dynamic> j) => SerialConfig(
        baudRate: _asInt(j['baudRate'], 9600),
        dataBits: _asInt(j['dataBits'], 8),
        parity: Parity.values.firstWhere(
            (e) => e.name == j['parity'].toString().toLowerCase(),
            orElse: () => Parity.none),
        stopBits: () {
          final d = _asDouble(j['stopBits'], 1);
          if (d >= 2) return StopBits.two;
          if (d >= 1.5) return StopBits.onePointFive;
          return StopBits.one;
        }(),
        flowControl: FlowControl.values.firstWhere(
            (e) => e.name == j['flowControl'].toString().toLowerCase(),
            orElse: () => FlowControl.none),
        encoding: _normEnc(j['encoding']),
      );
}

// 聚合参数 (时间窗口聚合, 防止小包风暴)
class AggConfig {
  final int flushMs;
  final int maxBufKb;
  const AggConfig({this.flushMs = 80, this.maxBufKb = 4});

  Map<String, dynamic> toJson() => {'flushMs': flushMs, 'maxBufKb': maxBufKb};

  AggConfig copyWith({int? flushMs, int? maxBufKb}) =>
      AggConfig(flushMs: flushMs ?? this.flushMs, maxBufKb: maxBufKb ?? this.maxBufKb);

  factory AggConfig.fromJson(Map<String, dynamic> j) =>
      AggConfig(flushMs: _asInt(j['flushMs'], 80), maxBufKb: _asInt(j['maxBufKb'], 4));
}
