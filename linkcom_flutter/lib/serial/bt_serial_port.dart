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
    // 当前仅列出「已配对」设备(getBondedDevices); 附近未配对设备需先做经典蓝牙扫描
    final devices = await FlutterBluetoothSerial.instance.getBondedDevices();
    return devices
        .map((d) {
          // 重要: 已配对的 **BLE 设备也会出现在已配对列表**里(如手环/FNB48 这类),
          // 它们不提供经典 SPP, 用 RFCOMM 连必然报 "read failed, socket might closed"。
          final le = d.type == BluetoothDeviceType.le;
          final nm = (d.name != null && d.name!.isNotEmpty) ? d.name : d.address;
          return SerialPortInfo(
            id: d.address,
            name: '$nm (${d.address})${le ? ' · BLE设备, 请切到 BLE 通道' : ''}',
            backend: SerialBackend.bluetooth,
            raw: {
              'address': d.address,
              'name': d.name,
              'bonded': true,
              'le': le,
            },
          );
        })
        .toList();
  }

  // 已配对设备先用安全 RFCOMM(可加密), 失败再退回非安全 RFCOMM;
  // 未配对设备直接用非安全 RFCOMM(免系统配对, 与"直接连附近设备"的 App 一致)
  @override
  Future<SerialPort> connect(SerialPortInfo info, SerialConfig cfg) async {
    await _ensureEnabled();
    // 纯 BLE 设备没有 SPP 服务, 直接给出结论, 避免白等两次 RFCOMM 超时
    if (info.raw['le'] == true) {
      throw Exception('该设备是低功耗蓝牙(BLE)设备, 不提供经典蓝牙 SPP 服务, '
          '请切换到「BLE」通道连接');
    }
    final bonded = info.raw['bonded'] == true;
    final attempts = bonded ? const [false, true] : const [true];
    Object? lastErr;
    for (final insecure in attempts) {
      try {
        final conn =
            await BluetoothConnection.toAddress(info.id, insecure: insecure);
        final p = BtSerialPort(conn);
        await p.open(cfg);
        return p;
      } catch (e) {
        lastErr = e;
      }
    }
    throw Exception(_btHint(lastErr, bonded));
  }

  // 把插件的原始异常翻译成可操作的提示
  static String _btHint(Object? e, bool bonded) {
    final s = e?.toString() ?? '';
    if (s.contains('read failed') || s.contains('socket might closed')) {
      return '蓝牙连接失败: 设备未应答 SPP(RFCOMM) 连接。常见原因: '
          '${bonded ? '配对信息已失效' : '设备未配对'} / 已被其它主机连接 / '
          '不在范围内 / 不是经典蓝牙 SPP 设备(如 BLE-only)。';
    }
    if (s.contains('already connected')) return '蓝牙连接失败: 该设备已被本机其它连接占用';
    return '蓝牙连接失败: $e';
  }

  // 已配对列表基本静态, 不做热插拔事件透传
  @override
  Stream<SerialPortInfo>? get deviceEvents => null;
}
