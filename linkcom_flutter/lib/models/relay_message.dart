import '../serial/serial_config.dart';

// LinkCOM 中继协议消息模型, 与 server.js 保持一致
// t: join | ok | err | peers | serial-config | serial-state | serial-data | closed | bye

enum RelayRole { share, link }

enum SerialChannelMode { serial, tcpClient, tcpServer }

class RelayMessage {
  final String t;
  final Map<String, dynamic> _extra;

  RelayMessage(this.t, [this._extra = const {}]);

  factory RelayMessage.fromJson(Map<String, dynamic> j) =>
      RelayMessage(j['t'] as String, Map<String, dynamic>.from(j));

  Map<String, dynamic> toJson() => _extra;

  String? get room => _extra['room'] as String?;
  String? get pwd => _extra['pwd'] as String?;
  String? get role => _extra['role'] as String?;
  bool? get portOpen => _extra['portOpen'] as bool?;
  String? get buf => _extra['buf'] as String?; // base64
  Map<String, dynamic>? get cfg => _extra['cfg'] as Map<String, dynamic>?;
  Map<String, dynamic>? get agg => _extra['agg'] as Map<String, dynamic>?;
  String? get mode => _extra['mode'] as String?;
  String? get from => _extra['from'] as String?;
  String? get kind => _extra['kind'] as String?;
  String? get msg => _extra['msg'] as String?;
  Map<String, dynamic>? get peers => _extra['peers'] as Map<String, dynamic>?;
}

// ---- 构造器 ----
RelayMessage msgJoin(String room, RelayRole role, {String pwd = ''}) =>
    RelayMessage('join', {'room': room, 'role': role.name, 'pwd': pwd});

RelayMessage msgSerialData(String b64, {String? kind}) =>
    RelayMessage('serial-data', {'buf': b64, 'kind': kind});

RelayMessage msgSerialState(bool open) => RelayMessage('serial-state', {'portOpen': open});

RelayMessage msgSerialStateQuery() => RelayMessage('serial-state-query', const {});

RelayMessage msgSerialConfig(SerialConfig cfg, SerialChannelMode mode, AggConfig agg) =>
    RelayMessage('serial-config', {'cfg': cfg.toJson(), 'mode': mode.name, 'agg': agg.toJson()});

RelayMessage msgBye() => RelayMessage('bye');
