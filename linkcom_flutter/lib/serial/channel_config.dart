import '../models/relay_message.dart';

// 共享端可选通道 (UI 层):
//   com       串口 COM (Windows COMx / 安卓 USB-OTG)
//   classic   经典蓝牙 SPP (RFCOMM, HC-05/06 等)
//   ble       低功耗蓝牙 BLE (GATT)
//   tcpClient TCP 客户端
//   tcpServer TCP 服务器
// 桌面端只显示 com/tcpClient/tcpServer 三段; 移动端五段。
enum ShareChannel { com, classic, ble, tcpClient, tcpServer }

extension ShareChannelX on ShareChannel {
  bool get isTcp =>
      this == ShareChannel.tcpClient || this == ShareChannel.tcpServer;
  // 走"枚举设备 + 连接"流程的通道 (COM / 经典蓝牙)
  // 注意: COM 物理参数(波特率/数据位/停止位/校验/流控)只对**真正的串口**有意义 ——
  // 经典蓝牙 SPP / BLE 链路上不存在这些参数(波特率由模块自身 UART 决定), 故界面只在
  // ShareChannel.com 时显示串口参数编辑器。用 `usesComParams` 表达这个语义。
  bool get isSerial => this == ShareChannel.com || this == ShareChannel.classic;
  // 是否需要配置 COM 物理参数(仅真正的串口; 蓝牙/TCP 都不需要)
  bool get usesComParams => this == ShareChannel.com;
  bool get isBle => this == ShareChannel.ble;
  // 需要先枚举/扫描设备再打开
  bool get needsPicker => isSerial || isBle;

  // 上报给中继的通道类型 (协议只有 serial/tcpClient/tcpServer 三种)
  SerialChannelMode get relayMode => switch (this) {
        ShareChannel.tcpClient => SerialChannelMode.tcpClient,
        ShareChannel.tcpServer => SerialChannelMode.tcpServer,
        _ => SerialChannelMode.serial,
      };

  String get label => switch (this) {
        ShareChannel.com => '串口 COM',
        ShareChannel.classic => '经典蓝牙 SPP',
        ShareChannel.ble => '低功耗蓝牙 BLE',
        ShareChannel.tcpClient => 'TCP 客户端',
        ShareChannel.tcpServer => 'TCP 服务器',
      };

  // 分段按钮上的短标签(窄屏 5 段, 越短越好)
  String get shortLabel => switch (this) {
        ShareChannel.com => 'COM',
        ShareChannel.classic => 'SPP',
        ShareChannel.ble => 'BLE',
        ShareChannel.tcpClient => 'TCP 客户端',
        ShareChannel.tcpServer => 'TCP 服务器',
      };
}

// 把上报的 mode 文本还原成 UI 通道 (链接端展示用: 只能区分 serial / tcp*)
ShareChannel? shareChannelFromRelayMode(String? mode) => switch (mode) {
      'tcpClient' => ShareChannel.tcpClient,
      'tcpServer' => ShareChannel.tcpServer,
      'serial' => ShareChannel.com,
      _ => null,
    };

// 共享端上报的物理通道名 -> UI 通道 (协议字段 chan; 旧版共享端不带该字段 → 按"真串口"处理)
ShareChannel shareChanFromName(String? name) => switch (name) {
      'classic' => ShareChannel.classic,
      'ble' => ShareChannel.ble,
      _ => ShareChannel.com,
    };

// 链接端展示「共享端协议」: mode 先区分 TCP, serial 时再看物理通道(真串口 / 经典蓝牙 / BLE)
String shareChannelLabel(SerialChannelMode mode, ShareChannel chan) => switch (mode) {
      SerialChannelMode.tcpClient => 'TCP 客户端',
      SerialChannelMode.tcpServer => 'TCP 服务器',
      SerialChannelMode.serial => chan.label,
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
