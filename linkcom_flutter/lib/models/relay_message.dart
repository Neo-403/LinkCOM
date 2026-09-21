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
  // 共享端物理通道(com/classic/ble), 仅 serial 模式下携带; 缺省视为 com(旧版共享端)
  String? get chan => _extra['chan'] as String?;
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

// chan: 共享端**物理通道**名(com/classic/ble), 仅 serial 模式下有意义。
// 链接端据此区分"共享端用的是真串口还是经典蓝牙/BLE", 从而决定是否显示 COM 参数编辑器、
// 以及是否把 COM 参数回传共享端(蓝牙/TCP 上这些参数无效)。
RelayMessage msgSerialConfig(SerialConfig cfg, SerialChannelMode mode, AggConfig agg,
        {String? chan}) =>
    RelayMessage('serial-config', {
      // TCP 通道无串口参数, 不下发 cfg(与 Web 端一致: 仅 serial 模式带 cfg)
      if (mode == SerialChannelMode.serial) 'cfg': cfg.toJson(),
      if (mode == SerialChannelMode.serial && chan != null) 'chan': chan,
      'mode': mode.name,
      'agg': agg.toJson(),
    });

// 链接端回传配置给共享端 (带链接端已知的共享通道类型)
// withCfg: 只有共享端是真串口(COM)时才回传 COM 参数 —— 否则回传的默认值(如 9600)
// 会覆盖共享端本机设置并触发它重开串口。
RelayMessage msgSerialConfigLink(SerialConfig cfg, AggConfig agg, SerialChannelMode mode,
        {bool withCfg = false}) =>
    RelayMessage('serial-config', {
      if (withCfg && mode == SerialChannelMode.serial) 'cfg': cfg.toJson(),
      'mode': mode.name,
      'agg': agg.toJson(),
    });

RelayMessage msgBye() => RelayMessage('bye');
