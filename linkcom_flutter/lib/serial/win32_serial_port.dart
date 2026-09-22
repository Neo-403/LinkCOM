import 'dart:async';
import 'dart:typed_data';
import 'dart:ffi'; // Pointer<DCB>.ref 由 dart:ffi 提供(改 DCB 实现流控)
import 'package:serial_port_win32/serial_port_win32.dart' as spw;
import 'package:win32/win32.dart';
import '../state/app_tuning.dart';
import 'serial_config.dart';
import 'serial_service.dart';

// DCB.fDtrControl / fRtsControl 取值(winbase.h)
const int _dtrControlEnable = 1; // DTR_CONTROL_ENABLE
const int _rtsControlEnable = 1; // RTS_CONTROL_ENABLE
const int _rtsControlHandshake = 2; // RTS_CONTROL_HANDSHAKE

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
    // ★ 关键修复: serial_port_win32 的工厂是 `_cache.putIfAbsent(portName, ...)`,
    // 按**端口名**缓存静态单例 —— 第二次用同一个 COMx 构造时新参数会被**静默丢弃**,
    // 实测表现为"端口永远停在首次打开的波特率"(设 9600 读 115200 反而正常、设备换 9600 全是 0x00)。
    // 所以打开后必须用库的 setter 重新下发一遍参数(其 setter 内部 GetCommState → 改字段 → SetCommState)。
    _applyCfg(cfg);
    _reading = true;
    _startReadLoop();
    _stateCtrl.add(SerialState.open);
  }

  // 打开后强制把串口参数真正写到驱动(绕过库的实例缓存), 再补上库没有实现的流控与 DTR/RTS:
  // 通用串口工具(含 Chrome Web Serial)默认都会置 DTR/RTS, 部分设备/485 模块要靠它才输出数据
  void _applyCfg(SerialConfig cfg) {
    try {
      _port.BaudRate = cfg.baudRate;
      _port.ByteSize = cfg.dataBits;
      _port.Parity = _parity(cfg.parity);
      _port.StopBits = _stop(cfg.stopBits);
    } on Object {
      // 个别驱动不支持运行时改参数: 忽略, 后续收不到正确数据会体现出来
    }
    // 放大驱动输入/输出缓冲(驱动默认常只有 4KB): 高速连续流下即使读取稍有延迟也不易溢出丢数据
    try {
      SetupComm(_port.handler, AppTuning.rxBufKb * 1024, AppTuning.rxBufKb * 1024);
    } on Object {
      // 个别驱动忽略/不支持, 忽略即可
    }
    _applyFlowControl(cfg);
    // DTR 始终置位; RTS 只在非硬件流控时手动置位(硬件流控下 RTS 由驱动按 CTS 自动控制)
    try {
      _port.setFlowControlSignal(SETDTR);
      if (cfg.flowControl != FlowControl.hardware) {
        _port.setFlowControlSignal(SETRTS);
      }
    } on Object {
      // 不支持置位信号时忽略
    }
  }

  // 流控(库没有提供 setter, 直接用 win32 的 GetCommState/SetCommState 改 DCB):
  //   hardware → RTS/CTS: fOutxCtsFlow=1 + fRtsControl=RTS_CONTROL_HANDSHAKE
  //   software → XON/XOFF: fOutX=1 + fInX=1
  //   none     → 两者都关, RTS 常开
  // 另外把 fErrorChar 关掉(否则驱动会把出错字节替换成 0x00)、fNull 关掉(不丢弃 0x00 字节)。
  void _applyFlowControl(SerialConfig cfg) {
    final h = _port.handler;
    if (h == INVALID_HANDLE_VALUE) return;
    final d = _port.dcb;
    if (GetCommState(h, d).value == false) return;
    switch (cfg.flowControl) {
      case FlowControl.hardware:
        d.ref.fOutxCtsFlow = 1;
        d.ref.fRtsControl = _rtsControlHandshake;
        d.ref.fOutX = 0;
        d.ref.fInX = 0;
      case FlowControl.software:
        d.ref.fOutxCtsFlow = 0;
        d.ref.fRtsControl = _rtsControlEnable;
        d.ref.fOutX = 1;
        d.ref.fInX = 1;
      case FlowControl.none:
        d.ref.fOutxCtsFlow = 0;
        d.ref.fRtsControl = _rtsControlEnable;
        d.ref.fOutX = 0;
        d.ref.fInX = 0;
    }
    d.ref.fOutxDsrFlow = 0;
    d.ref.fDsrSensitivity = 0;
    d.ref.fDtrControl = _dtrControlEnable;
    d.ref.fTXContinueOnXoff = 1;
    d.ref.fErrorChar = 0;
    d.ref.fNull = 0;
    d.ref.fAbortOnError = 0;
    try {
      SetCommState(h, d);
    } on Object {
      // 个别驱动拒绝修改 DCB: 忽略, 保持已写入的波特率等参数
    }
  }

  Future<void>? _readFuture;
  int _readErrors = 0;

  void _startReadLoop() {
    _readFuture = Future(() async {
      while (_reading) {
        try {
          // 关键: dataPollingInterval 默认 10ms(可在设置中调), 避免库默认 500us 轮询产生
          // 海量 FFI 定时器回调占满 Dart 事件循环导致 UI 卡死
          final data = await _port.readBytes(
            4096,
            timeout: Duration(milliseconds: AppTuning.readTimeoutMs),
            dataPollingInterval: Duration(milliseconds: AppTuning.readPollMs),
          );
          _readErrors = 0;
          if (data.isNotEmpty && _reading) _dataCtrl.add(data);
        } on Object {
          // 端口已关闭 -> 退出循环
          if (!_reading) break;
          // 瞬时驱动错误(拔插/驱动忙)先重试, 避免"界面还显示已打开, 但永远收不到数据"
          _readErrors++;
          if (_readErrors > 20) break;
          await Future.delayed(const Duration(milliseconds: 50));
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
