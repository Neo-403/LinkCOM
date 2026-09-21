import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'serial_config.dart';
import 'serial_service.dart';

// 安卓 12+ 扫描/连接 BLE 需要运行时申请 BLUETOOTH_SCAN / BLUETOOTH_CONNECT
// (flutter_blue_plus 只负责 ACCESS_FINE_LOCATION, 这两个要自己申请)
const _permChannel = MethodChannel('linkcom/perm');

Future<void> requestBlePermissions() async {
  if (!Platform.isAndroid) return;
  try {
    await _permChannel.invokeMethod('requestBluetooth');
  } catch (_) {
    // 原生未实现/被拒: 交给后续扫描报错提示
  }
}

// BLE (低功耗蓝牙 / GATT) 通道: 与经典 SPP(RFCOMM) 是两套完全不同的 API。
// 把「可写特征值」当发送、「通知特征值」当接收, 从而当成一个串口使用。
// 特征值映射(常规方案): 优先已知串口透传 UUID(Nordic UART / FFE0-FFE1),
// 否则取「第一个支持 notify 的当接收 + 第一个可写的当发送」。
class BleSerialPort implements SerialPort, ChannelLogSource {
  final BluetoothDevice device;
  @override
  final SerialBackend backend = SerialBackend.ble;
  final _stateCtrl = StreamController<SerialState>.broadcast();
  final _dataCtrl = StreamController<Uint8List>.broadcast();
  final _logCtrl = StreamController<String>.broadcast();

  BluetoothCharacteristic? _tx; // 写(发送)
  StreamSubscription<List<int>>? _valSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _closing = false;

  BleSerialPort(this.device);

  @override
  Stream<SerialState> get state => _stateCtrl.stream;
  @override
  Stream<Uint8List> get data => _dataCtrl.stream;
  @override
  Stream<String> get logs => _logCtrl.stream;

  void _log(String s) {
    if (!_logCtrl.isClosed) _logCtrl.add(s);
  }

  // 常见串口透传 UUID
  static const _nusWrite = '6e400002b5a3f393e0a9e50e24dcca9e'; // 手机写
  static const _nusNotify = '6e400003b5a3f393e0a9e50e24dcca9e'; // 手机收
  static const _ffe1 = '0000ffe1';

  // 只比较前 8 位十六进制(兼容 16 位短 UUID 与 128 位全写)
  static bool _uuidHead(BluetoothCharacteristic c, String want) {
    final s = c.uuid.toString().toLowerCase().replaceAll('-', '');
    return s == want || s.startsWith(want.substring(0, 8));
  }

  @override
  Future<void> open(SerialConfig _) async {
    _stateCtrl.add(SerialState.opening);
    try {
      // flutter_blue_plus 2.x 需要声明 license(非商业用途用 nonprofit)
      await device.connect(
          license: License.nonprofit, timeout: const Duration(seconds: 20));
    } catch (e) {
      _stateCtrl.add(SerialState.error);
      throw Exception('BLE 连接失败: $e');
    }
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && !_closing) {
        _log('BLE 连接已断开');
        _stateCtrl.add(SerialState.closed);
      }
    });

    List<BluetoothCharacteristic> chars;
    try {
      final services = await device.discoverServices();
      chars = [for (final s in services) ...s.characteristics];
    } catch (e) {
      await _safeDisconnect();
      _stateCtrl.add(SerialState.error);
      throw Exception('BLE 发现服务失败: $e');
    }

    BluetoothCharacteristic? tx;
    BluetoothCharacteristic? rx;
    for (final c in chars) {
      if (_uuidHead(c, _nusWrite) || _uuidHead(c, _ffe1)) tx ??= c;
      if (_uuidHead(c, _nusNotify) || _uuidHead(c, _ffe1)) rx ??= c;
    }
    tx ??= _firstWhere(chars, (c) => c.properties.write || c.properties.writeWithoutResponse);
    rx ??= _firstWhere(chars, (c) => c.properties.notify || c.properties.indicate);

    if (tx == null || rx == null) {
      await _safeDisconnect();
      _stateCtrl.add(SerialState.error);
      throw Exception('该 BLE 设备没有可用的收发特征值(需要 1 个可写 + 1 个通知)');
    }
    _tx = tx;
    _log('BLE 已连接 ${device.advName.isEmpty ? device.remoteId.toString() : device.advName}');
    _log('BLE 收: ${rx.uuid}  发: ${tx.uuid}');

    try {
      await rx.setNotifyValue(true);
    } catch (e) {
      await _safeDisconnect();
      _stateCtrl.add(SerialState.error);
      throw Exception('BLE 订阅通知失败: $e');
    }
    _valSub = rx.onValueReceived.listen((d) {
      if (d.isNotEmpty) _dataCtrl.add(Uint8List.fromList(d));
    });
    _stateCtrl.add(SerialState.open);
  }

  static BluetoothCharacteristic? _firstWhere(List<BluetoothCharacteristic> cs,
          bool Function(BluetoothCharacteristic) test) =>
      cs.cast<BluetoothCharacteristic?>().firstWhere(
          (c) => c != null && test(c), orElse: () => null);

  @override
  Future<void> write(Uint8List bytes) async {
    final c = _tx;
    if (c == null) throw Exception('BLE 未连接');
    // 单包不能超过 MTU-3; 用当前 MTU(未协商时为 23)分片发送
    final mtu = device.mtuNow;
    final maxLen = (mtu > 23 ? mtu - 3 : 20).clamp(20, 512);
    final withoutResponse = c.properties.writeWithoutResponse && !c.properties.write;
    for (var i = 0; i < bytes.length; i += maxLen) {
      final end = (i + maxLen) > bytes.length ? bytes.length : i + maxLen;
      await c.write(bytes.sublist(i, end), withoutResponse: withoutResponse);
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    try {
      await _valSub?.cancel();
    } catch (_) {}
    _valSub = null;
    await _safeDisconnect();
    _stateCtrl.add(SerialState.closed);
    _log('BLE 已关闭');
  }

  Future<void> _safeDisconnect() async {
    try {
      if (device.isConnected) await device.disconnect();
    } catch (_) {}
    try {
      await _connSub?.cancel();
    } catch (_) {}
    _connSub = null;
  }
}

class BleSerialService implements SerialService {
  static const _scanWindow = Duration(seconds: 6);

  // 安卓 API 级别(0 = 非安卓/取不到)
  Future<int> _androidSdk() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await _permChannel.invokeMethod<int>('sdkInt') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _ensureReady() async {
    await requestBlePermissions();
    if (!await FlutterBluePlus.isSupported) {
      throw Exception('本机不支持 BLE 低功耗蓝牙');
    }
    var st = await _currentAdapterState();
    if (st != BluetoothAdapterState.on) {
      // 蓝牙关着: 会弹系统框请求开启, 最多等 20 秒
      try {
        await FlutterBluePlus.turnOn().timeout(const Duration(seconds: 20));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 800));
      st = await _currentAdapterState();
    }
    if (st != BluetoothAdapterState.on) {
      throw Exception('请先打开手机蓝牙(当前状态: ${_stateText(st)})');
    }
  }

  // 关键: 首次调用时 adapterStateNow 往往还是 unknown(未初始化完),
  // 若直接当成"没开蓝牙"就会误报并完全跳过扫描。这里等状态流给出真实值。
  Future<BluetoothAdapterState> _currentAdapterState() async {
    var st = FlutterBluePlus.adapterStateNow;
    if (st != BluetoothAdapterState.unknown) return st;
    try {
      st = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      st = FlutterBluePlus.adapterStateNow;
    }
    return st;
  }

  static String _stateText(BluetoothAdapterState s) =>
      s.toString().split('.').last;

  // 扫描附近的 BLE 设备(按信号强度去重排序)
  // 另合并「系统已配对 / 系统已连接」的 BLE 设备: 它们往往已停止广播, 单靠扫描永远扫不到
  @override
  Future<List<SerialPortInfo>> listDevices() async {
    await _ensureReady();
    final found = <String, BluetoothDevice>{};
    final rssiOf = <String, int>{};
    final nameOf = <String, String>{};
    final nearby = <String>{}; // 真正扫描到的(在附近)
    final bondedOnly = <String>{}; // 已配对/系统已连接但没广播(不在附近)
    final sub = FlutterBluePlus.scanResults.listen((rs) {
      for (final r in rs) {
        final k = r.device.remoteId.toString();
        found[k] = r.device;
        rssiOf[k] = r.rssi;
        nearby.add(k);
        // 名字来源优先级: 广播名 > 系统缓存名(Android 已配对设备才有)
        final nm = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        if (nm.isNotEmpty) nameOf[k] = nm;
      }
    });
    try {
      // 安卓 12+ 只需 BLUETOOTH_SCAN(manifest 已加 neverForLocation);
      // 11 及以下系统强制要求定位权限才能扫到 BLE, 此时才让插件走 FINE_LOCATION
      final sdk = await _androidSdk();
      final useFine = sdk > 0 && sdk <= 30;
      // startScan 会在 timeout 到期后自行完成; 整体再兜一层超时防卡死
      await FlutterBluePlus.startScan(
        timeout: _scanWindow,
        androidUsesFineLocation: useFine,
      ).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw Exception('BLE 扫描失败: $e${_adapterHint()}');
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }

    // silent=true: 只是"已配对"但没广播(很可能不在附近) → 由界面决定是否显示
    Future<void> merge(Future<List<BluetoothDevice>> f,
        {required bool silent}) async {
      try {
        for (final d in await f) {
          final k = d.remoteId.toString();
          if (nameOf[k] == null && d.platformName.isNotEmpty) {
            nameOf[k] = d.platformName; // 系统缓存名(扫描不到广播名时的兜底)
          }
          if (found.containsKey(k)) continue;
          found[k] = d;
          rssiOf[k] = 0;
          if (silent) bondedOnly.add(k);
        }
      } catch (_) {
        // Android 12+ 未授权时可能失败, 忽略(扫描结果仍然可用)
      }
    }

    await merge(FlutterBluePlus.bondedDevices, silent: true);
    // 系统"已连接"的设备一定是可用的, 不算"不在附近"
    await merge(FlutterBluePlus.systemDevices([Guid('1800')]), silent: false);

    // 排序: 扫描到的(按信号强弱)在前, 已配对未广播的在后
    final keys = found.keys.toList()
      ..sort((a, b) {
        final na = nearby.contains(a) ? 1 : 0;
        final nb = nearby.contains(b) ? 1 : 0;
        if (na != nb) return nb - na;
        return (rssiOf[b] ?? 0).compareTo(rssiOf[a] ?? 0);
      });
    return keys.map((k) {
      final d = found[k]!;
      final r = rssiOf[k] ?? 0;
      final silent = bondedOnly.contains(k);
      final nm = (nameOf[k]?.isNotEmpty ?? false)
          ? nameOf[k]!
          : (silent ? '(未命名/已配对)' : '(未命名)');
      return SerialPortInfo(
        id: k,
        name: '$nm [$k]'
            '${r > 0 ? ' $r dBm' : ''}'
            '${silent ? ' · 已配对(未广播)' : ''}',
        backend: SerialBackend.ble,
        raw: {
          'device': d,
          'name': nm,
          'rssi': r,
          'nearby': !silent,
          'pairedSilent': silent,
        },
      );
    }).toList();
  }

  static String _adapterHint() {
    final st = FlutterBluePlus.adapterStateNow;
    if (st == BluetoothAdapterState.off) return ' (蓝牙未开启)';
    if (st == BluetoothAdapterState.unauthorized) return ' (缺少蓝牙权限, 请在系统设置里允许)';
    return st == BluetoothAdapterState.on ? '' : ' (蓝牙状态: ${_stateText(st)})';
  }

  // BLE 没有"已配对"概念: 直接连已扫描到的设备
  @override
  Future<SerialPort> connect(SerialPortInfo info, SerialConfig cfg) async {
    final dev = info.raw['device'] as BluetoothDevice?;
    if (dev == null) {
      throw Exception('请先点击「刷新」扫描到该 BLE 设备后再连接');
    }
    final p = BleSerialPort(dev);
    await p.open(cfg);
    return p;
  }

  @override
  Stream<SerialPortInfo>? get deviceEvents => null;
}
