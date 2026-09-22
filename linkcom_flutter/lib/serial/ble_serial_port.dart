import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_tuning.dart';
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
class BleSerialPort implements SerialPort, ChannelLogSource, BleCharControl {
  final BluetoothDevice device;
  @override
  final SerialBackend backend = SerialBackend.ble;
  final _stateCtrl = StreamController<SerialState>.broadcast();
  final _dataCtrl = StreamController<Uint8List>.broadcast();
  final _logCtrl = StreamController<String>.broadcast();

  BluetoothCharacteristic? _tx; // 写(发送)
  BluetoothCharacteristic? _rx; // 通知(接收)
  List<BluetoothService> _services = const []; // 发现到的服务(手动选特征值/自动挑选用)
  List<BleCharOption> _options = const []; // 供 UI 下拉的特征值清单
  StreamSubscription<List<int>>? _valSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _closing = false;

  BleSerialPort(this.device);

  @override
  Stream<SerialState> get state => _stateCtrl.stream;
  @override
  Stream<Uint8List> get data => _dataCtrl.stream;
  // 订阅前产生的日志先缓存: open() 里的"服务/特征值清单"是在 UI 订阅之前发出的,
  // 若直接丢进 broadcast 流会被丢弃 → 这里缓存并在订阅时补发
  final _logBuf = <String>[];

  @override
  Stream<String> get logs => Stream<String>.multi((c) {
        for (final s in List<String>.from(_logBuf)) {
          c.add(s);
        }
        _logBuf.clear();
        final sub =
            _logCtrl.stream.listen(c.add, onError: c.addError, onDone: c.close);
        c.onCancel = sub.cancel;
      });

  void _log(String s) {
    if (_logCtrl.isClosed) return;
    if (_logCtrl.hasListener) {
      _logCtrl.add(s);
    } else {
      _logBuf.add(s);
    }
  }

  // 常见串口透传 UUID (按归一化后的形式比较)
  static const _nusWrite = '6e400002b5a3f393e0a9e50e24dcca9e'; // 手机写
  static const _nusNotify = '6e400003b5a3f393e0a9e50e24dcca9e'; // 手机收
  static const _ffe1 = 'ffe1'; // 0000ffe1-... (HM-10/AT-09/HC-04 等经典透传)

  // UUID 归一化(去横线小写后):
  //   0000ffe1-0000-1000-8000-00805f9b34fb -> ffe1  (标准 16 位全写)
  //   0000ffe1                              -> ffe1  (8 位写法)
  //   ffe1                                  -> ffe1  (★ flutter_blue_plus 对 16 位 UUID 只给 4 位!)
  //   6e400002b5a3f393e0a9e50e24dcca9e      -> 原样  (自定义 128 位)
  // 之前只按"前 8 位匹配全写"比较, 导致短格式(ffe1)匹配不上, 透传特征值被退化误选成别的厂商特征值。
  static String _norm(Guid u) {
    final s = u.toString().toLowerCase().replaceAll('-', '');
    const suffix = '00001000800000805f9b34fb'; // 0000xxxx-0000-1000-8000-00805f9b34fb 的后半段
    if (s.length == 8 + suffix.length && s.endsWith(suffix)) {
      return s.substring(4, 8);
    }
    if (s.length == 8 && s.startsWith('0000')) return s.substring(4);
    return s;
  }

  static bool _uuidIs(BluetoothCharacteristic c, String want) =>
      _norm(c.uuid) == want;

  // 日志用短 UUID
  static String _shortUuid(Guid u) => _norm(u);

  // 厂商自定义 16 位服务(0xFFxx): 串口透传基本都在这一段
  static bool _isVendor16(Guid u) {
    final n = _norm(u);
    return n.length == 4 && n.startsWith('ff');
  }

  // 特征值属性文本(日志用)
  static String _propText(BluetoothCharacteristic c) {
    final p = c.properties;
    final l = <String>[
      if (p.read) '读',
      if (p.write) '写',
      if (p.writeWithoutResponse) '写无回执',
      if (p.notify) '通知',
      if (p.indicate) '指示',
    ];
    return '[${l.join('|')}]';
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

    List<BluetoothService> services;
    List<BluetoothCharacteristic> chars;
    try {
      services = await device.discoverServices();
      chars = [for (final s in services) ...s.characteristics];
    } catch (e) {
      await _safeDisconnect();
      _stateCtrl.add(SerialState.error);
      throw Exception('BLE 发现服务失败: $e');
    }

    _services = services;
    _options = [
      for (final s in services)
        for (final c in s.characteristics)
          BleCharOption(_norm(c.uuid), _norm(s.uuid),
              c.properties.write || c.properties.writeWithoutResponse,
              c.properties.notify || c.properties.indicate),
    ];

    // 自动挑选; 该设备若被手动指定过收发特征值(适配非标模块) → 命中则优先用它
    final auto = _autoPick(chars);
    if (auto.$1 == null || auto.$2 == null) {
      await _safeDisconnect();
      _stateCtrl.add(SerialState.error);
      throw Exception('该 BLE 设备没有可用的收发特征值(需要 1 个可写 + 1 个通知)');
    }
    final saved = await _loadSaved();
    final tx = (saved.$1 != null ? _findChar(saved.$1!) : null) ?? auto.$1!;
    final rx = (saved.$2 != null ? _findChar(saved.$2!) : null) ?? auto.$2!;
    _tx = tx;
    // 打印全部服务/特征值(含属性): 非标透传模块挑错特征值时, 靠这几行定位
    for (final s in services) {
      final cs =
          s.characteristics.map((c) => '${_shortUuid(c.uuid)}${_propText(c)}').join(' ');
      _log('BLE 服务 ${_shortUuid(s.uuid)}${cs.isEmpty ? '' : ': $cs'}');
    }
    _log('BLE 已连接 ${device.advName.isEmpty ? device.remoteId.toString() : device.advName}');
    _log('BLE 收: ${_charLabel(rx)}  发: ${_charLabel(tx)}'
        '${saved.$1 != null || saved.$2 != null ? ' (手动指定)' : ''}');

    try {
      // setNotifyValue 返回 hasCCCD: 为 false 表示该特征值根本没有 CCCD(订阅描述符),
      // 此时插件**不报错但订阅实际不生效** —— 必须查出来, 否则表现为"永远收不到数据"。
      final hasCccd = await rx.setNotifyValue(true);
      if (!hasCccd) {
        _log('BLE 警告: ${_charLabel(rx)} 没有 CCCD 描述符, 订阅不生效(收不到数据)');
      } else {
        _log('BLE 订阅 ${_charLabel(rx)}: ${rx.isNotifying ? '已生效' : '未生效(isNotifying=false)'}');
      }
    } catch (e) {
      await _safeDisconnect();
      _stateCtrl.add(SerialState.error);
      throw Exception('BLE 订阅通知失败: $e');
    }
    _rx = rx;
    _valSub = rx.onValueReceived.listen((d) {
      if (d.isNotEmpty) _dataCtrl.add(Uint8List.fromList(d));
    });
    _stateCtrl.add(SerialState.open);
  }

  // ---------- 收发特征值: 自动挑选 + 手动指定(适配各式模块) ----------

  // 自动策略: 已知透传 UUID(NUS/FFE1) → 同一特征既能写又能通知 → 厂商 0xFFxx 服务 →
  //           第一个可写 / 第一个可通知
  (BluetoothCharacteristic?, BluetoothCharacteristic?) _autoPick(
      List<BluetoothCharacteristic> chars) {
    bool canWrite(BluetoothCharacteristic c) =>
        c.properties.write || c.properties.writeWithoutResponse;
    bool canNotify(BluetoothCharacteristic c) =>
        c.properties.notify || c.properties.indicate;
    BluetoothCharacteristic? tx;
    BluetoothCharacteristic? rx;
    for (final c in chars) {
      if (_uuidIs(c, _nusWrite) || _uuidIs(c, _ffe1)) tx ??= c;
      if (_uuidIs(c, _nusNotify) || _uuidIs(c, _ffe1)) rx ??= c;
    }
    tx ??= _firstWhere(chars, (c) => canWrite(c) && canNotify(c));
    rx ??= _firstWhere(chars, (c) => canWrite(c) && canNotify(c));
    tx ??= _firstWhere(chars, (c) => canWrite(c) && _isVendor16(c.uuid));
    rx ??= _firstWhere(chars, (c) => canNotify(c) && _isVendor16(c.uuid));
    tx ??= _firstWhere(chars, canWrite);
    rx ??= _firstWhere(chars, canNotify);
    return (tx, rx);
  }

  // 特征值显示成 "服务/特征值"(与手动选择下拉一致), 避免日志里只看到后 4 位分不清
  String _charLabel(BluetoothCharacteristic c) {
    final cu = _norm(c.uuid);
    for (final s in _services) {
      for (final x in s.characteristics) {
        if (_norm(x.uuid) == cu) return '${_norm(s.uuid)}/$cu';
      }
    }
    return cu;
  }

  BluetoothCharacteristic? _findChar(String normUuid) {
    for (final s in _services) {
      for (final c in s.characteristics) {
        if (_norm(c.uuid) == normUuid) return c;
      }
    }
    return null;
  }

  @override
  List<BleCharOption> get charOptions => _options;

  @override
  String? get txUuid => _tx == null ? null : _norm(_tx!.uuid);

  @override
  String? get rxUuid => _rx == null ? null : _norm(_rx!.uuid);

  // 按设备(MAC)记住手动指定的收发特征值
  String _prefKey(String kind) => '$kind-${device.remoteId}';

  Future<(String?, String?)> _loadSaved() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getString(_prefKey('bleTx')), p.getString(_prefKey('bleRx')));
    } catch (_) {
      return (null, null);
    }
  }

  Future<void> _save(String? tx, String? rx) async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final e in {'bleTx': tx, 'bleRx': rx}.entries) {
        final k = _prefKey(e.key);
        final v = e.value;
        if (v == null || v.isEmpty) {
          await p.remove(k);
        } else {
          await p.setString(k, v);
        }
      }
    } catch (_) {}
  }

  // 切换收发特征值: 发送直接换目标; 接收需退订旧的再订阅新的(即时生效, 不用重连)
  Future<void> _use(
      BluetoothCharacteristic? tx, BluetoothCharacteristic? rx) async {
    if (tx != null) _tx = tx;
    if (rx != null && rx.uuid != _rx?.uuid) {
      try {
        await _rx?.setNotifyValue(false);
      } catch (_) {}
      try {
        await _valSub?.cancel();
      } catch (_) {}
      _valSub = null;
      // 同上: 回读 hasCCCD / isNotifying, 让"订阅到底生效没有"在日志里可见
      final hasCccd = await rx.setNotifyValue(true);
      _valSub = rx.onValueReceived.listen((d) {
        if (d.isNotEmpty) _dataCtrl.add(Uint8List.fromList(d));
      });
      _rx = rx;
      if (!hasCccd) {
        _log('BLE 警告: ${_charLabel(rx)} 没有 CCCD 描述符, 订阅不生效(收不到数据)');
      } else if (!rx.isNotifying) {
        _log('BLE 警告: ${_charLabel(rx)} 订阅未生效(isNotifying=false)');
      }
    }
  }

  @override
  Future<void> selectChars(
      {String? txUuid, String? rxUuid, bool auto = false}) async {
    if (auto) {
      final chars = [for (final s in _services) ...s.characteristics];
      final (tx, rx) = _autoPick(chars);
      await _use(tx, rx);
      await _save(null, null);
      _log('BLE 已恢复自动选择 收: ${rx == null ? '-' : _charLabel(rx)} '
          '发: ${tx == null ? '-' : _charLabel(tx)}');
      return;
    }
    final tx = txUuid == null ? null : _findChar(txUuid);
    final rx = rxUuid == null ? null : _findChar(rxUuid);
    if (txUuid != null && tx == null) _log('未找到发送特征值: $txUuid');
    if (rxUuid != null && rx == null) _log('未找到接收特征值: $rxUuid');
    await _use(tx, rx);
    await _save(txUuid ?? this.txUuid, rxUuid ?? this.rxUuid);
    _log('BLE 已切换 收: ${_rx == null ? '-' : _charLabel(_rx!)} '
        '发: ${_tx == null ? '-' : _charLabel(_tx!)}');
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
  // 扫描时长可在设置中调整(默认 6s)
  static Duration get _scanWindow => Duration(seconds: AppTuning.bleScanSec);

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
