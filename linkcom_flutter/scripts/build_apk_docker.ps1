# 在 Docker 中构建 Android APK (无需本机安装 Android SDK / JDK)
# 产物: <linkcom_flutter>/build/apk-out/app-release.apk
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File scripts/build_apk_docker.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/build_apk_docker.ps1 -FlutterImage ghcr.io/cirruslabs/flutter:3.41.5
param(
  # 留空 = 自动选择: 优先复用本地已有镜像(可含国内 ghcr 加速地址), 否则用官方地址
  [string]$FlutterImage = ""
)

$ErrorActionPreference = 'Stop'

$proj = Split-Path -Parent $PSScriptRoot          # linkcom_flutter
$repo = Split-Path -Parent $proj                  # 仓库根

# 选择基础镜像: 直连 ghcr.io 在国内常被限速(几十 KB/s), 若本地已有镜像/Mirror 则直接复用
if ([string]::IsNullOrWhiteSpace($FlutterImage)) {
  $candidates = @(
    'ghcr.1ms.run/cirruslabs/flutter:stable',   # 国内 GHCR 加速
    'ghcr.io/cirruslabs/flutter:stable'
  )
  $localImages = @(docker images --format '{{.Repository}}:{{.Tag}}' 2>$null)
  foreach ($c in $candidates) {
    if ($localImages -contains $c) { $FlutterImage = $c; break }
  }
  if ([string]::IsNullOrWhiteSpace($FlutterImage)) {
    $FlutterImage = 'ghcr.io/cirruslabs/flutter:stable'
  }
}
Write-Host "基础镜像: $FlutterImage"

# 1) 版本号单一来源: 由仓库根 VERSION 生成 lib/version.dart (同时更新 public/version.js、package.json)
$sync = Join-Path $repo 'sync_version.py'
if (Test-Path $sync) {
  Write-Host "== 同步版本号 =="
  try { python $sync } catch { Write-Warning "sync_version.py 执行失败(可忽略): $_" }
}

# 2) Docker 构建, 用 BuildKit 的 local 输出把 APK 直接落到宿主机
Write-Host "== Docker 构建 Android APK (镜像: $FlutterImage) =="
Push-Location $proj
try {
  docker build `
    --build-arg "FLUTTER_IMAGE=$FlutterImage" `
    --target apk `
    --output "type=local,dest=build/apk-out" `
    -f docker/Dockerfile.android `
    .
  if ($LASTEXITCODE -ne 0) { throw "docker build 失败 (exit=$LASTEXITCODE)" }
} finally {
  Pop-Location
}

$apk = Join-Path $proj 'build/apk-out/app-release.apk'
if (Test-Path $apk) {
  $size = [math]::Round((Get-Item $apk).Length / 1MB, 2)
  Write-Host "`nAPK 构建成功: $apk ($size MB)"
} else {
  throw "未找到 APK 产物: $apk"
}
