import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'serial_config.dart';
import 'serial_service.dart';

// P2: 安卓经典蓝牙 SPP (HC-05/06 等)。
// 注意: Windows 蓝牙串口表现为虚拟 COMx, 直接走 Win32/COM 后端(SerialBackend.usb), 无需本实现。
// 蓝牙 SPP 链路本身不暴露波特率/数据位/校验等参数, 故 SerialConfig 仅作占位忽略。
class BtSerialPort implements SerialPort {
  final BluetoothConnection _conn;
  @override
  final SerialBackend backend = SerialBackend.bluetooth;
  final _stateCtrl = StreamController<SerialState>.broadcast();
  final _dataCtrl = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  BtSerialPort(this._conn);

  @override
  Stream<SerialState> get state => _stateCtrl.stream;
  @override
  Stream<Uint8List> get data => _dataCtrl.stream;

  @override
  Future<void> open(SerialConfig cfg) async {
    _stateCtrl.add(SerialState.opening);
    _sub = _conn.input?.listen(
      (d) {
        if (d.isNotEmpty) _dataCtrl.add(d);
      },
      onDone: () => _stateCtrl.add(SerialState.closed),
      onError: (_) => _stateCtrl.add(SerialState.error),
    );
    _stateCtrl.add(SerialState.open);
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    try {
      // BluetoothConnection.dispose() 返回 void, 内部自行异步收尾
      _conn.dispose();
    } catch (_) {}
    _stateCtrl.add(SerialState.closed);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    _conn.output.add(bytes);
    await _conn.output.allSent;
  }
}

class BtSerialService implements SerialService {
  Future<void> _ensureEnabled() async {
    final bt = FlutterBluetoothSerial.instance;
    try {
      final on = await bt.isEnabled;
      if (on != true) await bt.requestEnable();
    } catch (_) {
      // 无蓝牙适配器 / 权限不足时交由后续枚举或连接报错
    }
  }

  @override
  Future<List<SerialPortInfo>> listDevices() async {
    await _ensureEnabled();
    final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
    return devices
        .map((d) => SerialPortInfo(
              id: d.address,
              name: (d.name != null && d.name!.isNotEmpty)
                  ? '${d.name} (${d.address})'
                  : d.address,
              backend: SerialBackend.bluetooth,
              raw: {'address': d.address, 'name': d.name},
            ))
        .toList();
  }

  @override
  Future<SerialPort> connect(SerialPortInfo info, SerialConfig cfg) async {
    await _ensureEnabled();
    final conn = await BluetoothConnection.toAddress(info.id);
    final p = BtSerialPort(conn);
    await p.open(cfg);
    return p;
  }

  // 已配对列表基本静态, 不做热插拔事件透传
  @override
  Stream<SerialPortInfo>? get deviceEvents => null;
}
