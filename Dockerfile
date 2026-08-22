# LinkCOM - Web 串口共享与远程调试工具
FROM node:20-alpine

WORKDIR /app

# 先拷贝依赖清单, 利用层缓存
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

# 拷贝应用代码 (含唯一版本来源 VERSION)
COPY VERSION ./
COPY server.js ./
COPY public ./public

# 构建镜像时自动把根 VERSION 同步到 Web 端 public/version.js, 无需手动运行脚本
# (GitHub Actions 中已在 push 前由 sync_version.py 生成, 此处再基于 VERSION 幂等生成, 保证 docker build 也一致)
RUN V=$(tr -d '[:space:]' < VERSION) && \
    printf "window.APP_VERSION = '%s';\n" "$V" > public/version.js

ENV PORT=8080
EXPOSE 8080

# 容器以非 root 用户运行
USER node

CMD ["node", "server.js"]
