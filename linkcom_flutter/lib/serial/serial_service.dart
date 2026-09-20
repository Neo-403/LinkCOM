import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'serial_config.dart';
import 'usb_serial_port.dart';
import 'win32_serial_port.dart';
import 'bt_serial_port.dart';

enum SerialBackend { usb, bluetooth }

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
  if (backend == SerialBackend.usb) {
    if (Platform.isWindows) return Win32SerialService();
    return UsbSerialService();
  }
  return BtSerialService();
}
