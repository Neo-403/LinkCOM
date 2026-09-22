import 'dart:async';
import 'dart:typed_data';
import 'package:usb_serial/usb_serial.dart';
import 'serial_config.dart';
import 'serial_service.dart';

// P1: USB 串口后端 (usb_serial 0.3.0)
// 同时支持 Windows(COMx, 经 serial_port_win32) 与 Android(OTG, 经 felHR85 UsbSerial)
// 覆盖 CH340/CP210x/FTDI/PL2303/CDC
class UsbSerialPort implements SerialPort {
  final UsbPort _port;
  @override
  final SerialBackend backend = SerialBackend.usb;
  final _stateCtrl = StreamController<SerialState>.broadcast();
  final _dataCtrl = StreamController<Uint8List>.broadcast();
  final _subs = <StreamSubscription>[];

  UsbSerialPort(this._port);

  @override
  Stream<SerialState> get state => _stateCtrl.stream;
  @override
  Stream<Uint8List> get data => _dataCtrl.stream;

  @override
  Future<void> open(SerialConfig cfg) async {
    _stateCtrl.add(SerialState.opening);
    final ok = await _port.open();
    if (ok != true) {
      _stateCtrl.add(SerialState.error);
      throw Exception('打开串口失败');
    }
    final stop = cfg.stopBits == StopBits.one
        ? UsbPort.STOPBITS_1
        : cfg.stopBits == StopBits.onePointFive
            ? UsbPort.STOPBITS_1_5
            : UsbPort.STOPBITS_2;
    final int parity;
    switch (cfg.parity) {
      case Parity.odd:
        parity = UsbPort.PARITY_ODD;
      case Parity.even:
        parity = UsbPort.PARITY_EVEN;
      case Parity.mark:
        parity = UsbPort.PARITY_MARK;
      case Parity.space:
        parity = UsbPort.PARITY_SPACE;
      case Parity.none:
        parity = UsbPort.PARITY_NONE;
    }
    await _port.setPortParameters(cfg.baudRate, cfg.dataBits, stop, parity);
    if (cfg.flowControl == FlowControl.hardware) {
      await _port.setFlowControl(UsbPort.FLOW_CONTROL_RTS_CTS);
    } else if (cfg.flowControl == FlowControl.software) {
      await _port.setFlowControl(UsbPort.FLOW_CONTROL_XON_XOFF);
    }
    // DTR/RTS 置位: 与 Windows/浏览器等通用串口工具行为一致(部分设备/485 模块靠 DTR 才输出数据);
    // 硬件流控下 RTS 由驱动按 CTS 自动控制, 不再手动置位
    try {
      await _port.setDTR(true);
      if (cfg.flowControl != FlowControl.hardware) await _port.setRTS(true);
    } catch (_) {
      // 个别设备/驱动不支持置位信号: 忽略
    }
    final sub = _port.inputStream?.listen((d) => _dataCtrl.add(d));
    if (sub != null) {
      _subs.add(sub);
    }
    _stateCtrl.add(SerialState.open);
  }

  @override
  Future<void> close() async {
    await _port.close();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _stateCtrl.add(SerialState.closed);
  }

  @override
  Future<void> write(Uint8List bytes) async => _port.write(bytes);
}

class UsbSerialService implements SerialService {
  @override
  Future<List<SerialPortInfo>> listDevices() async {
    final devices = await UsbSerial.listDevices();
    return devices
        .map((d) => SerialPortInfo(
              id: d.deviceId?.toString() ?? '${d.vid}-${d.pid}',
              name: d.productName ?? 'VID:${d.vid?.toRadixString(16)} PID:${d.pid?.toRadixString(16)}',
              backend: SerialBackend.usb,
              raw: {'vid': d.vid, 'pid': d.pid, 'deviceId': d.deviceId},
            ))
        .toList();
  }

  @override
  Future<SerialPort> connect(SerialPortInfo info, SerialConfig cfg) async {
    final devices = await UsbSerial.listDevices();
    final dev = devices.firstWhere(
      (d) => d.deviceId?.toString() == info.id,
      orElse: () => throw Exception('未找到串口: ${info.name}'),
    );
    final port = await dev.create();
    if (port == null) throw Exception('创建串口端口失败');
    final p = UsbSerialPort(port);
    await p.open(cfg);
    return p;
  }

  // 安卓 OTG 热插拔: 仅透传 "插入" 事件 (拔出由端口自身 close 处理)
  @override
  Stream<SerialPortInfo>? get deviceEvents {
    final src = UsbSerial.usbEventStream;
    if (src == null) return null;
    return src
        .where((e) => e.event == UsbEvent.ACTION_USB_ATTACHED && e.device != null)
        .map((e) => SerialPortInfo(
              id: e.device!.deviceId?.toString() ?? '',
              name: e.device!.productName ?? 'USB 设备',
              backend: SerialBackend.usb,
              raw: {'vid': e.device!.vid, 'pid': e.device!.pid, 'deviceId': e.device!.deviceId},
            ));
  }
}
