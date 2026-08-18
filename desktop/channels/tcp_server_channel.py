"""TCP Server 通道

在本机监听 (指定网卡 IP + 端口)。多客户端合并: 任一客户端的数据都上行到房间;
房间下发的 link 数据广播给所有已连入的客户端。
"""
import socket
import threading

from .base import Channel


class TcpServerChannel(Channel):
    def __init__(self, local_ip, local_port):
        super().__init__()
        self.local_ip = local_ip.strip()
        if not self.local_ip:
            self.local_ip = '0.0.0.0'
        self.local_port = int(local_port)
        self._listen = None
        self._accept_thread = None
        self._clients = []          # list of socket
        self._client_threads = []
        self._lock = threading.Lock()

    def open(self):
        if self._running:
            return
        if not self.local_port:
            self._emit_status('TCP Server 需填写监听端口', True)
            return
        try:
            self._listen = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._listen.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._listen.bind((self.local_ip, self.local_port))
            self._listen.listen(8)
            self._listen.settimeout(0.5)
        except OSError as e:
            if e.winerror == 10048:
                self._emit_status(
                    f'TCP 监听失败: 端口 {self.local_port} 已被占用 (WinError 10048)。'
                    f'可能上一次未完全关闭, 请先「关闭通道」或换一个端口重试。', True)
            else:
                self._emit_status('TCP 监听失败: ' + str(e), True)
            self._listen = None
            return
        except Exception as e:
            self._emit_status('TCP 监听失败: ' + str(e), True)
            self._listen = None
            return
        self._running = True
        bind = self._listen.getsockname()
        self._emit_status(f'TCP Server 监听中 {bind[0]}:{bind[1]}')
        self._accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._accept_thread.start()

    def _accept_loop(self):
        while self._running and self._listen:
            try:
                conn, addr = self._listen.accept()
            except socket.timeout:
                continue
            except Exception:
                break
            with self._lock:
                self._clients.append(conn)
            self._emit_status(f'TCP 客户端接入 {addr[0]}:{addr[1]} (共 {len(self._clients)} 个)')
            t = threading.Thread(target=self._client_loop, args=(conn, addr), daemon=True)
            self._client_threads.append(t)
            t.start()

    def _client_loop(self, conn, addr):
        while self._running:
            try:
                data = conn.recv(4096)
            except socket.timeout:
                continue
            except Exception:
                break
            if not data:
                break
            self._emit_data(data)
        with self._lock:
            if conn in self._clients:
                self._clients.remove(conn)
        try:
            conn.close()
        except Exception:
            pass
        self._emit_status(f'TCP 客户端断开 {addr[0]}:{addr[1]} (剩 {len(self._clients)} 个)')

    def write(self, data: bytes):
        # 广播给所有客户端
        with self._lock:
            targets = list(self._clients)
        if not targets:
            return False
        for c in targets:
            try:
                c.sendall(data)
            except Exception:
                pass
        return True

    def close(self):
        self._running = False
        with self._lock:
            for c in list(self._clients):
                try:
                    c.close()
                except Exception:
                    pass
            self._clients.clear()
        try:
            if self._listen:
                self._listen.close()
        except Exception:
            pass
        self._listen = None
        self._emit_status('TCP Server 已关闭')

    def config_dict(self):
        return {
            'baudRate': '-', 'dataBits': '-', 'stopBits': '-',
            'parity': 'none', 'flowControl': 'none', 'encoding': 'utf8',
        }
