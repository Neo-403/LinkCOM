import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'serial_config.dart';
import 'usb_serial_port.dart';
import 'win32_serial_port.dart';
import 'bt_serial_port.dart';
import 'ble_serial_port.dart';

enum SerialBackend { usb, bluetooth, ble, tcp }

class SerialPortInfo {
  final String id;
  final String name;
  final SerialBackend backend;
  final Map<String, dynamic> raw;
  const SerialPortInfo({
    required this.id,
    required this.name,
    required this.backend,
    this.raw = const {},
  });
}

enum SerialState { closed, opening, open, error }

// 统一串口端口接口 (USB / 蓝牙共用)
abstract class SerialPort {
  SerialBackend get backend;
  Stream<SerialState> get state;
  Stream<Uint8List> get data; // 来自串口的字节流
  Future<void> open(SerialConfig cfg);
  Future<void> close();
  Future<void> write(Uint8List bytes);
}

// 通道状态文本流 (TCP 服务器上报「客户端接入/断开」等); 串口后端不实现
abstract class ChannelLogSource {
  Stream<String> get logs;
}

// 统一串口服务接口
abstract class SerialService {
  // 枚举可用串口 (USB 设备 / 已配对蓝牙)
  Future<List<SerialPortInfo>> listDevices();
  // 按信息创建并打开一个端口
  Future<SerialPort> connect(SerialPortInfo info, SerialConfig cfg);
  // 设备热插拔事件 (安卓 OTG); 不支持时返回 null
  Stream<SerialPortInfo>? get deviceEvents => null;
}

// 统一工厂: 按平台/后端返回实现
// Windows 的 USB 串口表现为 COMx, 走 serial_port_win32; 安卓走 usb_serial(OTG)
// 注: 当前静态导入 win32_serial_port (Windows-only FFI); 安卓端构建时改为条件导入即可
SerialService createSerialService(SerialBackend backend) {
  switch (backend) {
    case SerialBackend.usb:
      return Platform.isWindows ? Win32SerialService() : UsbSerialService();
    case SerialBackend.bluetooth:
      return BtSerialService();
    case SerialBackend.ble:
      return BleSerialService();
    case SerialBackend.tcp:
      // TCP 不走 SerialService(无枚举/无串口参数), 由 createTcpPort() 直接构造
      throw UnsupportedError('TCP 通道请使用 createTcpPort()');
  }
}

// ---- BLE 手动指定收发特征值(适配各式非标透传模块) ----

/// 一个可选的 BLE 特征值(UI 下拉用)
class BleCharOption {
  final String uuid; // 归一化短 UUID(选择/保存用)
  final String service; // 归一化服务 UUID
  final bool canWrite;
  final bool canNotify;
  const BleCharOption(this.uuid, this.service, this.canWrite, this.canNotify);

  String get label =>
      '$service/$uuid [${[if (canWrite) '写', if (canNotify) '通知'].join('|')}]';
}

/// 端口若支持"手动指定收发特征值"则实现本接口(BLE 用)
abstract class BleCharControl {
  List<BleCharOption> get charOptions;
  String? get txUuid; // 当前发送(写)特征值
  String? get rxUuid; // 当前接收(通知)特征值

  /// 切换收发特征值; auto=true 表示恢复自动挑选。即时生效(不需重连)并记住该设备
  Future<void> selectChars({String? txUuid, String? rxUuid, bool auto = false});
}
