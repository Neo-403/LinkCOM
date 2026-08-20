# LinkCOM 桌面端 (Windows)

一个 Python 桌面端，替代浏览器共享端角色，把 **本地 COM 口 / TCP 连接** 的数据通过
WebSocket 转发到 [LinkCOM](../server.js) 服务器房间，其它设备（手机/电脑）用浏览器
链接端 (`/?mode=link`) 实时收发调试。

协议与现有 Web 端完全兼容，**服务器 `server.js` 无需任何改动**。

## 三种共享模式

| 模式 | 说明 | 配置 |
|------|------|------|
| 串口 COM | 本地串口（pyserial），兼容 Web Serial 的串口参数 | COM 口、波特率、数据位、停止位、校验、流控 |
| TCP Client | 本机作为 TCP 客户端连远端设备 | 远端主机+端口；可选**本地出口网卡 IP**（多网卡场景）；可选**本地出口端口**（留空随机） |
| TCP Server | 本机监听端口，供设备接入 | 监听网卡 IP（可选 0.0.0.0 全部）+ 监听端口 |

> TCP Server 多客户端：**任一客户端数据合并上行**，房间下发的链接端数据**广播给所有客户端**。

## 目录结构

```
desktop/
  main.py                 入口 (支持 linkcom:// 启动参数与 --register)
  main_window.py          PySide6 主窗口 (三模式 Tab / 日志 / 发送 / 状态)
  linkcom_client.py       WebSocket 客户端 (协议复用 + 自动重连)
  channels/
    base.py               通道抽象基类
    serial_channel.py     串口通道 (pyserial)
    tcp_client_channel.py TCP Client 通道 (指定本地出口 IP/端口)
    tcp_server_channel.py TCP Server 通道 (多客户端合并+广播)
  config.py                linkcom.zwzw 读写 (exe/源码同目录)
  net_util.py             本机网卡 IP 枚举
  url_scheme.py           linkcom:// 解析
  codecs_util.py          UTF-8 / GBK 编解码 + HEX 格式化
  requirements.txt
  config.json.example
```

## 运行（开发模式）

1. 安装 Python 3.10+，并先启动 LinkCOM 服务器：
   ```bash
   # 项目根目录
   npm install   # 仅首次需要 (安装 ws 模块)
   node server.js
   ```
2. 安装桌面端依赖：
   ```bash
   cd desktop
   pip install -r requirements.txt
   ```
3. 启动客户端：
   ```bash
   python main.py
   ```
4. 在界面填写：
   - **WEB 服务器**：如 `ws://127.0.0.1:8080`，若服务器带子路径（如 `/linkcom`）可写成 `ws://host:port/linkcom`
   - **房间码**：启动自动生成（6 位），可手动修改；与浏览器链接端保持一致
   - 密码（可选）
5. 操作流程（打开通道 在前，共享通道 在后）：
   - 先点 **打开通道**（连接本地 COM / TCP 数据源）
   - 再点 **共享通道**（连 WEB 服务器并进入房间开始转发，状态灯变绿表示共享中）
   - 关闭时分别点 **关闭通道** / **停止共享**
6. 手机/其它设备打开 `http://<服务器地址>/?mode=link`，输入同一房间码即可收发。

## 共享链接（一键加入房间）

进入「共享中」后，控制栏会出现蓝色 **「共享链接」**。点击它：
- 自动把**网页链接**复制到剪贴板：
  `http(s)://<服务器>/?mode=link&room=<房间码>&pwd=<密码>`
  （对方手机/浏览器打开即可自动填入房间码与密码进房）
- 同时尝试用 **`linkcom://`** 一键唤起本机已注册的桌面端：
  `linkcom://?room=<房间码>&pwd=<密码>&server=<服务器>&mode=link`
  （若已执行 `python main.py --register`，本机客户端会自动带房间码+密码进房）

> 密码为空时链接不含 `pwd` 参数。

## URL Scheme（一键拉起）

支持 `linkcom://` 协议，点击网页分享链接直接预填配置并打开客户端：

```
linkcom://?room=ROOM&pwd=PASSWORD&server=ws://host:port&mode=tcpClient
```

注册（Windows，管理员运行一次）：
```bash
python main.py --register
```
会写入 `HKEY_CURRENT_USER\Software\Classes\linkcom`。注册后，生成分享链接的页面可加一个按钮：
```html
<a href="linkcom://?room=ROOM&pwd=&server=ws://host:port">用桌面端打开</a>
```

## 打包成单 exe（PyInstaller）

开发验证无误后，自行打包。产出**单个可执行文件**，无需目标机器安装 Python，兼容 **Windows 10 / 11**（Win7 需 SP1 + 安装 [Visual C++ 2015-2022 运行库](https://learn.microsoft.com/zh-CN/cpp/windows/latest-supported-vc-redist)，并建议使用下方 Win7 兼容命令）。

```bash
cd desktop
pip install pyinstaller

# 默认 (Win10/Win11, 64 位 Python 环境打包)
pyinstaller --name LinkCOM --windowed --onefile ^
  --icon logo.ico --add-data "logo.png;." ^
  --hidden-import=websocket --hidden-import=serial --hidden-import=PySide6 ^
  main.py
```

- `--windowed`：不弹控制台黑窗（GUI 程序）
- `--onefile`：产出单个 `dist/LinkCOM.exe`，可直接拷贝到无 Python 环境运行
- `--icon logo.ico`：exe 文件图标（多尺寸 ico，任务栏/资源管理器正常显示）
- `--add-data "logo.png;."`：把 logo 嵌入单文件包内，运行时窗口图标自动加载
- `--hidden-import`：显式声明动态导入的依赖，避免打包后 missing module

### Win7 兼容（可选）

Win7 最高仅支持到 Python 3.8，且需对应的 PyInstaller 老版本（如 `pyinstaller==4.10`）。若需在 Win7 上运行：

1. 在 **Python 3.8 64 位** 环境安装 `pyinstaller==4.10` 与项目依赖
2. 使用同样命令打包（ico/png 图标在新老 PyInstaller 下均生效）

> 注：现代 Windows（Win10/11）推荐用最新 Python + 最新 PyInstaller 打包即可。

打包后配置会自动保存在 **exe 同目录** 的 `linkcom.zwzw` 中（开发时在源码目录），每次运行读取、修改后保存，参数不会丢失。

## 配置项 (linkcom.zwzw)

首次运行会自动生成 `linkcom.zwzw`，可手动编辑后重启。字段结构与 `config.json.example` 一致：
`server` / `basePath` / `room` / `pwd` / `mode` / `serial` / `tcpClient` / `tcpServer` / `display`。

> 注意：修改 WEB 服务器地址后**必须点击「开始共享」重新连接**才会生效。
