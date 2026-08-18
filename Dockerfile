# LinkCOM - Web 串口共享与远程调试工具
FROM node:20-alpine

WORKDIR /app

# 先拷贝依赖清单, 利用层缓存
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

# 拷贝应用代码
COPY server.js ./
COPY public ./public

ENV PORT=8080
EXPOSE 8080

# 容器以非 root 用户运行
USER node

CMD ["node", "server.js"]
