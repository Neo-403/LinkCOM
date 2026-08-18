"""TCP Client 通道

作为客户端连到远端设备。可指定本地出口网卡 IP 与端口 (端口留空则随机)。
"""
import socket
import threading

from .base import Channel


class TcpClientChannel(Channel):
    def __init__(self, remote_host, remote_port, local_ip='', local_port=''):
        super().__init__()
        self.remote_host = remote_host
        self.remote_port = int(remote_port)
        self.local_ip = local_ip.strip()
        self.local_port = int(local_port) if str(local_port).strip() else 0
        self._sock = None
        self._thread = None

    def open(self):
        if self._running:
            return
        if not self.remote_host or not self.remote_port:
            self._emit_status('TCP Client 需填写远端主机与端口', True)
            return
        try:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._sock.settimeout(0.3)
            # 指定本地出口地址 (多网卡场景)
            if self.local_ip:
                self._sock.bind((self.local_ip, self.local_port))
            self._sock.connect((self.remote_host, self.remote_port))
        except OSError as e:
            if e.winerror == 10048:
                self._emit_status(
                    f'TCP 连接失败: 本地端口 {self.local_port} 已被占用 '
                    f'(WinError 10048)。请改本地端口或留空随机后重试。', True)
            else:
                self._emit_status('TCP 连接失败: ' + str(e), True)
            self._sock = None
            return
        except Exception as e:
            self._emit_status('TCP 连接失败: ' + str(e), True)
            self._sock = None
            return
        local = self._sock.getsockname()
        self._emit_status(f'TCP 已连接 -> {self.remote_host}:{self.remote_port} (本地出口 {local[0]}:{local[1]})')
        self._running = True
        self._thread = threading.Thread(target=self._read_loop, daemon=True)
        self._thread.start()

    def _read_loop(self):
        while self._running and self._sock:
            try:
                data = self._sock.recv(4096)
            except socket.timeout:
                continue
            except Exception as e:
                if self._running:
                    self._emit_status('TCP 读异常: ' + str(e), True)
                break
            if not data:
                if self._running:
                    self._emit_status('TCP 对端关闭连接', False)
                break
            self._emit_data(data)
        self._running = False

    def write(self, data: bytes):
        if self._sock:
            try:
                self._sock.sendall(data)
                return True
            except Exception as e:
                self._emit_status('TCP 写入失败: ' + str(e), True)
                return False
        return False

    def close(self):
        self._running = False
        try:
            if self._sock:
                self._sock.close()
        except Exception:
            pass
        self._sock = None
        self._emit_status('TCP Client 已关闭')

    def config_dict(self):
        return {
            'baudRate': '-', 'dataBits': '-', 'stopBits': '-',
            'parity': 'none', 'flowControl': 'none', 'encoding': 'utf8',
        }
