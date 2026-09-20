# 本机一键安装 Android 构建/测试环境(免 Docker): JDK(17~21) + Android SDK 命令行工具 + 模拟器。
# 说明:
#   - Flutter 3.41 要求 compileSdk/targetSdk = 36, Gradle 8.14/AGP 8.11 需要 JDK 17~21
#     (本机默认 JDK 可能是 26, 故单独指定 JDK 并通过 `flutter config --jdk-dir` 绑定)。
#   - 脚本会优先复用 `flutter config --jdk-dir` 已配置的 JDK; 没有才下载 Temurin 17。
#   - 模拟器需要硬件加速(Windows: 启用 "Windows 虚拟机监控程序平台"/Hyper-V)。
#   - 模拟器可验证 UI/逻辑/中继/前台服务; USB-OTG 与蓝牙 SPP 属真实硬件, 仍需真机。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File scripts/setup_android_sdk.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/setup_android_sdk.ps1 -Api 36 -AvdName linkcom
#   powershell -ExecutionPolicy Bypass -File scripts/setup_android_sdk.ps1 -JdkDir "D:\Program Files\Java\jdk-21"
# PositionalBinding=$false: 防止调用方多传/含空格的参数被误绑到位置参数(曾导致 $SdkRoot 被顶替)
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$SdkRoot = "$env:LOCALAPPDATA\Android\Sdk",
  [string]$Api = "36",
  [string]$CmdlineToolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip",
  [string]$AvdName = "linkcom",
  [string]$JdkDir = "",
  [switch]$SkipJdk
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- JDK (17~21)
if (-not $SkipJdk -and [string]::IsNullOrWhiteSpace($JdkDir)) {
  # 1) 复用 flutter 已配置的 jdk-dir (解析 `flutter config --list`, 各版本存储位置不同, 以此为准)
  try {
    $hit = (flutter config --list 2>$null | Select-String -Pattern '^\s*jdk-dir:\s*(.+)$' | Select-Object -First 1)
    if ($hit) {
      $cand = $hit.Matches[0].Groups[1].Value.Trim()
      if ($cand -and (Test-Path (Join-Path $cand 'bin\java.exe'))) { $JdkDir = $cand }
    }
  } catch {}
  # 2) 常见安装位置
  if ([string]::IsNullOrWhiteSpace($JdkDir)) {
    $probe = @(
      "$env:ProgramFiles\Eclipse Adoptium\jdk-21*",
      "$env:ProgramFiles\Eclipse Adoptium\jdk-17*",
      "$env:ProgramFiles\Java\jdk-21*",
      "$env:ProgramFiles\Java\jdk-17*",
      "$env:ProgramFiles\Microsoft\jdk-21*",
      "$env:ProgramFiles\Microsoft\jdk-17*"
    )
    foreach ($p in $probe) {
      $hit = Get-ChildItem -Path $p -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit) { $JdkDir = $hit.FullName; break }
    }
  }
  # 3) 仍没有则下载 Temurin 17 (便携解压)
  if ([string]::IsNullOrWhiteSpace($JdkDir)) {
    Write-Host "== 未发现 JDK 17/21, 下载 Temurin JDK 17 =="
    $jdkZip = Join-Path $env:TEMP 'temurin17.zip'
    $jdkDest = Join-Path $SdkRoot 'jdk-17'
    Invoke-WebRequest -Uri 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse' -OutFile $jdkZip
    if (Test-Path $jdkDest) { Remove-Item -Recurse -Force $jdkDest }
    Expand-Archive -Path $jdkZip -DestinationPath $jdkDest -Force
    $inner = Get-ChildItem -Path $jdkDest -Directory | Select-Object -First 1
    $JdkDir = if ($inner) { $inner.FullName } else { $jdkDest }
  }
}

if (-not [string]::IsNullOrWhiteSpace($JdkDir) -and
    -not (Test-Path (Join-Path $JdkDir 'bin\java.exe'))) {
  throw "无效的 JDK 目录(缺少 bin\java.exe): $JdkDir"
}

if (-not [string]::IsNullOrWhiteSpace($JdkDir)) {
  Write-Host "JDK: $JdkDir"
  # sdkmanager/gradle 均按 JAVA_HOME 取 JDK, 避免用到系统默认的过新 JDK
  $env:JAVA_HOME = $JdkDir
  $env:PATH = "$JdkDir\bin;$env:PATH"
  flutter config --jdk-dir "$JdkDir" | Out-Null
}

# ---------------------------------------------------------------- Android SDK
$latest = Join-Path $SdkRoot 'cmdline-tools/latest'
$sdkmanager = Join-Path $latest 'bin/sdkmanager.bat'
$avdmanager = Join-Path $latest 'bin/avdmanager.bat'

if (-not (Test-Path $sdkmanager)) {
  Write-Host "== 下载 Android 命令行工具 =="
  $zip = Join-Path $env:TEMP 'cmdline-tools.zip'
  Invoke-WebRequest -Uri $CmdlineToolsUrl -OutFile $zip
  $tmp = Join-Path $env:TEMP 'cmdline-tools-extract'
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force -Path $latest | Out-Null
  Copy-Item -Recurse -Force (Join-Path $tmp 'cmdline-tools\*') $latest
  Write-Host "已解压到 $latest"
}

$env:ANDROID_HOME = $SdkRoot
$env:ANDROID_SDK_ROOT = $SdkRoot

Write-Host "== 接受 Android SDK 许可证 =="
# 1) 直接写入标准许可哈希(社区/CI 通用做法), 保证安装阶段不弹交互
$licDir = Join-Path $SdkRoot 'licenses'
New-Item -ItemType Directory -Force -Path $licDir | Out-Null
Set-Content -Encoding ASCII -Path (Join-Path $licDir 'android-sdk-license') -Value @(
  '24333f8a63b6825ea9c5514f83c2829b004d1fee',
  'd56f5187479451eabf01fb78af6dfcb131a6481e',
  '8933bad161af4178b1185d1a37fbf41ea5269c55'
)
Set-Content -Encoding ASCII -Path (Join-Path $licDir 'android-sdk-preview-license') -Value '84831b9409646a918e30573bab4c9c91346d8abd'
Set-Content -Encoding ASCII -Path (Join-Path $licDir 'intel-android-extra-license') -Value 'd975f751698a77b662f1254ddbeed3901e976f5a'
# 2) 再跑一次 --licenses 兜底(y 由文件喂入, 避免管道丢失)
$licYes = Join-Path $env:TEMP 'android_lic_yes.txt'
1..60 | ForEach-Object { 'y' } | Out-File -FilePath $licYes -Encoding ASCII
Get-Content $licYes | & $sdkmanager --sdk_root=$SdkRoot --licenses

Write-Host "== 安装 SDK 组件 (API $Api) =="
& $sdkmanager --sdk_root=$SdkRoot `
  "platform-tools" `
  "platforms;android-$Api" `
  "build-tools;$Api.0.0" `
  "emulator" `
  "system-images;android-$Api;google_apis;x86_64"
if ($LASTEXITCODE -ne 0) { throw "sdkmanager 安装失败, 返回码 $LASTEXITCODE" }

Write-Host "== 创建模拟器 (AVD: $AvdName) =="
'no' | & $avdmanager create avd -n $AvdName -k "system-images;android-$Api;google_apis;x86_64" --force

Write-Host "== 配置 Flutter =="
flutter config --android-sdk "$SdkRoot" | Out-Null
flutter doctor -v

Write-Host @"

==== 完成 ====
后续(在 linkcom_flutter 目录):
  仅打包(进度可见):  flutter build apk --release
  启动模拟器:        flutter emulators --launch $AvdName
  安装到模拟器调试:  flutter run -d emulator-5554
APK 产物: build\app\outputs\flutter-apk\app-release.apk
"@
