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
docker build -t linkcom:latest .
docker run -d --name linkcom -p 8080:8080 -e PORT=8080 --restart unless-stopped linkcom:latest
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
程序已支持子路径部署，只需两处保持一致：

1. **docker-compose 设置 `BASE_PATH`**（与 nginx 的 `location` 完全一致，不带末尾斜杠）：
   ```yaml
   environment:
     - PORT=8080
     - BASE_PATH=/linkcom
   ```
2. **nginx 反代时保留子路径前缀**（注意 `proxy_pass` 末尾**不要**加 `/`）：
   ```nginx
   server {
       listen 443 ssl;
       server_name your.domain;

       location /linkcom/ {
           proxy_pass http://127.0.0.1:18080;   # 末尾不带 / , 保留 /linkcom 前缀转发给容器
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection "upgrade";
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_read_timeout 3600s;
       }
   }
   ```
   访问地址：
   - 共享端：`https://your.domain/linkcom/?mode=share`
   - 链接端：`https://your.domain/linkcom/?mode=link`

> 注意：`BASE_PATH` 与 nginx `location /linkcom/` 必须一致。若用根路径部署，请勿设置 `BASE_PATH`，nginx 用上面的「根路径」配置即可。
> WebSocket 路径会自动变为 `BASE_PATH + /ws`（如 `/linkcom/ws`），前端会从当前页面 URL 自动推导，无需手动配置。

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
