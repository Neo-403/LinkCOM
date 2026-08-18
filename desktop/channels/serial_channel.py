"""串口通道 (pyserial)"""
import threading

import serial

from .base import Channel


def _map_parity(p):
    return {'none': 'N', 'odd': 'O', 'even': 'E', 'mark': 'M', 'space': 'S'}.get(p, 'N')


def _map_stop_bits(v):
    try:
        f = float(v)
    except Exception:
        f = 1
    if f == 1.5:
        return serial.STOPBITS_ONE_POINT_FIVE
    if f == 2:
        return serial.STOPBITS_TWO
    return serial.STOPBITS_ONE


class SerialChannel(Channel):
    def __init__(self, port, baud_rate, data_bits=8, stop_bits=1,
                 parity='none', flow_control='none', encoding='utf8',
                 read_timeout=0.3, read_size=4096):
        super().__init__()
        self.port_name = port
        self.baud_rate = int(baud_rate)
        self.data_bits = int(data_bits)
        self.stop_bits = stop_bits
        self.parity = _map_parity(parity)
        self.flow_control = flow_control
        self.encoding = encoding
        self.read_timeout = max(0.0, float(read_timeout))  # 聚合窗口(秒): pyserial 读超时, 0 表示即时
        self.read_size = max(1, int(read_size))            # 单次读取缓冲上限(字节)
        self._ser = None
        self._thread = None

    def open(self):
        if self._running:
            return
        try:
            self._ser = serial.Serial(
                port=self.port_name,
                baudrate=self.baud_rate,
                bytesize=self.data_bits,
                stopbits=_map_stop_bits(self.stop_bits),
                parity=self.parity,
                xonxoff=(self.flow_control == 'software'),
                rtscts=(self.flow_control == 'hardware'),
                timeout=self.read_timeout,
                write_timeout=2.0,
            )
        except Exception as e:
            self._emit_status('打开串口失败: ' + str(e), True)
            return
        self._running = True
        self._thread = threading.Thread(target=self._read_loop, daemon=True)
        self._thread.start()
        self._emit_status(f'串口已打开 {self.baud_rate} {self.data_bits}{self.parity}{self.stop_bits}')

    def _read_loop(self):
        while self._running and self._ser and self._ser.is_open:
            try:
                data = self._ser.read(self.read_size)
            except Exception as e:
                if self._running:
                    self._emit_status('读串口异常: ' + str(e), True)
                break
            if data:
                self._emit_data(data)
        # 读线程结束不代表必须关闭通道对象; 仅置标志
        if self._running:
            self._running = False
            self._emit_status('串口读线程结束 (设备可能断开)', False)

    def write(self, data: bytes):
        if self._ser and self._ser.is_open:
            try:
                self._ser.write(data)
                return True
            except Exception as e:
                self._emit_status('写入串口失败: ' + str(e), True)
                return False
        return False

    def close(self):
        self._running = False
        try:
            if self._ser and self._ser.is_open:
                self._ser.close()
        except Exception:
            pass
        self._ser = None
        self._emit_status('串口已关闭')

    def config_dict(self):
        return {
            'baudRate': self.baud_rate,
            'dataBits': self.data_bits,
            'stopBits': self.stop_bits,
            'parity': self.parity,
            'flowControl': self.flow_control,
            'encoding': self.encoding,
        }
