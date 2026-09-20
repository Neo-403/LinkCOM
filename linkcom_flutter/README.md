# LinkCOM · Flutter 客户端 (Windows + Android)

LinkCOM 的跨平台客户端：**一套 Dart 代码同时覆盖 Windows 桌面与 Android 手机**，与 Web 端（`../public/`）共用同一套中继协议（`../server.js`）。

## 功能

- **共享端**：打开本机串口（Windows COMx / Android USB-OTG / 蓝牙 SPP），把数据经中继服务器转发给链接端
- **链接端**：加入房间，经中继与共享端串口双向收发，无需本地串口
- **两端数据完全隔离**：共享端可一直保持共享，同时链接端还能连接另一个房间（各持独立 `RelaySession`）
- 房间码 + 可选密码；打开串口 / 开始共享 相互独立
- 文本 / HEX / 双显，UTF-8 / GBK；时间戳、自动滚动、暂停、字节统计、历史导出
- 快速发送（增删改 / 顺序 / 轮询 / 延迟 / 本地文件导入导出）
- 快速匹配（规则匹配、去重排序、高亮、查看帧、本地文件导入导出）
- 极客主题（自动 / 白天 / 黑夜）
- 窄屏（手机）用抽屉导航，宽屏用可折叠侧栏；Android 支持前台服务保活

## 文档

| 文档 | 说明 |
|---|---|
| [`WINDOWS.md`](WINDOWS.md) | Windows 桌面端：构建、运行、测试指南 |
| [`ANDROID.md`](ANDROID.md) | Android：环境安装、打包、装到模拟器/真机、adb 排障、已知坑 |

## 快速开始

```powershell
cd linkcom_flutter

# Windows 桌面（开发模式，可热重载）
flutter run -d windows

# Android（需先配好 SDK/JDK，见 ANDROID.md）
flutter emulators --launch linkcom
flutter run -d emulator-5554

# 打包
flutter build windows --release
flutter build apk --release
```

> 中继服务器地址在「设置」页配置（形如 `ws://host:8080/ws`）。本地联调可先启动根目录的 `node server.js`。

## 平台与串口后端

| 平台 | 串口后端 |
|---|---|
| Windows | `serial_port_win32`（COMx，含 CH340/CP210x/FTDI/PL2303/CDC 与蓝牙虚拟 COM） |
| Android USB-OTG | `usb_serial` |
| Android 蓝牙 SPP | `flutter_bluetooth_serial`（本地化补丁，见 `plugins/`） |

## 目录

```
lib/
  main.dart            入口 + 导航（宽屏侧栏 / 窄屏抽屉）
  state/               AppState(全局: 服务器地址/历史/主题) + RelaySession(每板块会话)
  net/                 ws_client / relay_controller
  serial/              串口配置与各平台实现（win32 / usb / bt）
  codec/               GBK / UTF-8 编解码
  sniffer/             快速匹配控制器
  background/          Android 前台服务保活
  ui/                  共享端 / 链接端 / 设置 及子面板
android/ windows/      平台工程
plugins/               本地化修补的第三方插件
scripts/               Android SDK 安装、Docker 打包等脚本
```
