import '../models/relay_message.dart';

// 共享端可选通道 (UI 层): COM(串口) / BLE(蓝牙 SPP) / TCP 客户端 / TCP 服务器
// 桌面端只显示 com/tcpClient/tcpServer 三段; 移动端额外拆出 ble 一段
enum ShareChannel { com, ble, tcpClient, tcpServer }

extension ShareChannelX on ShareChannel {
  bool get isTcp => this == ShareChannel.tcpClient || this == ShareChannel.tcpServer;
  bool get isSerial => this == ShareChannel.com || this == ShareChannel.ble;
  // 上报给中继的通道类型 (与 Web/桌面端协议一致)
  SerialChannelMode get relayMode => switch (this) {
        ShareChannel.tcpClient => SerialChannelMode.tcpClient,
        ShareChannel.tcpServer => SerialChannelMode.tcpServer,
        _ => SerialChannelMode.serial,
      };
  String get label => switch (this) {
        ShareChannel.com => '串口 COM',
        ShareChannel.ble => '蓝牙 BLE',
        ShareChannel.tcpClient => 'TCP 客户端',
        ShareChannel.tcpServer => 'TCP 服务器',
      };
  // 段按钮上的短标签(窄屏用)
  String get shortLabel => switch (this) {
        ShareChannel.com => 'COM',
        ShareChannel.ble => 'BLE',
        ShareChannel.tcpClient => 'TCP 客户端',
        ShareChannel.tcpServer => 'TCP 服务器',
      };
}

// 把上报的 mode 文本还原成 UI 通道 (链接端展示用)
ShareChannel? shareChannelFromRelayMode(String? mode) => switch (mode) {
      'tcpClient' => ShareChannel.tcpClient,
      'tcpServer' => ShareChannel.tcpServer,
      'serial' => ShareChannel.com,
      _ => null,
    };

// TCP 客户端参数: 字段命名与桌面端 config.json 的 tcpClient 对齐
class TcpClientConfig {
  final String localIp; // 本地出口网卡 IP, 空 = 默认路由
  final String localPort; // 本地出口端口, 空 = 随机
  final String remoteHost; // 远端主机(域名/IP)
  final String remotePort; // 远端端口
  const TcpClientConfig({
    this.localIp = '',
    this.localPort = '',
    this.remoteHost = '',
    this.remotePort = '',
  });

  bool get valid =>
      remoteHost.trim().isNotEmpty && (int.tryParse(remotePort.trim()) ?? 0) > 0;

  Map<String, dynamic> toJson() => {
        'localIp': localIp,
        'localPort': localPort,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
      };

  factory TcpClientConfig.fromJson(Map<String, dynamic> j) => TcpClientConfig(
        localIp: (j['localIp'] ?? '').toString(),
        localPort: (j['localPort'] ?? '').toString(),
        remoteHost: (j['remoteHost'] ?? '').toString(),
        remotePort: (j['remotePort'] ?? '').toString(),
      );

  TcpClientConfig copyWith(
          {String? localIp, String? localPort, String? remoteHost, String? remotePort}) =>
      TcpClientConfig(
        localIp: localIp ?? this.localIp,
        localPort: localPort ?? this.localPort,
        remoteHost: remoteHost ?? this.remoteHost,
        remotePort: remotePort ?? this.remotePort,
      );
}

// TCP 服务器参数: 字段命名与桌面端 config.json 的 tcpServer 对齐
class TcpServerConfig {
  final String localIp; // 监听网卡 IP, 空 或 0.0.0.0 = 全部网卡
  final String localPort; // 监听端口
  const TcpServerConfig({this.localIp = '', this.localPort = ''});

  bool get valid => (int.tryParse(localPort.trim()) ?? 0) > 0;

  Map<String, dynamic> toJson() => {'localIp': localIp, 'localPort': localPort};

  factory TcpServerConfig.fromJson(Map<String, dynamic> j) => TcpServerConfig(
        localIp: (j['localIp'] ?? '').toString(),
        localPort: (j['localPort'] ?? '').toString(),
      );

  TcpServerConfig copyWith({String? localIp, String? localPort}) =>
      TcpServerConfig(
        localIp: localIp ?? this.localIp,
        localPort: localPort ?? this.localPort,
      );
}
