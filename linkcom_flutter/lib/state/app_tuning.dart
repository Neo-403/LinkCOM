// 全局可调参数(设置页可改), 供串口/蓝牙后端直接取用。
// 这些后端是普通类, 拿不到 Provider/AppState, 所以由 AppState 载入/修改后写入这里。
class AppTuning {
  AppTuning._();

  /// 串口读取轮询间隔(ms): 越小交数据越及时, 但 FFI 定时器回调更频繁(过大/过小都影响体验)
  static int readPollMs = 10;

  /// 单次读取的最大等待(ms): 到点即把已到数据交出
  static int readTimeoutMs = 25;

  /// 驱动输入/输出缓冲(KB), Windows 用 SetupComm 放大(默认常只有 4KB)
  static int rxBufKb = 64;

  /// 单个板块最多保留的日志行数(超出丢弃最旧的)
  static int maxLogLines = 5000;

  /// BLE 扫描时长(s)
  static int bleScanSec = 6;
}
