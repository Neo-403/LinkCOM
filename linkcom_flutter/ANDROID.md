# LinkCOM Flutter · Android 构建 / 运行 / 调试指南

> 适用：Windows 上开发，用 Android 模拟器（或真机）运行 Flutter 版 LinkCOM。

## 0. 本机已就绪的环境（一次性配好，之后直接用）

| 项 | 值 |
|---|---|
| Flutter | 3.41.5（stable） |
| JDK | `D:\Program Files\Java\jdk-21`（已 `flutter config --jdk-dir` 绑定；**不要用系统默认的 Java 26**，Gradle 8.14 不支持） |
| Android SDK | `C:\Users\WJ\AppData\Local\Android\Sdk`（platform 36 / build-tools 36.0.0 / platform-tools / emulator / NDK 28.2 / CMake 3.22.1） |
| 模拟器 AVD | `linkcom`（`system-images;android-36;google_apis;x86_64`） |
| 应用包名 | `com.zwzw.linkcom`（启动 Activity：`com.zwzw.linkcom.MainActivity`） |

校验环境：

```powershell
flutter doctor -v      # Android toolchain 应显示 SDK 36 + Java binary 指向 jdk-21
flutter devices        # 应能看到 emulator-5554（模拟器已启动时）
```

## 1. 首次/换机时的环境安装

```powershell
cd c:\Users\WJ\Desktop\CS\LinkCOM\linkcom_flutter

# 装 JDK（17~21 任一）+ Android SDK + 模拟器（脚本会自动识别已配置的 JDK）
powershell -ExecutionPolicy Bypass -File scripts\setup_android_sdk.ps1
```

如需指定 JDK：`... -JdkDir "D:\Program Files\Java\jdk-21"`。
如需换 API 级别：`... -Api 35`。

## 2. 日常最常用（打包 / 起模拟器 / 调试）

```powershell
cd c:\Users\WJ\Desktop\CS\LinkCOM\linkcom_flutter

flutter build apk --release            # 打包（产物见下）
flutter emulators --launch linkcom     # 启动模拟器（需已开启虚拟化/WHPX）
flutter devices                        # 确认设备 id（一般为 emulator-5554）
flutter run -d emulator-5554           # 装到模拟器调试（debug 版，首次构建需数分钟）
```

- `flutter run` 会**重新构建 debug 版**并安装，终端有进度；装好后应用会自动打开。
- release 产物：`build\app\outputs\flutter-apk\app-release.apk`
- 退出 `flutter run`：在终端按 `q`（或 `Ctrl+C`）。

## 3. 只装 release 包到模拟器（不重新构建）

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$apk = "build\app\outputs\flutter-apk\app-release.apk"

& $adb install -r $apk                                  # 覆盖安装
& $adb shell am start -n com.zwzw.linkcom/.MainActivity  # 启动
```

## 4. 常用 adb 命令（排障/验证）

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"

& $adb devices                                  # 已连接设备
& $adb shell getprop sys.boot_completed         # 模拟器是否启动完成(1=完成)
& $adb shell wm size                            # 屏幕分辨率(用于算 input tap 坐标)

& $adb shell pm clear com.zwzw.linkcom          # 清应用数据(重置权限/配置, 排障常用)
& $adb uninstall com.zwzw.linkcom               # 卸载

& $adb logcat -c                                # 清空日志
& $adb logcat -d -b crash                       # ★崩溃堆栈(装完看不到应用先看这个)
& $adb logcat -d | Select-String -Pattern 'E/flutter|AndroidRuntime|linkcom'

& $adb shell screencap -p /sdcard/s.png         # 截图
& $adb pull /sdcard/s.png .\s.png

& $adb shell input tap 200 433                  # 模拟点击(配合 wm size 算坐标)
& $adb emu kill                                 # 关闭模拟器
```

## 5. 已知坑与对策（均已在仓库中修好，勿回退）

1. **Gradle 发行包下载超时**：官方 `services.gradle.org` 会 307 跳转到 GitHub（国内超时）。
   已把 `android/gradle/wrapper/gradle-wrapper.properties` 指向腾讯镜像。
   还原官方源：改回 `https\://services.gradle.org/distributions/gradle-8.14-all.zip`。
2. **SDK 许可**：`scripts/setup_android_sdk.ps1` 会写入 `$SDK\licenses` 标准哈希文件（交互式 `--licenses` 在 PowerShell 里不可靠）。
3. **`avdmanager` 建 AVD 报 `?no is not a valid reply`**：PowerShell 管道给 `.bat` 会带 BOM。
   对策：用 `Start-Process -RedirectStandardInput <文件>`，**别**用 `'no' | & xxx.bat`。
4. **MainActivity 包名**：必须与 `applicationId`/`namespace` 一致。若改了 `applicationId`（现为 `com.zwzw.linkcom`），
   务必同步 `android/app/src/main/kotlin/com/zwzw/linkcom/MainActivity.kt` 的 `package` 与目录。
   否则 `flutter build apk` **会成功**，但装机一打开就崩 `ClassNotFoundException`（AGP 构建期不校验 Activity 类）。
5. **前台服务通知崩溃** `CannotPostForegroundServiceNotificationException`：
   `flutter_background_service` 若在 `AndroidConfiguration` 里**指定** `notificationChannelId`，插件就**不会自建渠道**，
   必须在别处先用 `flutter_local_notifications` 创建。本仓库的做法是**不指定**，让插件用内置 `FOREGROUND_DEFAULT` 自动创建。
6. **蓝牙（Android 12+）崩溃**：老插件 `flutter_bluetooth_serial` 只知道请求定位权限，不知 `BLUETOOTH_CONNECT`，
   授权回调里调 `getBondedDevices()` 抛 `SecurityException` 崩进程。
   已在本地化插件 `plugins/flutter_bluetooth_serial` 打补丁：API 31+ 请求 `BLUETOOTH_CONNECT`/`BLUETOOTH_SCAN`，
   并捕获 `SecurityException`。首次切「蓝牙SPP」会弹**「附近设备」**权限，允许后即可。
7. **Gradle 内存**：`android/gradle.properties` 已把 `-Xmx8G` 降到 `-Xmx2g`（适配小内存/CI 环境）。
8. **签名**：release 目前用 **debug 签名**（`android/app/build.gradle.kts` 里如此），仅供本地安装测试；正式分发需配置自己的签名。

## 6. 模拟器的能力边界

- ✅ 可验证：UI/主题、中继（WebSocket）收发、串口配置同步、快速发送/嗅探、前台服务保活、权限流程。
- ❌ 不可验证：**USB-OTG 串口**、**蓝牙 SPP 实机通信** —— 需要真机 + 实际硬件模块。

## 7. 其它平台

```powershell
flutter build windows --release        # Windows 桌面版(开发主用)
flutter build apk --release            # Android 版
```
