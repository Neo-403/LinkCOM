import 'dart:io' show Platform;
import 'package:flutter_background_service/flutter_background_service.dart';

// P4: 安卓前台服务保活 — 息屏/切后台时保持进程存活, 使主 isolate 的串口读循环与 WS 不被系统回收。
// 设计取舍: 串口对象(Win32/UsbSerial)与 WS 仍运行在主 isolate, 前台服务仅负责
//   "保进程 + 静默通知"; 避免把 SerialPort 与全局状态跨 isolate 迁移带来的复杂度与不稳定。
// Windows 蓝牙为虚拟 COM 且无此机制, 非 Android 平台直接跳过 (不影响现有 Windows 版本)。
const _notifId = 888;

Future<void> initializeBackgroundService() async {
  if (!Platform.isAndroid) return;
  try {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onServiceStart,
        autoStart: false,
        isForegroundMode: true,
        // 不要指定 notificationChannelId: 插件源码里"指定了渠道就不会自建", 需自行用
        // flutter_local_notifications 创建, 否则前台服务通知非法(渠道不存在)会导致
        // CannotPostForegroundServiceNotificationException 直接崩进程。
        // 留空则插件用内置的 FOREGROUND_DEFAULT 渠道并自动创建, 无需额外依赖。
        initialNotificationTitle: 'LinkCOM',
        initialNotificationContent: '串口共享运行中',
        foregroundServiceNotificationId: _notifId,
        // Android 14+ 必须声明前台服务类型(与 AndroidManifest 的 dataSync 一致)
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(),
    );
  } catch (_) {
    // 无插件实现/权限不足时静默降级(不影响前台使用)
  }
}

// 开始共享/连接房间时调用 (幂等)
Future<void> startKeepAlive() async {
  if (!Platform.isAndroid) return;
  try {
    final s = FlutterBackgroundService();
    if (!await s.isRunning()) await s.startService();
  } catch (_) {}
}

// 断开共享/房间时调用
Future<void> stopKeepAlive() async {
  if (!Platform.isAndroid) return;
  try {
    FlutterBackgroundService().invoke('stopService');
  } catch (_) {}
}

@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) {
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
  }
  service.on('stopService').listen((_) => service.stopSelf());
}
