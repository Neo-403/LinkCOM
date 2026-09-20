import 'dart:async';
import 'dart:typed_data';
import 'package:serial_port_win32/serial_port_win32.dart' as spw;
import 'package:win32/win32.dart';
import 'serial_config.dart';
import 'serial_service.dart';

// Windows 后端: serial_port_win32 3.0.0 (纯 Dart FFI, 读 COMx, 免插件注册)
// 覆盖 USB-TTL(CH340/CP210x/FTDI/PL2303)/CDC 及蓝牙虚拟 COMx
// 3.0.0 为拉模式(readBytes 返回 Future), 这里自起读循环把数据推入流
class Win32SerialPort implements SerialPort {
  final spw.SerialPort _port;
  @override
  final SerialBackend backend = SerialBackend.usb; // Windows 下即 COMx
  final _stateCtrl = StreamController<SerialState>.broadcast();
  final _dataCtrl = StreamController<Uint8List>.broadcast();
  bool _reading = false;

  Win32SerialPort(this._port);

  @override
  Stream<SerialState> get state => _stateCtrl.stream;
  @override
  Stream<Uint8List> get data => _dataCtrl.stream;

  static DCB_PARITY _parity(Parity p) {
    switch (p) {
      case Parity.odd:
        return ODDPARITY;
      case Parity.even:
        return EVENPARITY;
      case Parity.mark:
        return MARKPARITY;
      case Parity.space:
        return SPACEPARITY;
      case Parity.none:
        return NOPARITY;
    }
  }

  static DCB_STOP_BITS _stop(StopBits s) {
    switch (s) {
      case StopBits.onePointFive:
        return ONE5STOPBITS;
      case StopBits.two:
        return TWOSTOPBITS;
      case StopBits.one:
        return ONESTOPBIT;
    }
  }

  @override
  Future<void> open(SerialConfig cfg) async {
    _stateCtrl.add(SerialState.opening);
    // 参数已在构造时写入 DCB, 这里 await open() 真正打开端口 (openWithSettings 内部不 await, 不可靠)
    try {
      await _port.open();
    } on Object {
      // 偶发 ERROR_ACCESS_DENIED(5): 旧句柄可能尚未释放, 稍等重试一次,
      // 仍失败则向上抛出, 由 UI 显示 "打开失败"
      await Future.delayed(const Duration(milliseconds: 300));
      await _port.open();
    }
    _reading = true;
    _startReadLoop();
    _stateCtrl.add(SerialState.open);
  }

  Future<void>? _readFuture;

  void _startReadLoop() {
    _readFuture = Future(() async {
      while (_reading) {
        try {
          // 关键: dataPollingInterval 调大到 10ms, 避免默认 500us 轮询产生海量
          // FFI 定时器回调占满 Dart 事件循环导致 UI 卡死
          final data = await _port.readBytes(
            4096,
            timeout: const Duration(milliseconds: 25),
            dataPollingInterval: const Duration(milliseconds: 10),
          );
          if (data.isNotEmpty && _reading) _dataCtrl.add(data);
        } on Object {
          // 端口关闭或断开 -> 结束循环
          break;
        }
      }
    });
  }

  @override
  Future<void> close() async {
    _reading = false;
    // 先等读循环自然退出(端口被关会令 readBytes 抛异常)再真正关闭句柄,
    // 否则 pending 的 readBytes 与 close 竞争会导致下次 open 出现
    // ERROR_ACCESS_DENIED(5), 必须拔插设备才能恢复
    try {
      await _readFuture?.timeout(const Duration(milliseconds: 200));
    } on Object {
      // 忽略超时/异常
    }
    try {
      _port.close();
    } on Object {
      // 端口可能已断开(句柄失效), close 抛错不应阻断状态复位
    }
    _stateCtrl.add(SerialState.closed);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    await _port.writeBytesFromUint8List(bytes);
  }
}

class Win32SerialService implements SerialService {
  @override
  Future<List<SerialPortInfo>> listDevices() async {
    final ports = spw.SerialPort.getAvailablePorts();
    return ports
        .where((p) => p.isNotEmpty)
        .map((p) => SerialPortInfo(
              id: p,
              name: p,
              backend: SerialBackend.usb,
              raw: const {},
            ))
        .toList();
  }

  @override
  Future<SerialPort> connect(SerialPortInfo info, SerialConfig cfg) async {
    final sp = spw.SerialPort(
      info.id,
      openNow: false,
      BaudRate: cfg.baudRate,
      Parity: Win32SerialPort._parity(cfg.parity),
      StopBits: Win32SerialPort._stop(cfg.stopBits),
      ByteSize: cfg.dataBits,
    );
    final p = Win32SerialPort(sp);
    await p.open(cfg);
    return p;
  }

  @override
  Stream<SerialPortInfo>? get deviceEvents => null;
}
