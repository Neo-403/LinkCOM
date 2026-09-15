"""LinkCOM 桌面端 - WebSocket 连接/协议封装

复用 server.js 的现有协议 (JSON over WebSocket):
  客户端 -> 服务器:
    { t:"join", room, role:"share", pwd? }
    { t:"serial-data", buf:"<base64>", src:"share" }
    { t:"serial-config", cfg:{...}, mode, agg?, portOpen? }
    { t:"serial-state", portOpen:bool }
    { t:"bye" }
  服务器 -> 客户端:
    { t:"ok", role, room, peers }
    { t:"err", msg }
    { t:"serial-data", buf:"<base64>", from:"share"|"link", src }
    { t:"serial-config", cfg, from? }
    { t:"peers", share, links }
    { t:"closed", reason }
"""
import base64
import json
import threading
import time

import websocket


def buf_to_b64(data: bytes) -> str:
    return base64.b64encode(data).decode('ascii')


def b64_to_buf(b64: str) -> bytes:
    return base64.b64decode(b64)


class LinkComClient:
    """WebSocket 共享端客户端 (role=share)。线程安全。"""

    def __init__(self, server: str, base_path: str = '', room: str = '', pwd: str = ''):
        self.server = server.rstrip('/')
        self.base_path = (base_path or '').strip()
        if self.base_path and not self.base_path.startswith('/'):
            self.base_path = '/' + self.base_path
        if self.base_path.endswith('/'):
            self.base_path = self.base_path[:-1]
        self.room = room
        self.pwd = pwd

        self._ws = None
        self._thread = None
        self._running = False
        self._joined = False
        self._reconnect = True
        self._lock = threading.Lock()

        # 回调 (由 GUI 设置)。所有回调在 WebSocket 线程或独立线程触发,
        # GUI 内部需自行切回主线程。
        self.on_open = None          # (ws_open:bool)
        self.on_join = None          # (room, peers)
        self.on_error = None         # (msg)
        self.on_peers = None         # (share:bool, links:int)
        self.on_closed = None        # (reason)
        self.on_data_from_link = None  # (raw_bytes) 来自链接端, 需写回通道
        self.on_remote_cfg = None    # (cfg) 链接端请求改参数
        self.on_log = None           # (text, is_err)

    # ---------- 公共 API ----------
    def start(self):
        self._running = True
        self._reconnect = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._running = False
        self._reconnect = False
        try:
            self._ws.close()
        except Exception:
            pass

    def send_data(self, data: bytes, kind: str = None):
        """通道收到的数据 -> 上行服务器 (src=share)。
        kind='tx' 表示共享端主动发送(链接端显示为"共享端发送")，
        默认(None)表示通道回执(串口/TCP 硬件读到的数据，链接端显示为←接收)。"""
        with self._lock:
            if self._ws and self._ws.sock and self._ws.sock.connected:
                try:
                    msg = {
                        't': 'serial-data', 'buf': buf_to_b64(data), 'src': 'share'
                    }
                    if kind:
                        msg['kind'] = kind
                    self._ws.send(json.dumps(msg))
                    return True
                except Exception as e:
                    self._log('发送数据失败: ' + str(e), True)
        return False

    def send_config(self, cfg: dict, mode: str = 'serial', agg: dict = None, port_open: bool = None):
        with self._lock:
            if self._ws and self._ws.sock and self._ws.sock.connected:
                try:
                    msg = {'t': 'serial-config', 'cfg': cfg, 'mode': mode}
                    if agg is not None:
                        msg['agg'] = agg
                    # 完整配置可一并携带最新通道打开状态, 供新加入的链接端同步
                    if isinstance(port_open, bool):
                        msg['portOpen'] = port_open
                    self._ws.send(json.dumps(msg))
                except Exception:
                    pass

    def send_state(self, port_open: bool):
        """通道打开/关闭状态实时同步给链接端 (serial-state), 使其未打开时无法发送"""
        with self._lock:
            if self._ws and self._ws.sock and self._ws.sock.connected:
                try:
                    self._ws.send(json.dumps({'t': 'serial-state', 'portOpen': bool(port_open)}))
                except Exception:
                    pass

    def send_bye(self):
        with self._lock:
            if self._ws and self._ws.sock and self._ws.sock.connected:
                try:
                    self._ws.send(json.dumps({'t': 'bye'}))
                except Exception:
                    pass

    # ---------- 内部 ----------
    def _ws_url(self) -> str:
        # server 形如 ws://host:port 或 wss://host:port
        return f"{self.server}{self.base_path}/ws"

    def _log(self, text, is_err=False):
        if self.on_log:
            try:
                self.on_log(text, is_err)
            except Exception:
                pass

    def _run(self):
        while self._running:
            try:
                url = self._ws_url()
                self._log('连接服务器: ' + url)
                self._ws = websocket.WebSocketApp(
                    url,
                    on_open=self._on_open,
                    on_message=self._on_message,
                    on_error=self._on_error,
                    on_close=self._on_close,
                )
                self._ws.run_forever(ping_interval=20, ping_timeout=10)
            except Exception as e:
                self._log('WebSocket 异常: ' + str(e), True)

            if not self._running:
                break
            if self._reconnect:
                self._log('服务器断开, 2s 后重连…')
                time.sleep(2)
        self._log('WebSocket 线程结束')

    def _on_open(self, ws):
        self._joined = False
        if self.on_open:
            self.on_open(True)
        # 自动 join
        try:
            ws.send(json.dumps({
                't': 'join', 'room': self.room, 'role': 'share', 'pwd': self.pwd
            }))
        except Exception as e:
            self._log('发送 join 失败: ' + str(e), True)

    def _on_message(self, ws, raw):
        try:
            m = json.loads(raw)
        except Exception:
            return
        t = m.get('t')
        if t == 'ok':
            self._joined = True
            if self.on_join:
                self.on_join(m.get('room'), m.get('peers', {}))
        elif t == 'err':
            if self.on_error:
                self.on_error(m.get('msg', ''))
        elif t == 'peers':
            if self.on_peers:
                self.on_peers(m.get('share', False), m.get('links', 0))
        elif t == 'closed':
            if self.on_closed:
                self.on_closed(m.get('reason', ''))
        elif t == 'serial-data':
            if m.get('from') == 'link':
                data = b64_to_buf(m.get('buf', ''))
                if self.on_data_from_link:
                    self.on_data_from_link(data)
        elif t == 'serial-config':
            if m.get('from') == 'link' and self.on_remote_cfg:
                self.on_remote_cfg(m.get('cfg', {}), m.get('mode', 'serial'), m.get('agg', None))

    def _on_error(self, ws, err):
        self._log('WebSocket 错误: ' + str(err), True)
        if self.on_open:
            self.on_open(False)

    def _on_close(self, ws, *args):
        self._joined = False
        if self.on_open:
            self.on_open(False)
