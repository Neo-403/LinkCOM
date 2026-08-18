"""通道抽象基类

通道 = 数据源/数据汇 (串口 / TCP 连接)。统一接口:
  - open(): 建立连接, 启动读循环
  - close(): 关闭
  - write(data): 把来自链接端的数据写回通道
  - on_data: 回调, 通道收到数据时触发 (bytes), 由上层上行服务器

所有网络/串口读都在独立线程中进行, 通过 on_data 回调把字节交给上层。
"""
import threading


class Channel:
    def __init__(self):
        self.on_data = None      # (bytes) -> None
        self.on_status = None    # (text, is_err) -> None
        self._running = False

    def open(self):
        raise NotImplementedError

    def close(self):
        self._running = False

    def write(self, data: bytes):
        raise NotImplementedError

    def is_open(self):
        return self._running

    def _emit_data(self, data: bytes):
        if self.on_data and data:
            try:
                self.on_data(data)
            except Exception:
                pass

    def _emit_status(self, text, is_err=False):
        if self.on_status:
            try:
                self.on_status(text, is_err)
            except Exception:
                pass

    @staticmethod
    def _reader_loop(recv_fn, stop_fn, chunk=4096):
        """通用读循环: recv_fn()->bytes|None, stop_fn()->bool"""
        while not stop_fn():
            try:
                data = recv_fn()
            except Exception:
                break
            if data is None:
                continue
            if data:
                yield data
        return
