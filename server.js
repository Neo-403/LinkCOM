/**
 * LinkCOM - Web 串口共享与远程调试服务器
 *
 * 架构:
 *   共享端 (电脑, Web Serial 读本地 COM) --WebSocket--> 本服务器 --WebSocket--> 链接端 (手机/电脑)
 *
 * 消息协议 (JSON):
 *   客户端 -> 服务器:
 *     { t:"join", room:"R1", role:"share"|"link", pwd?:"" }   加入房间
 *     { t:"serial-data", buf:"<base64>", src:"share"|"link" }  串口数据 (src=真实来源角色)
 *     { t:"serial-config", cfg:{...} }                         共享端串口参数变更通知
 *     { t:"bye" }                                              离开
 *   服务器 -> 客户端:
 *     { t:"ok", role, room, peers }                            加入成功
 *     { t:"err", msg }                                         错误
 *     { t:"serial-data", buf:"<base64>", from:"share"|"link", src:"share"|"link" } 转发串口数据
 *     { t:"serial-config", cfg }                               转发串口参数
 *     { t:"peers", share:bool, links:int }                     房间在线状态
 *     { t:"closed" }                                           对端断开
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;
const PUBLIC_DIR = path.join(__dirname, 'public');

// 子路径部署前缀, 例如 /linkcom 。值为空或 / 表示根路径。
// 用法: docker 中 environment: BASE_PATH=/linkcom
let BASE_PATH = (process.env.BASE_PATH || '').trim();
if (!BASE_PATH || BASE_PATH === '/') BASE_PATH = '';
else if (!BASE_PATH.startsWith('/')) BASE_PATH = '/' + BASE_PATH;
if (BASE_PATH.endsWith('/')) BASE_PATH = BASE_PATH.slice(0, -1);
// 暴露给前端 (注入到 HTML), 让 WebSocket 与跳转能跟随子路径
process.env.BASE_PATH = BASE_PATH;

// ---------- 静态文件服务 ----------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const server = http.createServer((req, res) => {
  let urlPath = decodeURIComponent(req.url.split('?')[0]);

  // 剥离子路径前缀 (BASE_PATH), 例如 /linkcom/share.html -> /share.html
  let prefix = BASE_PATH || '';
  if (prefix && urlPath.startsWith(prefix)) {
    urlPath = urlPath.slice(prefix.length) || '/';
  }
  if (urlPath === '/') urlPath = '/index.html';

  // 防止路径穿越
  const filePath = path.join(PUBLIC_DIR, path.normalize(urlPath));
  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('404 Not Found');
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
    });
    res.end(data);
  });
});

// ---------- WebSocket 房间管理 ----------
const wss = new WebSocketServer({ server, path: BASE_PATH + '/ws' });

/** rooms: Map<roomId, { pwd, share:ws|null, links:Set<ws> }> */
const rooms = new Map();

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function roomPeers(room) {
  return { share: !!room.share, links: room.links.size };
}

function broadcastPeers(roomId) {
  const room = rooms.get(roomId);
  if (!room) return;
  const peers = roomPeers(room);
  if (room.share) send(room.share, { t: 'peers', ...peers });
  room.links.forEach((l) => send(l, { t: 'peers', ...peers }));
}

function leaveRoom(ws) {
  const { roomId, role } = ws.meta || {};
  if (!roomId) return;
  const room = rooms.get(roomId);
  if (!room) return;
  if (role === 'share' && room.share === ws) {
    room.share = null;
    // 通知所有链接端共享端已离开
    room.links.forEach((l) => send(l, { t: 'closed', reason: 'share-left' }));
  } else if (role === 'link') {
    room.links.delete(ws);
  }
  broadcastPeers(roomId);
  if (!room.share && room.links.size === 0) {
    rooms.delete(roomId);
  }
  ws.meta = null;
}

wss.on('connection', (ws) => {
  ws.meta = null; // { roomId, role }

  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    switch (msg.t) {
      case 'join': {
        const roomId = String(msg.room || '').trim();
        if (!roomId) { send(ws, { t: 'err', msg: '房间码不能为空' }); return; }
        const role = msg.role === 'share' ? 'share' : 'link';
        let room = rooms.get(roomId);

        if (role === 'share') {
          // 共享端: 若已存在且密码不同则拒绝覆盖 (简单策略: 允许接管, 记录密码)
          if (!room) {
            room = { pwd: msg.pwd || '', share: null, links: new Set(), cfg: null };
            rooms.set(roomId, room);
          } else {
            // 若已有共享端且密码不匹配, 拒绝
            if (room.share && room.pwd && room.pwd !== (msg.pwd || '')) {
              send(ws, { t: 'err', msg: '房间密码错误' }); return;
            }
            room.pwd = msg.pwd || room.pwd;
          }
          // 顶掉旧共享端
          if (room.share && room.share !== ws) {
            send(room.share, { t: 'closed', reason: 'replaced' });
            try { room.share.close(); } catch {}
          }
          room.share = ws;
        } else {
          // 链接端
          if (!room) { send(ws, { t: 'err', msg: '房间不存在, 请先由共享端创建' }); return; }
          if (room.pwd && room.pwd !== (msg.pwd || '')) {
            send(ws, { t: 'err', msg: '房间密码错误' }); return;
          }
          if (!room.share) {
            send(ws, { t: 'err', msg: '共享端尚未连接串口' }); return;
          }
          room.links.add(ws);
          // 若已有串口参数, 立即推给新加入的链接端 (解决后加入看不到配置的问题)
          if (room.cfg) send(ws, { t: 'serial-config', cfg: room.cfg });
        }

        ws.meta = { roomId, role };
        send(ws, { t: 'ok', role, room: roomId, peers: roomPeers(room) });
        broadcastPeers(roomId);
        break;
      }

      case 'serial-data': {
        const { roomId, role } = ws.meta || {};
        if (!roomId) return;
        const room = rooms.get(roomId);
        if (!room) return;
        if (role === 'share') {
          // 来自共享端（串口回执 或 本页发送），始终广播给所有链接端
          room.links.forEach((l) => send(l, { t: 'serial-data', buf: msg.buf, from: 'share', src: msg.src || 'share' }));
        } else if (role === 'link') {
          // 来自链接端：转发给共享端写串口
          if (room.share) send(room.share, { t: 'serial-data', buf: msg.buf, from: 'link', src: 'link' });
        }
        break;
      }

      case 'serial-config': {
        const { roomId, role } = ws.meta || {};
        if (!roomId) return;
        const room = rooms.get(roomId);
        if (!room) return;
        if (role === 'share') {
          // 共享端主动变更: 通知所有链接端并缓存
          room.cfg = msg.cfg;
          room.links.forEach((l) => send(l, { t: 'serial-config', cfg: msg.cfg }));
        } else if (role === 'link') {
          // 链接端请求修改串口参数: 转发给共享端 (由其重设串口)
          if (room.share) send(room.share, { t: 'serial-config', cfg: msg.cfg, from: 'link' });
        }
        break;
      }

      case 'bye': {
        leaveRoom(ws);
        break;
      }
    }
  });

  ws.on('close', () => leaveRoom(ws));
  ws.on('error', () => leaveRoom(ws));
});

server.listen(PORT, () => {
  console.log(`LinkCOM 服务器已启动: http://localhost:${PORT}`);
  console.log(`  共享端: http://localhost:${PORT}/  (选择 COM 口并共享)`);
  console.log(`  链接端: http://localhost:${PORT}/?mode=link  (输入房间码连接)`);
});
