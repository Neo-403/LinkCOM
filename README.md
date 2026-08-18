# LinkCOM · Web 串口共享与远程调试工具

把本地电脑的串口 (COM 口) 通过浏览器共享到服务器，手机或任意远程电脑经浏览器实时收发该串口数据，实现**远程调试**。

## 特性
- **共享端** (电脑): 用浏览器原生 **Web Serial API** 读取本地 COM 口，无需安装驱动/客户端
- **链接端** (手机/电脑): 浏览器经 **WebSocket** 实时收发共享串口数据
- **房间码 + 可选密码** 访问控制；房间码留空自动生成随机码
- **打开串口 / 共享 相互独立**：可先本地开串口调试，再决定是否共享；或先共享占位后开串口
- **文本 / HEX 双模式可同时勾选**（分屏左右两栏显示），切换时可按新模式重渲染历史事件
- **文本编码 UTF-8 / GBK 可选**（收发均支持，GBK 用浏览器原生解码 + 运行时反推编码表，无外部依赖）
- 波特率/数据位/停止位/校验/流控 完整配置
- 发送区支持 文本/HEX、回车发送、自动加 `\r\n`
- 自动滚动 / 暂停显示 / 清空 / 收发字节统计
- 响应式布局，手机端可正常操作
- WS 断线自动重连；链接端加入即收到串口参数

## 使用

### 1. 启动服务器
```bash
npm install      # 安装 ws 依赖
npm start        # 默认端口 8080, 可用 PORT=9000 npm start 修改
```

### 2. 共享端 (本地电脑, 接串口的那台)
- 用 **桌面版 Chrome / Edge** 打开 `http://<服务器IP>:8080/`
- 点「选择 COM 口」选串口（浏览器基于安全策略不暴露 COM 号，以 USB 标识显示），点「打开串口」
- 房间码留空会自动生成随机码，也可手动填写；可选密码
- 点「开始共享」把该串口数据转发到房间
- 显示区可单独或同时勾选「文本 / HEX」（同时勾选为分屏），编码可选 UTF-8 / GBK
- ⚠️ Web Serial 仅桌面浏览器支持，且需 `localhost` 或 `https` 访问

### 3. 链接端 (手机/远程电脑)
- 浏览器打开 `http://<服务器IP>:8080/?mode=link`
- 输入共享端的房间码和密码，点「连接房间」
- 连接成功即显示共享端串口参数，可远程收发串口数据调试

## 远程部署注意 (远距离测试)
- 服务器需有公网 IP 或经内网穿透暴露 8080 端口
- **手机/远程访问必须用 https**（浏览器安全限制），可用反向代理 (Nginx + 免费证书) 或 `wss`
- 共享端电脑访问服务器也建议 https，否则 Web Serial 在 `http://非localhost` 下被禁用；`localhost` 例外

## Docker 部署 (推荐)
无需在宿主机装 Node，直接打包成镜像运行。

```bash
# 构建并后台启动 (默认 8080)
docker compose up -d --build

# 或自定义端口
PORT=9000 docker compose up -d --build

# 查看日志
docker compose logs -f

# 停止
docker compose down
```

单独构建/运行:
```bash
docker build -t 918178/linkcom:latest .
docker run -d --name linkcom -p 8080:8080 -e PORT=8080 --restart unless-stopped 918178/linkcom:latest
```

> 镜像基于 `node:20-alpine`，仅含生产依赖，以非 root 用户运行。

## Nginx 反向代理 (含子路径部署)

### 根路径 (默认)
```nginx
server {
    listen 80;
    server_name your.domain;
    location / {
        proxy_pass http://127.0.0.1:18080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }
}
```

### 子路径 (如 `https://your.domain/linkcom/`)
程序已支持子路径部署，需两处保持一致：**① 后端设 `BASE_PATH` ② nginx 透传前缀**。

#### 1) docker-compose（与 Nginx 容器同网络，不暴露宿主端口）
```yaml
services:
  linkcom:
    # image: 918178/linkcom:latest  # DockerHub
    image: ghcr.io/neo-403/linkcom:latest  # Ghcr.io
    container_name: linkcom
    restart: unless-stopped
    # ports:            # 不映射到宿主, 仅走下面内网网络
    #   - "8080:8080"
    environment:
      - PORT=8080
      - BASE_PATH=/linkcom   # 子路径, 须与 nginx location 完全一致(不带末尾 /)
    networks:
      - nginx_default      # 与 nginx 容器同一网络才能反代
# 加入 nginx 容器所在网络
networks:
  nginx_default:
    external: true           # 使用已存在的网络(由 nginx 容器创建)
    name: nginx_default    # 须与 nginx 容器使用的网络名一致
```
- `BASE_PATH=/linkcom` → 后端把静态页、WebSocket 都挂到 `/linkcom` 下（WS 实际路径 `/linkcom/ws`）。
- 不写 `ports` 容器只在 `nginx_default` 内网可达，由 Nginx 暴露公网，更安全。

#### 2) Nginx 反代（保留子路径前缀）
```nginx
# 在 http {} 块定义(全局一次), 让普通请求与 WebSocket 升级都能正确转发
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    server_name your.domain;

    # ===== LinkCOM 共享串口 (WebSocket 转发, 子路径 /linkcom) =====
    # 前置: 后端容器已设 BASE_PATH=/linkcom
    # 访问: https://your.domain/linkcom/share.html (共享端)
    #       https://your.domain/linkcom/link.html  (链接端)
    location /linkcom/ {
        # 注意 proxy_pass 末尾【不要】加 "/" —— 否则会裁掉 /linkcom 前缀
        # 透传后: /linkcom/share.html -> http://linkcom:8080/linkcom/share.html
        #         /linkcom/ws         -> http://linkcom:8080/linkcom/ws
        proxy_pass http://linkcom:8080;

        proxy_http_version 1.1;                 # WebSocket 必须 1.1
        proxy_set_header Upgrade $http_upgrade; # WebSocket 升级握手
        proxy_set_header Connection $connection_upgrade; # 有升级则 upgrade, 否则 close
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;               # 长连接空闲超时, 须大于前端心跳/重连周期
        proxy_send_timeout 3600s;
        # client_max_body_size 30M;             # 共享文件等需更大上传体积时取消注释
    }
}
```
- `proxy_pass http://linkcom:8080;`（**无末尾 `/`**）是关键：把 `/linkcom` 前缀原样透传给后端，由 `BASE_PATH` 处理；若误加 `/` 会裁剪前缀导致 404。
- `linkcom` 是 docker 服务名，需与 Nginx 容器在同一网络（`nginxui_default`）才能解析。
- 前端 `link.js`/`share.js` 会从当前页面 URL 自动推导 WS 前缀（`/linkcom/ws`），无需手动配置。

访问地址：
- 共享端：`https://your.domain/linkcom/share.html`
- 链接端：`https://your.domain/linkcom/link.html?room=房间码`

> 注意：`BASE_PATH` 与 nginx `location /linkcom/` 必须一致。若用根路径部署，请勿设置 `BASE_PATH`，nginx 用上面的「根路径」配置即可。
> WebSocket 路径会自动变为 `BASE_PATH + /ws`（如 `/linkcom/ws`），前端从页面 URL 自动推导，无需手动配置。

## 协议 (WebSocket `/ws`, JSON)
- `join` `{t:"join",room,role:"share"|"link",pwd?}`
- `serial-data` `{t:"serial-data",buf:"<base64>",from:"share"|"link"}`
- `serial-config` `{t:"serial-config",cfg:{...}}`
- `peers` `{t:"peers",share:bool,links:int}`

## 目录
```
server.js          后端 WebSocket 转发 + 静态服务
public/
  index.html       入口(按 mode 跳转)
  share.html/js    共享端
  link.html/js     链接端
  gbk.js           GBK/UTF-8 编解码 (纯前端)
  style.css        共用样式
package.json
Dockerfile
docker-compose.yml
.dockerignore
```
