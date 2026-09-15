"""LinkCOM 桌面端 - PySide6 主窗口

三种共享模式 (Tab): 串口 / TCP Client / TCP Server
统一: 房间码 + WEB 服务器配置 + 日志终端 + 收发统计 + 富发送区
协议复用 server.js (WebSocket /ws, role=share)
"""
import json
import os
import sys
import time

from PySide6.QtCore import Qt, QObject, Signal, Slot, QTimer, QUrl, QEvent, QSize
from PySide6.QtGui import QDesktopServices, QIcon
from PySide6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout, QTabWidget, QGroupBox,
    QLabel, QLineEdit, QPushButton, QComboBox, QCheckBox, QTextEdit, QPlainTextEdit,
    QSpinBox, QStatusBar, QFileDialog, QMessageBox, QFrame, QInputDialog,
    QListWidget, QListWidgetItem, QDialog, QFormLayout,
)
from PySide6.QtGui import QTextCursor, QColor, QPalette

from config import load_config, save_config
from linkcom_client import LinkComClient
from channels import SerialChannel, TcpClientChannel, TcpServerChannel
from net_util import list_local_ips
from codecs_util import decode_text, encode_text, hex_lines, text_of
from sniffer import Sniffer, hex_to_bytes, new_rule_id

MAX_HISTORY = 5000


class Bridge(QObject):
    """WebSocket 线程 -> 主线程 信号桥接"""
    sig_log = Signal(str, bool)
    sig_ws_open = Signal(bool)
    sig_join = Signal(str, object)
    sig_error = Signal(str)
    sig_peers = Signal(bool, int)
    sig_closed = Signal(str)
    sig_data_from_link = Signal(bytes)
    sig_remote_cfg = Signal(object, str, object)
    sig_channel_data = Signal(bytes)
    sig_channel_status = Signal(str, bool)


# ---------------- 样式 (现代深色 UI) ----------------
_APP_STYLE = """
QWidget { background:#1e1e24; color:#d4d4d4; font-family:"Segoe UI", "Microsoft YaHei", sans-serif; font-size:13px; }
QGroupBox { background:#26262e; border:1px solid #353541; border-radius:8px; margin-top:10px; padding:10px 12px 12px; font-weight:600; }
QGroupBox::title { subcontrol-origin:margin; left:12px; padding:0 4px; color:#9aa0a6; }
QTabWidget::pane { border:1px solid #353541; border-radius:8px; top:6px; }
QTabBar::tab { background:#26262e; color:#9aa0a6; padding:7px 16px; border-top-left-radius:6px; border-top-right-radius:6px; }
QTabBar::tab:selected { background:#1e1e24; color:#3ddc84; border-bottom:2px solid #3ddc84; }
QTabBar::tab:!selected:hover { color:#d4d4d4; }
QLabel { color:#b8bcc4; }
QLineEdit, QComboBox, QPlainTextEdit, QTextEdit {
    background:#15151a; border:1px solid #3a3a45; border-radius:6px; padding:5px 8px; color:#e6e6e6; selection-background-color:#3ddc84; selection-color:#15151a;
}
QLineEdit:focus, QComboBox:focus, QPlainTextEdit:focus, QTextEdit:focus { border:1px solid #3ddc84; }
QPushButton { background:#3a3a45; color:#e6e6e6; border:none; border-radius:6px; padding:7px 14px; font-weight:600; }
QPushButton:hover { background:#474754; }
QPushButton:pressed { background:#2c2c34; }
QPushButton:disabled { background:#2a2a32; color:#5a5a64; }
QTextEdit#term { background:#15151a; }
QStatusBar { background:#15151a; color:#9aa0a6; }
"""

_CHECK_STYLE = """
QCheckBox { color:#b8bcc4; spacing:5px; }
QCheckBox::indicator { width:15px; height:15px; border:1px solid #3a3a45; border-radius:4px; background:#15151a; }
QCheckBox::indicator:checked { background:#3ddc84; border:1px solid #3ddc84; image:none; }
"""

_TERM_STYLE = """
QTextEdit { background:#15151a; border:1px solid #353541; border-radius:8px; padding:8px 10px; }
"""


def _resolve_resource(name):
    """定位打包内嵌/开发态资源文件。单文件 exe 运行时在 sys._MEIPASS 下。"""
    if getattr(sys, 'frozen', False):
        base = sys._MEIPASS
    else:
        base = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base, name)


def _read_version():
    """以项目根目录 VERSION 为唯一版本来源 (桌面端运行时读取)。"""
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, '..', 'VERSION'),          # 开发态: desktop/../VERSION
        os.path.join(here, 'VERSION'),                # 开发态(已复制)
        os.path.join(getattr(sys, '_MEIPASS', here), 'VERSION'),  # 打包态
    ]
    for p in candidates:
        try:
            with open(p, 'r', encoding='utf-8') as f:
                v = f.read().strip()
                if v:
                    return v
        except Exception:
            continue
    return '1.0.0'


class MainWindow(QWidget):
    def __init__(self, cfg, startup=None):
        super().__init__()
        self.setStyleSheet(_APP_STYLE)
        # 窗口图标 (打包态从 _MEIPASS 取, 开发态从脚本目录取)
        icon_path = _resolve_resource('logo.png')
        if os.path.exists(icon_path):
            self.setWindowIcon(QIcon(icon_path))
        self.cfg = cfg
        self.client = None
        self.channel = None
        self.history = []   # (ts, cls, bytes)
        self.rx_bytes = 0
        self.tx_bytes = 0
        self.paused = False
        self.encoding = cfg['display'].get('encoding', 'gbk')
        self.mode_text = cfg['display'].get('modeText', True)
        self.mode_hex = cfg['display'].get('modeHex', False)
        self.show_ts = cfg['display'].get('showTs', True)
        self.auto_scroll = cfg['display'].get('autoScroll', True)
        self.flush_ms = cfg['display'].get('flushMs', 80)      # 聚合窗口(ms): 串口读取超时, 0=即时
        self.max_buf_kb = cfg['display'].get('maxBufKb', 4)    # 单次读取缓冲上限(KB)
        # 快速发送条目: {name, hex(bool), crlf(bool), data(str), delay(int ms), checked(bool)}
        self.quick_items = cfg.get('quick') or []
        if not isinstance(self.quick_items, list):
            self.quick_items = []
        # 快速匹配 (Sniffer): 规则/记录存配置 sniffer 字段, 逻辑与 Web 端 sniffer.js 对齐
        self.sniffer = Sniffer(lambda: self.encoding)
        sn_st = cfg.get('sniffer')
        if isinstance(sn_st, dict):
            self.sniffer.load_storage(sn_st)

        self.bridge = Bridge()
        self.bridge.sig_log.connect(self.append_log)
        self.bridge.sig_ws_open.connect(self.on_ws_open)
        self.bridge.sig_join.connect(self.on_joined)
        self.bridge.sig_error.connect(self.on_server_error)
        self.bridge.sig_peers.connect(self.on_peers)
        self.bridge.sig_closed.connect(lambda r: self.append_log('链接端断开: ' + str(r), False))
        self.bridge.sig_data_from_link.connect(self.on_data_from_link)
        self.bridge.sig_remote_cfg.connect(self.on_remote_cfg)
        self.bridge.sig_channel_data.connect(self.on_channel_data)
        self.bridge.sig_channel_status.connect(lambda t, e: self.append_log(t, e))

        self._build_ui()
        self._load_cfg_to_ui()
        # 房间码自动生成 (若未配置), 用户可手动修改
        if not self.ed_room.text().strip():
            self.ed_room.setText(self._gen_room())
        if startup:
            self._apply_startup(startup)

    # ---------------- UI 构建 ----------------
    def _build_ui(self):
        self.setWindowTitle('LinkCOM 桌面端')
        self.resize(900, 680)
        root = QVBoxLayout(self)

        # ===== 服务器 / 房间 配置 =====
        srv_box = QGroupBox('服务器与房间')
        srv = QHBoxLayout(srv_box)
        srv.addWidget(QLabel('WEB 服务器:'))
        self.ed_server = QLineEdit()
        self.ed_server.setPlaceholderText('ws://127.0.0.1:8080 或 wss://your.domain/linkcom')
        srv.addWidget(self.ed_server, 3)
        srv.addWidget(QLabel('房间码:'))
        self.ed_room = QLineEdit()
        srv.addWidget(self.ed_room, 1)
        srv.addWidget(QLabel('密码:'))
        self.ed_pwd = QLineEdit()
        self.ed_pwd.setEchoMode(QLineEdit.Password)
        srv.addWidget(self.ed_pwd, 1)
        root.addWidget(srv_box)

        # ===== 模式 Tab =====
        self.tabs = QTabWidget()
        self.tabs.addTab(self._build_serial_tab(), '串口 COM')
        self.tabs.addTab(self._build_tcp_client_tab(), 'TCP Client')
        self.tabs.addTab(self._build_tcp_server_tab(), 'TCP Server')
        root.addWidget(self.tabs)

        # ===== 控制栏 =====
        ctrl = QHBoxLayout()
        self.btn_open = QPushButton('打开通道')
        self.btn_open.clicked.connect(self.toggle_channel)
        ctrl.addWidget(self.btn_open)
        self.btn_share = QPushButton('共享通道')
        self.btn_share.clicked.connect(self.toggle_connect)
        ctrl.addWidget(self.btn_share)
        self.ws_dot = QLabel('●')
        self.ws_dot.setStyleSheet('color:gray')
        self.ws_stat = QLabel('未连接')
        ctrl.addWidget(self.ws_dot)
        ctrl.addWidget(self.ws_stat)
        ctrl.addWidget(QLabel('房间:'))
        self.lb_room = QLabel('-')
        ctrl.addWidget(self.lb_room)
        ctrl.addWidget(QLabel('链接端:'))
        self.lb_peers = QLabel('0')
        ctrl.addWidget(self.lb_peers)
        # 共享中可点击的"共享链接" (点击复制网页链接 + 一键唤起 linkcom://)
        self.link_label = QLabel('<a href="#">共享链接</a>')
        self.link_label.setStyleSheet('color:#1565c0; text-decoration:underline;')
        self.link_label.setCursor(Qt.PointingHandCursor)
        self.link_label.linkActivated.connect(self.on_share_link_click)
        self.link_label.setVisible(False)
        ctrl.addWidget(self.link_label)
        ctrl.addStretch(1)
        ctrl.addWidget(QLabel('RX:'))
        self.lb_rx = QLabel('0 B')
        ctrl.addWidget(self.lb_rx)
        ctrl.addWidget(QLabel('TX:'))
        self.lb_tx = QLabel('0 B')
        ctrl.addWidget(self.lb_tx)
        root.addLayout(ctrl)

        # ===== 显示模式 =====
        disp = QHBoxLayout()
        self.cb_text = QCheckBox('文本')
        self.cb_hex = QCheckBox('HEX')
        self.cb_ts = QCheckBox('时间戳')
        self.cb_text.setChecked(self.mode_text)
        self.cb_hex.setChecked(self.mode_hex)
        self.cb_ts.setChecked(self.show_ts)
        self.cb_text.stateChanged.connect(self.rerender)
        self.cb_hex.stateChanged.connect(self.rerender)
        self.cb_ts.stateChanged.connect(self.rerender)
        self.cb_text.setStyleSheet(_CHECK_STYLE)
        self.cb_hex.setStyleSheet(_CHECK_STYLE)
        self.cb_ts.setStyleSheet(_CHECK_STYLE)
        disp.addWidget(self.cb_text)
        disp.addWidget(self.cb_hex)
        disp.addWidget(self.cb_ts)
        disp.addWidget(QLabel('编码:'))
        self.cb_enc = QComboBox()
        self.cb_enc.addItems(['gbk', 'utf8'])
        self.cb_enc.setCurrentText(self.encoding)
        self.cb_enc.currentTextChanged.connect(self.on_encoding_changed)
        disp.addWidget(self.cb_enc)
        disp.addStretch(1)
        self.cb_autoscroll = QCheckBox('自动滚动')
        self.cb_autoscroll.setChecked(self.auto_scroll)
        self.cb_autoscroll.stateChanged.connect(self.on_autoscroll_changed)
        self.cb_autoscroll.setStyleSheet(_CHECK_STYLE)
        disp.addWidget(self.cb_autoscroll)
        self.btn_pause = QPushButton('暂停')
        self.btn_pause.clicked.connect(self.toggle_pause)
        disp.addWidget(self.btn_pause)
        self.btn_clear = QPushButton('清空')
        self.btn_clear.clicked.connect(self.clear_log)
        disp.addWidget(self.btn_clear)
        self.btn_export = QPushButton('导出历史')
        self.btn_export.clicked.connect(self.export_history)
        disp.addWidget(self.btn_export)
        root.addLayout(disp)

        # ===== 日志终端 =====
        self.term = QTextEdit()
        self.term.setReadOnly(True)
        self.term.setLineWrapMode(QTextEdit.NoWrap)
        self.term.setStyleSheet(_TERM_STYLE)
        mono = self.term.font()
        mono.setFamily('Consolas')
        self.term.setFont(mono)
        root.addWidget(self.term, 3)

        # ===== 发送区 =====
        send_box = QGroupBox('发送')
        send = QHBoxLayout(send_box)
        self.ed_send = QPlainTextEdit()
        self.ed_send.setPlaceholderText('文本模式输入文本, 勾选 HEX 则输入十六进制 (如 01 A2 FF)\n回车发送, Shift+回车换行')
        self.ed_send.setMinimumHeight(56)
        self.ed_send.setMaximumHeight(120)
        self.ed_send.installEventFilter(self)
        send.addWidget(self.ed_send, 4)
        # 右侧三行: 发送(高一点) / HEX / 自动加\r\n
        send_side = QVBoxLayout()
        send_side.setSpacing(4)
        self.btn_send = QPushButton('发送')
        self.btn_send.setMinimumHeight(34)
        self.btn_send.setStyleSheet('QPushButton { font-weight:700; }')
        self.btn_send.clicked.connect(self.do_send)
        send_side.addWidget(self.btn_send, 2)
        self.cb_send_hex = QCheckBox('HEX')
        send_side.addWidget(self.cb_send_hex)
        self.cb_send_crlf = QCheckBox('自动加 \\r\\n')
        send_side.addWidget(self.cb_send_crlf)
        send.addLayout(send_side, 0)
        root.addWidget(send_box)

        # ===== 快速发送 (与 Web 端 quick.js 功能一致) =====
        self._build_quick_send(root)

        # ===== 快速匹配 (与 Web 端 sniffer.js 功能一致) =====
        self._build_sniffer(root)

        # 状态栏
        self.status = QStatusBar()
        self.status.showMessage('就绪')
        credit = QLabel('<a href="https://github.com/Neo-403/LinkCOM" style="color:#8a98a8; text-decoration:none;">LinkCOM v' + _read_version() + ' | by ZWZW</a>')
        credit.setOpenExternalLinks(True)  # 点击用默认浏览器打开 GitHub 项目页
        credit.setStyleSheet('color:#8a98a8; padding-right:8px;')
        self.status.addPermanentWidget(credit)
        root.addWidget(self.status)

    def _build_serial_tab(self):
        w = QWidget()
        v = QVBoxLayout(w)
        h = QHBoxLayout()
        h.addWidget(QLabel('COM 口:'))
        self.cb_com = QComboBox()
        self.cb_com.setEditable(True)
        h.addWidget(self.cb_com, 2)
        self.btn_refresh_com = QPushButton('刷新')
        self.btn_refresh_com.clicked.connect(self.refresh_com)
        h.addWidget(self.btn_refresh_com)
        v.addLayout(h)
        h2 = QHBoxLayout()
        h2.addWidget(QLabel('波特率:'))
        self.cb_baud = QComboBox(); self.cb_baud.setEditable(True)
        self.cb_baud.addItems(['1200', '2400', '4800', '9600', '19200', '38400',
                               '57600', '115200', '230400', '460800', '921600'])
        self.cb_baud.setCurrentText('115200')
        h2.addWidget(self.cb_baud)
        h2.addWidget(QLabel('数据位:'))
        self.cb_dbits = QComboBox(); self.cb_dbits.addItems(['4', '5', '6', '7', '8'])
        self.cb_dbits.setCurrentText('8')
        h2.addWidget(self.cb_dbits)
        h2.addWidget(QLabel('停止位:'))
        self.cb_sbits = QComboBox(); self.cb_sbits.addItems(['1', '1.5', '2'])
        self.cb_sbits.setCurrentText('1')
        h2.addWidget(self.cb_sbits)
        h2.addWidget(QLabel('校验:'))
        self.cb_parity = QComboBox(); self.cb_parity.addItems(['none', 'odd', 'even', 'mark', 'space'])
        self.cb_parity.setCurrentText('none')
        h2.addWidget(self.cb_parity)
        h2.addWidget(QLabel('流控:'))
        self.cb_flow = QComboBox(); self.cb_flow.addItems(['none', 'hardware', 'software'])
        self.cb_flow.setCurrentText('none')
        h2.addWidget(self.cb_flow)
        # 聚合参数 (放在流控之后)
        h2.addWidget(QLabel('聚合(ms):'))
        self.sb_flush = QSpinBox()
        self.sb_flush.setRange(0, 2000)
        self.sb_flush.setSingleStep(10)
        self.sb_flush.setValue(self.flush_ms)
        self.sb_flush.setButtonSymbols(QSpinBox.NoButtons)
        self.sb_flush.setToolTip('串口读取聚合窗口: 该时间内到达的数据合并为一条 (0=即时)')
        self.sb_flush.valueChanged.connect(self.on_agg_changed)
        h2.addWidget(self.sb_flush)
        h2.addWidget(QLabel('缓冲(KB):'))
        self.sb_buf = QSpinBox()
        self.sb_buf.setRange(1, 1024)
        self.sb_buf.setValue(self.max_buf_kb)
        self.sb_buf.setButtonSymbols(QSpinBox.NoButtons)
        self.sb_buf.setToolTip('单次串口读取缓冲上限 (KB)')
        self.sb_buf.valueChanged.connect(self.on_agg_changed)
        h2.addWidget(self.sb_buf)
        v.addLayout(h2)
        v.addStretch(1)
        self.refresh_com()
        # COM 参数变化时, 若处于共享中则实时把新配置同步给链接端
        for cb in (self.cb_baud, self.cb_dbits, self.cb_sbits, self.cb_parity, self.cb_flow):
            cb.currentTextChanged.connect(self.on_serial_cfg_changed)
        return w

    def on_serial_cfg_changed(self, _=None):
        # 共享中且为串口模式时, 把最新 COM 配置实时同步给链接端
        if self.client and self.client._joined and self.tabs.currentIndex() == 0:
            self.send_config()

    def _build_tcp_client_tab(self):
        w = QWidget()
        v = QVBoxLayout(w)
        h = QHBoxLayout()
        h.addWidget(QLabel('本地出口IP:'))
        self.cb_tc_local_ip = QComboBox()
        self.cb_tc_local_ip.addItems(['(默认/随机)'] + list_local_ips())
        h.addWidget(self.cb_tc_local_ip, 2)
        h.addWidget(QLabel('本地端口:'))
        self.ed_tc_local_port = QLineEdit()
        self.ed_tc_local_port.setPlaceholderText('留空随机')
        h.addWidget(self.ed_tc_local_port, 1)
        v.addLayout(h)
        h2 = QHBoxLayout()
        h2.addWidget(QLabel('远端主机:'))
        self.ed_tc_remote_host = QLineEdit()
        self.ed_tc_remote_host.setPlaceholderText('目标设备 IP 或域名')
        h2.addWidget(self.ed_tc_remote_host, 3)
        h2.addWidget(QLabel('远端端口:'))
        self.ed_tc_remote_port = QLineEdit()
        h2.addWidget(self.ed_tc_remote_port, 1)
        v.addLayout(h2)
        v.addStretch(1)
        return w

    def _build_tcp_server_tab(self):
        w = QWidget()
        v = QVBoxLayout(w)
        h = QHBoxLayout()
        h.addWidget(QLabel('本地监听IP:'))
        self.cb_ts_local_ip = QComboBox()
        self.cb_ts_local_ip.addItems(['0.0.0.0 (全部)'] + list_local_ips())
        h.addWidget(self.cb_ts_local_ip, 2)
        h.addWidget(QLabel('监听端口:'))
        self.ed_ts_local_port = QLineEdit()
        self.ed_ts_local_port.setPlaceholderText('如 9000')
        h.addWidget(self.ed_ts_local_port, 1)
        v.addLayout(h)
        v.addWidget(QLabel('多客户端: 任一客户端数据合并上行, 下发数据广播给所有客户端'))
        v.addStretch(1)
        return w

    # ---------------- 配置载入 ----------------
    def _load_cfg_to_ui(self):
        c = self.cfg
        self.ed_server.setText(c.get('server', ''))
        self.ed_room.setText(c.get('room', ''))
        self.ed_pwd.setText(c.get('pwd', ''))
        self.tabs.setCurrentIndex({'serial': 0, 'tcpClient': 1, 'tcpServer': 2}.get(c.get('mode', 'serial'), 0))
        s = c.get('serial', {})
        if s.get('port'): self.cb_com.setCurrentText(str(s['port']))
        if s.get('baudRate'): self.cb_baud.setCurrentText(str(s['baudRate']))
        if s.get('dataBits'): self.cb_dbits.setCurrentText(str(s['dataBits']))
        if s.get('stopBits'): self.cb_sbits.setCurrentText(str(s['stopBits']))
        if s.get('parity'): self.cb_parity.setCurrentText(str(s['parity']))
        if s.get('flowControl'): self.cb_flow.setCurrentText(str(s['flowControl']))
        t = c.get('tcpClient', {})
        if t.get('localIp'): self.cb_tc_local_ip.setCurrentText(t['localIp'])
        if t.get('localPort'): self.ed_tc_local_port.setText(str(t['localPort']))
        if t.get('remoteHost'): self.ed_tc_remote_host.setText(t['remoteHost'])
        if t.get('remotePort'): self.ed_tc_remote_port.setText(str(t['remotePort']))
        sv = c.get('tcpServer', {})
        if sv.get('localIp'): self.cb_ts_local_ip.setCurrentText(sv['localIp'])
        if sv.get('localPort'): self.ed_ts_local_port.setText(str(sv['localPort']))

    def _apply_startup(self, startup):
        if 'server' in startup: self.ed_server.setText(startup['server'])
        if 'basePath' in startup: pass  # basePath 已并入 server 字符串
        if 'room' in startup: self.ed_room.setText(startup['room'])
        if 'pwd' in startup: self.ed_pwd.setText(startup['pwd'])
        if startup.get('mode') in ('serial', 'tcpClient', 'tcpServer'):
            self.tabs.setCurrentIndex({'serial': 0, 'tcpClient': 1, 'tcpServer': 2}[startup['mode']])
        self.append_log('已通过 linkcom:// 链接预填配置', False)

    def _collect_cfg(self):
        mode_idx = self.tabs.currentIndex()
        mode = ['serial', 'tcpClient', 'tcpServer'][mode_idx]
        c = self.cfg
        c['server'] = self.ed_server.text().strip()
        c['room'] = self.ed_room.text().strip()
        c['pwd'] = self.ed_pwd.text().strip()
        c['mode'] = mode
        c['serial'] = {
            'port': self.cb_com.currentText().strip(),
            'baudRate': int(self.cb_baud.currentText() or 9600),
            'dataBits': int(self.cb_dbits.currentText() or 8),
            'stopBits': float(self.cb_sbits.currentText() or 1),
            'parity': self.cb_parity.currentText(),
            'flowControl': self.cb_flow.currentText(),
            'encoding': self.encoding,
        }
        c['tcpClient'] = {
            'localIp': '' if self.cb_tc_local_ip.currentText().startswith('(默认') else self.cb_tc_local_ip.currentText().strip(),
            'localPort': self.ed_tc_local_port.text().strip(),
            'remoteHost': self.ed_tc_remote_host.text().strip(),
            'remotePort': self.ed_tc_remote_port.text().strip(),
        }
        c['tcpServer'] = {
            'localIp': '' if self.cb_ts_local_ip.currentText().startswith('0.0.0.0') else self.cb_ts_local_ip.currentText().strip(),
            'localPort': self.ed_ts_local_port.text().strip(),
        }
        c['display'] = {
            'modeText': self.cb_text.isChecked(),
            'modeHex': self.cb_hex.isChecked(),
            'showTs': self.cb_ts.isChecked(),
            'flushMs': self.sb_flush.value(),
            'maxBufKb': self.sb_buf.value(),
            'encoding': self.encoding,
            'autoScroll': self.auto_scroll,
            'paused': self.paused,
        }
        c['quick'] = self.quick_items
        c['sniffer'] = self.sniffer.to_storage()
        return c

    # ---------------- 连接/通道 控制 ----------------
    def _ws_url_parts(self, server_str):
        """拆分 server 字符串中的子路径, 返回 (host_url, base_path)"""
        base = ''
        server = server_str
        if '/' in server.replace('://', ''):
            idx = server.find('/', server.find('://') + 3)
            if idx >= 0:
                base = server[idx:]
                server = server[:idx]
        return server, base

    def toggle_connect(self):
        if self.client and self.client._running:
            self.disconnect_server()
        else:
            self.connect_server()

    def connect_server(self):
        c = self._collect_cfg()
        if not c['server']:
            QMessageBox.warning(self, '提示', '请填写 WEB 服务器地址')
            return
        if not c['room']:
            QMessageBox.warning(self, '提示', '请填写房间码')
            return
        save_config(c)
        server, base = self._ws_url_parts(c['server'])
        self.client = LinkComClient(server, base, c['room'], c['pwd'])
        self.client.on_log = lambda t, e: self.bridge.sig_log.emit(t, e)
        self.client.on_open = lambda o: self.bridge.sig_ws_open.emit(o)
        self.client.on_join = lambda r, p: self.bridge.sig_join.emit(r, p)
        self.client.on_error = lambda m: self.bridge.sig_error.emit(m)
        self.client.on_peers = lambda s, l: self.bridge.sig_peers.emit(s, l)
        self.client.on_closed = lambda r: self.bridge.sig_closed.emit(r)
        self.client.on_data_from_link = lambda d: self.bridge.sig_data_from_link.emit(d)
        self.client.on_remote_cfg = lambda cf, md, ag: self.bridge.sig_remote_cfg.emit(cf, md, ag)
        self.client.start()
        self.btn_share.setText('停止共享')
        self.append_log('正在共享通道 (房间 ' + c['room'] + ')', False)

    def disconnect_server(self):
        if self.client:
            self.client.send_bye()
            self.client.stop()
            self.client = None
        self.btn_share.setText('共享通道')
        self.ws_dot.setStyleSheet('color:gray')
        self.ws_stat.setText('未连接')
        self.lb_room.setText('-')
        self.lb_peers.setText('0')
        self.link_label.setVisible(False)
        self.append_log('已停止共享', False)

    def toggle_channel(self):
        if self.channel and self.channel.is_open():
            self.close_channel()
        else:
            self.open_channel()

    def open_channel(self):
        c = self._collect_cfg()
        if self.channel and self.channel.is_open():
            return
        self.channel = self._make_channel(c)
        if self.channel is None:
            return
        self.channel.on_data = lambda d: self.bridge.sig_channel_data.emit(d)
        self.channel.on_status = lambda t, e: self.bridge.sig_channel_status.emit(t, e)
        self.channel.open()
        if not self.channel.is_open():
            self.channel = None
            self.btn_open.setText('打开通道')
            return
        self.btn_open.setText('关闭通道')
        self.append_log('通道已打开', False)
        # 通知链接端通道状态, 使其在通道未打开时禁止发送 (serial-state)
        self._report_serial_state()

    def close_channel(self):
        if self.channel:
            self.channel.close()
            self.channel = None
        self.btn_open.setText('打开通道')
        self.append_log('通道已关闭', False)
        # 通知链接端通道状态, 使其在通道未打开时禁止发送 (serial-state)
        self._report_serial_state()

    def _make_channel(self, c):
        mode = c['mode']
        if mode == 'serial':
            s = c['serial']
            if not s['port']:
                QMessageBox.warning(self, '提示', '请选择 COM 口')
                return None
            return SerialChannel(
                s['port'], s['baudRate'], s['dataBits'], s['stopBits'],
                s['parity'], s['flowControl'], self.encoding,
                read_timeout=max(0.0, self.flush_ms / 1000.0),
                read_size=max(1, self.max_buf_kb * 1024),
            )
        elif mode == 'tcpClient':
            t = c['tcpClient']
            return TcpClientChannel(
                t['remoteHost'], t['remotePort'], t['localIp'], t['localPort'],
            )
        else:
            sv = c['tcpServer']
            return TcpServerChannel(sv['localIp'], sv['localPort'])

    # ---------------- 数据回调 ----------------
    @Slot(bytes)
    def on_channel_data(self, data: bytes):
        self.rx_bytes += len(data)
        self.lb_rx.setText(self.fmt(self.rx_bytes))
        self.push_history(data, 'rx')
        # 上行服务器 -> 链接端 (通道硬件数据, 链接端显示为 ←接收)
        if self.client:
            self.client.send_data(data)

    @Slot(bytes)
    def on_data_from_link(self, data: bytes):
        self.tx_bytes += len(data)
        self.lb_tx.setText(self.fmt(self.tx_bytes))
        self.push_history(data, 'ltx')
        if self.channel:
            self.channel.write(data)

    def do_send(self):
        if not self.channel or not self.channel.is_open():
            QMessageBox.warning(self, '提示', '请先「打开通道」')
            return
        txt = self.ed_send.toPlainText()
        if not txt and not self.cb_send_hex.isChecked():
            return
        try:
            if self.cb_send_hex.isChecked():
                clean = ''.join(ch for ch in txt if ch in '0123456789abcdefABCDEF')
                if len(clean) % 2 != 0:
                    QMessageBox.warning(self, '提示', 'HEX 字节数必须为偶数')
                    return
                buf = bytes(int(clean[i:i+2], 16) for i in range(0, len(clean), 2))
            else:
                s = txt
                if self.cb_send_crlf.isChecked():
                    s += '\r\n'
                buf = encode_text(s, self.encoding)
            self._send_buffer(buf)
        except Exception as e:
            self.append_log('发送异常: ' + str(e), True)

    def _send_buffer(self, buf):
        """通用的本地主动发送: 记录 + 上行 + 写通道。手动发送与快速发送共用。"""
        if not buf:
            return
        if not self.channel or not self.channel.is_open():
            self.append_log('发送失败: 通道未就绪', True)
            return
        try:
            # 先记录并上行, 再写通道 (避免因通道状态跳过记录/上行)
            # kind='tx' 让链接端将这条数据识别为"共享端发送"而非通道回执
            if self.client:
                self.client.send_data(buf, kind='tx')
            if self.channel:
                self.channel.write(buf)
            self.tx_bytes += len(buf)
            self.lb_tx.setText(self.fmt(self.tx_bytes))
            self.push_history(buf, 'tx')
        except Exception as e:
            self.append_log('发送异常: ' + str(e), True)

    def eventFilter(self, obj, event):
        # 发送框: 回车发送, Shift+回车换行
        if obj is self.ed_send and event.type() == QEvent.KeyPress:
            if event.key() in (Qt.Key_Return, Qt.Key_Enter):
                if not (event.modifiers() & Qt.ShiftModifier):
                    self.do_send()
                    return True  # 拦截, 不插入换行
                # Shift+Enter: 放行 -> 换行
        return super().eventFilter(obj, event)

    # ---------------- 渲染 ----------------
    def push_history(self, buf, cls):
        ts = self.now_ts()
        self.history.append((ts, cls, buf))
        if len(self.history) > MAX_HISTORY:
            self.history.pop(0)
        if self.paused:
            return
        # 快速匹配旁路监听 (与 Web 端一致: 暂停时不监听)
        if cls in ('rx', 'tx', 'ltx') and self.sniffer.feed(buf, cls):
            self._sn_schedule_render()
        self.append_line(ts, cls, buf)

    def _color_for(self, cls):
        return {
            'tx': '#3ddc84',   # 本端发送 -> 绿
            'ltx': '#ffb454',  # Link_发送 -> 橙
            'rx': '#4aa8ff',   # 接收 -> 蓝
            'stx': '#c792ea',  # 共享端发送 -> 紫
            'sys': '#9aa0a6',  # 系统 -> 灰
            'err': '#ff6b6b',  # 错误 -> 红
        }.get(cls, '#d4d4d4')

    def append_line(self, ts, cls, buf):
        color = self._color_for(cls)
        dir_text = self.dir_label(cls)
        ts_html = f'<span style="color:#6b7280">[{ts}]</span> ' if self.show_ts else ''
        if self.mode_text and self.mode_hex:
            text_part = text_of(buf, self.encoding).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('\r\n', ' ').replace('\n', ' ').replace('\r', ' ')
            hex_part = hex_lines(buf).replace('\n', ' ')
            html = (f'{ts_html}<span style="color:{color};font-weight:600">{dir_text}</span> '
                    f'<span style="color:{color}">文本: {text_part}</span><br>'
                    f'{ts_html}<span style="color:{color};font-weight:600">{dir_text}</span> '
                    f'<span style="color:#ffd666">HEX: {hex_part}</span>')
        elif self.mode_hex:
            hex_part = hex_lines(buf).replace('\n', '<br>&nbsp;&nbsp;&nbsp;&nbsp;')
            html = f'{ts_html}<span style="color:{color};font-weight:600">{dir_text}</span> <span style="color:#ffd666">HEX: {hex_part}</span>'
        else:
            text_part = text_of(buf, self.encoding).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('\r\n', ' ').replace('\n', ' ').replace('\r', ' ')
            html = f'{ts_html}<span style="color:{color};font-weight:600">{dir_text}</span> <span style="color:{color}">{text_part}</span>'
        self.term.append(html)
        if self.auto_scroll:
            self.term.moveCursor(QTextCursor.End)

    def rerender(self):
        self.mode_text = self.cb_text.isChecked()
        self.mode_hex = self.cb_hex.isChecked()
        self.show_ts = self.cb_ts.isChecked()
        self.term.clear()
        for ts, cls, buf in self.history:
            self.append_line(ts, cls, buf)

    def on_encoding_changed(self, enc):
        self.encoding = enc
        self.rerender()
        # 编码影响快速匹配的显示解码, 重绘记录
        self._sn_schedule_render()

    def on_agg_changed(self, _=None):
        # 聚合参数实时生效(下次打开串口时应用)
        self.flush_ms = self.sb_flush.value()
        self.max_buf_kb = self.sb_buf.value()
        # 共享中实时把新聚合参数同步给链接端
        if self.client and self.client._joined:
            self.send_config()

    def on_autoscroll_changed(self, _=None):
        self.auto_scroll = self.cb_autoscroll.isChecked()

    # ---------------- 快速发送 (对标 Web quick.js) ----------------
    def _build_quick_send(self, root):
        box = QGroupBox('快速发送')
        v = QVBoxLayout(box)
        v.setContentsMargins(10, 4, 10, 10)
        v.setSpacing(6)
        # 标题行 (可点击折叠): 收起/展开 + 摘要
        title_row = QHBoxLayout()
        self.qs_toggle = QPushButton('收起')
        self.qs_toggle.setFixedWidth(56)
        self.qs_toggle.setStyleSheet('QPushButton { font-weight:600; }')
        self.qs_summary = QLabel('共 0 条')
        self.qs_summary.setStyleSheet('color:#9aa0a6')
        title_row.addWidget(self.qs_toggle)
        title_row.addWidget(self.qs_summary)
        title_row.addStretch(1)
        v.addLayout(title_row)

        # 折叠内容容器
        self.qs_body = QWidget()
        body = QVBoxLayout(self.qs_body)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(6)

        # 顶部工具栏 (首行): 添加 / 重置为默认 / 清空 / 导入 / 导出
        bar1 = QHBoxLayout()
        self.qs_add = QPushButton('添加')
        self.qs_reset = QPushButton('重置为默认')
        self.qs_clear = QPushButton('清空')
        self.qs_imp = QPushButton('导入')
        self.qs_exp = QPushButton('导出')
        for b in (self.qs_add, self.qs_reset, self.qs_clear, self.qs_imp, self.qs_exp):
            bar1.addWidget(b)
        bar1.addStretch(1)
        body.addLayout(bar1)

        # 列表
        self.qs_list = QListWidget()
        self.qs_list.setStyleSheet(
            'QListWidget { background:#15151a; border:1px solid #353541; border-radius:8px; }'
            'QListWidget::item { padding:2px; }')
        body.addWidget(self.qs_list, 2)

        # 底部工具栏: 全选(仅发送勾选项) / 顺序发送 / 轮询发送 / 停止 / 状态
        bar2 = QHBoxLayout()
        self.qs_checkall = QCheckBox('全选(仅发送勾选项)')
        self.qs_checkall.setStyleSheet(_CHECK_STYLE)
        self.qs_checkall.stateChanged.connect(self.qs_set_all_checked)
        self.qs_seq = QPushButton('顺序发送')
        self.qs_poll = QPushButton('轮询发送')
        self.qs_stop = QPushButton('停止')
        for b in (self.qs_seq, self.qs_poll, self.qs_stop):
            bar2.addWidget(b)
        bar2.addStretch(1)
        self.qs_run = QLabel('空闲')
        self.qs_run.setStyleSheet('color:#9aa0a6')
        bar2.addWidget(self.qs_run)
        bar2.insertWidget(0, self.qs_checkall)
        body.addLayout(bar2)

        v.addWidget(self.qs_body)
        root.addWidget(box)

        # 信号
        self.qs_toggle.clicked.connect(self.qs_toggle_collapse)
        self.qs_add.clicked.connect(lambda: self.qs_open_editor(None))
        self.qs_reset.clicked.connect(self.qs_reset_defaults)
        self.qs_seq.clicked.connect(self.qs_run_seq)
        self.qs_poll.clicked.connect(self.qs_run_poll)
        self.qs_stop.clicked.connect(self.qs_stop_run)
        self.qs_imp.clicked.connect(self.qs_import)
        self.qs_exp.clicked.connect(self.qs_export)
        self.qs_clear.clicked.connect(self.qs_clear_all)
        self.qs_timer = QTimer(self)
        self.qs_timer.timeout.connect(self.qs_timer_step)
        self.qs_run_mode = 'stop'
        self.qs_run_list = []
        self.qs_run_index = 0
        self.qs_edit_index = None
        self._qs_render()
        # 默认折叠 (避免占据过多空间)
        self.qs_collapsed = False
        self.qs_toggle_collapse()

    def qs_toggle_collapse(self):
        self.qs_collapsed = not self.qs_collapsed
        self.qs_body.setVisible(not self.qs_collapsed)
        self.qs_toggle.setText('展开' if self.qs_collapsed else '收起')

    def _qs_render(self):
        self.qs_list.clear()
        for idx, it in enumerate(self.quick_items):
            item = QListWidgetItem(self.qs_list)
            w = QWidget()
            h = QHBoxLayout(w)
            h.setContentsMargins(4, 2, 4, 2)
            h.setSpacing(6)
            chk = QCheckBox()
            chk.setChecked(it.get('checked', True))
            chk.setStyleSheet(_CHECK_STYLE)
            chk.stateChanged.connect(lambda _, i=idx, c=chk: self._qs_set_checked(i, c.isChecked()))
            name = QLabel(it.get('name', '未命名'))
            name.setMinimumWidth(80)
            name.setStyleSheet('color:#e6e6e6; font-weight:600')
            data = QLabel(it.get('data', ''))
            data.setStyleSheet('color:#9aa0a6')
            data.setMinimumWidth(120)
            tag = QLabel('HEX' if it.get('hex') else '文本')
            tag.setStyleSheet('color:#ffd666' if it.get('hex') else 'color:#4aa8ff')
            delay = QSpinBox()
            delay.setRange(0, 60000)
            delay.setSingleStep(50)
            delay.setValue(int(it.get('delay', 0)))
            delay.setButtonSymbols(QSpinBox.NoButtons)
            delay.setMaximumWidth(64)
            delay.setFixedHeight(28)
            delay.valueChanged.connect(lambda _, i=idx, d=delay: self._qs_set_delay(i, d.value()))
            b_send = QPushButton('发送')
            b_send.setMinimumWidth(54)
            b_send.setFixedHeight(28)
            b_send.clicked.connect(lambda _, i=idx: self.qs_send_one(i))
            b_edit = QPushButton('编辑')
            b_edit.setMinimumWidth(54)
            b_edit.setFixedHeight(28)
            b_edit.clicked.connect(lambda _, i=idx: self.qs_open_editor(i))
            b_del = QPushButton('删')
            b_del.setMinimumWidth(40)
            b_del.setFixedHeight(28)
            b_del.clicked.connect(lambda _, i=idx: self.qs_delete(i))
            h.addWidget(chk)
            h.addWidget(name)
            h.addWidget(data)
            h.addWidget(tag)
            h.addWidget(QLabel('延迟'))
            h.addWidget(delay)
            h.addWidget(QLabel('ms'))
            h.addWidget(b_send)
            h.addWidget(b_edit)
            h.addWidget(b_del)
            w.setMinimumHeight(34)
            item.setSizeHint(QSize(w.sizeHint().width(), 34))
            self.qs_list.setItemWidget(item, w)
        # 摘要 + 全选状态
        n = len(self.quick_items)
        c = sum(1 for it in self.quick_items if it.get('checked', True))
        self.qs_summary.setText(f'共 {n} 条, 已勾选 {c} 条')
        self.qs_checkall.blockSignals(True)
        self.qs_checkall.setChecked(n > 0 and c == n)
        self.qs_checkall.blockSignals(False)

    def _qs_set_checked(self, i, val):
        if 0 <= i < len(self.quick_items):
            self.quick_items[i]['checked'] = val

    def _qs_set_delay(self, i, val):
        if 0 <= i < len(self.quick_items):
            self.quick_items[i]['delay'] = val

    def _qs_item_to_buf(self, it):
        data = it.get('data', '')
        if not data:
            return b''
        if it.get('hex'):
            clean = ''.join(ch for ch in data if ch in '0123456789abcdefABCDEF')
            if len(clean) % 2 != 0:
                return None  # 奇数 HEX
            return bytes(int(clean[i:i+2], 16) for i in range(0, len(clean), 2))
        s = data
        if it.get('crlf'):
            s += '\r\n'
        return encode_text(s, self.encoding)

    def qs_send_one(self, i):
        if not (0 <= i < len(self.quick_items)):
            return
        buf = self._qs_item_to_buf(self.quick_items[i])
        if buf is None:
            self.append_log('快速发送失败: HEX 字节数必须为偶数', True)
            return
        self._send_buffer(buf)

    def qs_open_editor(self, index=None):
        """整块表单对话框 (新增/编辑), 避免一个弹窗一个弹窗地跳"""
        self.qs_edit_index = index
        it = self.quick_items[index] if (index is not None and 0 <= index < len(self.quick_items)) else None
        dlg = QDialog(self)
        dlg.setWindowTitle('快速发送 - ' + ('编辑' if it else '添加'))
        dlg.setMinimumWidth(420)
        dv = QVBoxLayout(dlg)
        # 名称
        hn = QHBoxLayout()
        hn.addWidget(QLabel('名称:'))
        ed_name = QLineEdit(it.get('name', '') if it else '')
        hn.addWidget(ed_name, 1)
        dv.addLayout(hn)
        # 内容
        dv.addWidget(QLabel('内容 (文本或 HEX):'))
        ed_data = QPlainTextEdit(it.get('data', '') if it else '')
        ed_data.setMinimumHeight(70)
        dv.addWidget(ed_data)
        # HEX / 自动加\r\n / 参与发送勾选
        hflags = QHBoxLayout()
        cb_hex = QCheckBox('HEX 模式')
        cb_hex.setChecked(bool(it.get('hex')) if it else False)
        cb_crlf = QCheckBox('自动加 \\r\\n')
        cb_crlf.setChecked(bool(it.get('crlf')) if it else (not bool(it.get('hex')) if it else True))
        cb_checked = QCheckBox('参与顺序/轮询发送')
        cb_checked.setChecked(it.get('checked', True) if it else True)
        hflags.addWidget(cb_hex)
        hflags.addWidget(cb_crlf)
        hflags.addWidget(cb_checked)
        hflags.addStretch(1)
        dv.addLayout(hflags)
        # 延迟
        hd = QHBoxLayout()
        hd.addWidget(QLabel('本条发送后延迟(ms):'))
        sb_delay = QSpinBox()
        sb_delay.setRange(0, 60000)
        sb_delay.setSingleStep(50)
        sb_delay.setValue(int(it.get('delay', 0)) if it else 0)
        hd.addWidget(sb_delay)
        hd.addStretch(1)
        dv.addLayout(hd)
        # 按钮
        hb = QHBoxLayout()
        hb.addStretch(1)
        btn_ok = QPushButton('保存')
        btn_ok.setDefault(True)
        btn_cancel = QPushButton('取消')
        hb.addWidget(btn_ok)
        hb.addWidget(btn_cancel)
        dv.addLayout(hb)

        def do_save():
            name = ed_name.text().strip() or '未命名'
            data = ed_data.toPlainText()
            entry = {
                'name': name,
                'hex': cb_hex.isChecked(),
                'crlf': cb_crlf.isChecked(),
                'data': data,
                'delay': sb_delay.value(),
                'checked': cb_checked.isChecked(),
            }
            if self.qs_edit_index is not None and 0 <= self.qs_edit_index < len(self.quick_items):
                self.quick_items[self.qs_edit_index] = entry
            else:
                self.quick_items.append(entry)
            dlg.accept()
            self._qs_render()

        btn_ok.clicked.connect(do_save)
        btn_cancel.clicked.connect(dlg.reject)
        # 展开面板便于查看列表更新
        self.qs_collapsed = True
        self.qs_toggle_collapse()
        dlg.exec()

    def qs_set_all_checked(self, checked):
        for it in self.quick_items:
            it['checked'] = bool(checked)
        self._qs_render()

    def qs_reset_defaults(self):
        if not self.quick_items:
            self._qs_load_defaults()
            self._qs_render()
            return
        if QMessageBox.question(self, '快速发送', '确定用默认示例覆盖当前列表吗? 本地修改将丢失',
                                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No) == QMessageBox.StandardButton.No:
            return
        self.qs_stop_run()
        self._qs_load_defaults()
        self._qs_render()
        self.append_log('已重置为默认示例', False)

    def _qs_load_defaults(self):
        self.quick_items = [
            {'name': 'AT 测试', 'hex': False, 'crlf': True, 'data': 'AT', 'delay': 0, 'checked': True},
            {'name': '查询版本', 'hex': False, 'crlf': True, 'data': 'AT+VERSION?', 'delay': 0, 'checked': True},
            {'name': 'HEX 握手', 'hex': True, 'crlf': False, 'data': 'AA BB CC DD', 'delay': 0, 'checked': True},
        ]

    def qs_delete(self, i):
        if 0 <= i < len(self.quick_items):
            self.quick_items.pop(i)
            self._qs_render()

    def qs_clear_all(self):
        if not self.quick_items:
            return
        if QMessageBox.question(self, '快速发送', '确定清空所有快速发送条目吗?',
                                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No) == QMessageBox.StandardButton.Yes:
            self.quick_items.clear()
            self._qs_render()

    def qs_run_seq(self):
        self.qs_stop_run()
        self.qs_run_list = [it for i, it in enumerate(self.quick_items) if it.get('checked', True)]
        if not self.qs_run_list:
            self.append_log('没有勾选的条目, 无法顺序发送', True)
            return
        self.qs_run_mode = 'seq'
        self.qs_run_index = 0
        self.qs_step()

    def qs_run_poll(self):
        self.qs_stop_run()
        self.qs_run_list = [it for i, it in enumerate(self.quick_items) if it.get('checked', True)]
        if not self.qs_run_list:
            self.append_log('没有勾选的条目, 无法轮询发送', True)
            return
        self.qs_run_mode = 'poll'
        self.qs_run_index = 0
        self.qs_step()

    def qs_step(self):
        if self.qs_run_mode == 'stop':
            return
        if self.qs_run_index >= len(self.qs_run_list):
            if self.qs_run_mode == 'poll':
                self.qs_run_index = 0
            else:
                self.qs_stop_run()
                self.append_log('顺序发送完成', False)
                return
        it = self.qs_run_list[self.qs_run_index]
        buf = self._qs_item_to_buf(it)
        if buf is not None:
            self._send_buffer(buf)
        self.qs_run.setText(f"{'轮询' if self.qs_run_mode == 'poll' else '顺序'}发送中 ({self.qs_run_index + 1}/{len(self.qs_run_list)})")
        self.qs_run_index += 1
        gap = int(it.get('delay', 0) or 0)
        self.qs_timer.start(max(1, gap))

    def qs_timer_step(self):
        self.qs_timer.stop()
        self.qs_step()

    def qs_stop_run(self):
        if self.qs_timer.isActive():
            self.qs_timer.stop()
        self.qs_run_mode = 'stop'
        self.qs_run_index = 0
        self.qs_run_list = []
        self.qs_run.setText('空闲')
        self.qs_run.setStyleSheet('color:#9aa0a6')

    def qs_export(self):
        path, _ = QFileDialog.getSaveFileName(self, '导出快速发送', 'linkcom-quicksend.json', 'JSON (*.json)')
        if not path:
            return
        try:
            import json
            with open(path, 'w', encoding='utf-8') as f:
                json.dump({'version': 1, 'items': self.quick_items}, f, ensure_ascii=False, indent=2)
            self.append_log('已导出快速发送: ' + path, False)
        except Exception as e:
            self.append_log('导出失败: ' + str(e), True)

    def qs_import(self):
        path, _ = QFileDialog.getOpenFileName(self, '导入快速发送', '', 'JSON (*.json)')
        if not path:
            return
        try:
            import json
            with open(path, 'r', encoding='utf-8') as f:
                j = json.load(f)
            items = j.get('items') if isinstance(j, dict) else None
            if not isinstance(items, list) or not items:
                self.append_log('导入失败: 文件中没有条目', True)
                return
            self.quick_items = [{
                'name': it.get('name', '未命名'),
                'hex': bool(it.get('hex')),
                'crlf': bool(it.get('crlf')),
                'data': it.get('data', ''),
                'delay': int(it.get('delay', 0) or 0),
                'checked': it.get('checked', True) if isinstance(it.get('checked'), bool) else True,
            } for it in items]
            self._qs_render()
            self.append_log('已导入 ' + str(len(self.quick_items)) + ' 条', False)
        except Exception as e:
            self.append_log('导入失败: ' + str(e), True)

    # ---------------- 快速匹配 (对标 Web 端 sniffer.js) ----------------
    SN_MAX_ROWS = 50        # 每条规则最多展示的记录行数, 超出部分仍可查看帧/导出
    SN_FRAME_MAX_BYTES = 2048  # 查看帧单帧展示字节上限

    def _build_sniffer(self, root):
        box = QGroupBox('快速匹配')
        v = QVBoxLayout(box)
        v.setContentsMargins(10, 4, 10, 10)
        v.setSpacing(6)
        # 标题行 (可点击折叠) + 摘要
        title_row = QHBoxLayout()
        self.sn_toggle = QPushButton('展开')
        self.sn_toggle.setFixedWidth(56)
        self.sn_summary = QLabel('规则 0/0 · 记录 0')
        self.sn_summary.setStyleSheet('color:#9aa0a6')
        title_row.addWidget(self.sn_toggle)
        title_row.addWidget(self.sn_summary)
        title_row.addStretch(1)
        v.addLayout(title_row)

        self.sn_body = QWidget()
        body = QVBoxLayout(self.sn_body)
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(6)

        bar = QHBoxLayout()
        self.sn_add = QPushButton('添加')
        self.sn_clear = QPushButton('清空记录')
        self.sn_imp = QPushButton('导入规则')
        self.sn_exp = QPushButton('导出规则')
        for b in (self.sn_add, self.sn_clear, self.sn_imp, self.sn_exp):
            bar.addWidget(b)
        bar.addStretch(1)
        body.addLayout(bar)

        self.sn_list = QListWidget()
        self.sn_list.setStyleSheet(
            'QListWidget { background:#15151a; border:1px solid #353541; border-radius:8px; }'
            'QListWidget::item { padding:1px; }')
        self.sn_list.setMinimumHeight(140)
        body.addWidget(self.sn_list, 2)

        v.addWidget(self.sn_body)
        root.addWidget(box)

        # 信号
        self.sn_toggle.clicked.connect(self.sn_toggle_collapse)
        self.sn_add.clicked.connect(lambda: self.sn_open_editor(None))
        self.sn_clear.clicked.connect(self.sn_clear_records)
        self.sn_imp.clicked.connect(self.sn_import)
        self.sn_exp.clicked.connect(self.sn_export)
        # 数据可能高频到达, 变更后合并 300ms 再重绘
        self.sn_render_timer = QTimer(self)
        self.sn_render_timer.setSingleShot(True)
        self.sn_render_timer.setInterval(300)
        self.sn_render_timer.timeout.connect(self.sn_render)
        self._sn_folded = {}     # 规则 id -> 记录区是否折叠
        self.sn_collapsed = True
        self.sn_render()
        self.sn_toggle_collapse()  # 默认收起 (与 Web 端一致)

    def sn_toggle_collapse(self):
        self.sn_collapsed = not self.sn_collapsed
        self.sn_body.setVisible(not self.sn_collapsed)
        self.sn_toggle.setText('展开' if self.sn_collapsed else '收起')

    def _sn_schedule_render(self):
        if not self.sn_render_timer.isActive():
            self.sn_render_timer.start()

    def _report_serial_state(self):
        """通道打开/关闭状态实时同步给链接端 (serial-state), 使其未打开时无法发送"""
        if self.client is not None and self.client._joined:
            self.client.send_state(bool(self.channel and self.channel.is_open()))

    def sn_render(self):
        self.sn_list.clear()
        en = 0
        total = 0
        for r in self.sniffer.rules:
            recs = self.sniffer.records_for(r)
            total += len(recs)
            if r.get('enabled', True):
                en += 1
            self._sn_add_rule_row(r, recs)
        self.sn_summary.setText(f'规则 {en}/{len(self.sniffer.rules)} · 记录 {total}')

    def _sn_rule_meta(self, r):
        d = {'recv': '仅接收', 'send': '仅发送', 'both': '全部'}.get(r.get('dir'), '仅接收')
        lv = r.get('lenVal') or 0
        lf = f" 长{r.get('lenOp') or '='}{lv}" if lv else ''
        dm = 'HEX' if r.get('dispEnc') == 'hex' else '文本'
        if r.get('mode') == 'keyword':
            m = 'HEX' if (r.get('matchEnc') or 'hex') == 'hex' else '文本'
            return f"{d} | 匹配:{r.get('keyword') or '-'}{lf} | 匹:{m}→显:{dm}"
        return f"{d} | 偏移:{r.get('startOffset') or 0} 取{r.get('length') or 0}字节{lf} | 显:{dm}"

    def _sn_add_rule_row(self, r, recs):
        rid = r['id']
        item = QListWidgetItem(self.sn_list)
        w = QWidget()
        h = QHBoxLayout(w)
        h.setContentsMargins(4, 2, 4, 2)
        h.setSpacing(6)
        folded = bool(self._sn_folded.get(rid))
        b_fold = QPushButton('▸' if folded else '▾')
        b_fold.setFixedSize(22, 22)
        b_fold.setStyleSheet('QPushButton { padding:0; }')
        b_fold.clicked.connect(lambda _, i=rid: self._sn_toggle_fold(i))
        en = QCheckBox()
        en.setChecked(bool(r.get('enabled', True)))
        en.setStyleSheet(_CHECK_STYLE)
        en.stateChanged.connect(lambda _, i=rid, c=en: self._sn_set_enabled(i, c.isChecked()))
        badge = QLabel('匹配关键字' if r.get('mode') == 'keyword' else '提取')
        badge.setStyleSheet('color:#3ddc84' if r.get('enabled', True) else 'color:#5a5a64')
        name = QLabel(r.get('name') or '未命名规则')
        name.setStyleSheet('color:#e6e6e6; font-weight:600')
        name.setMinimumWidth(72)
        meta = QLabel(self._sn_rule_meta(r))
        meta.setStyleSheet('color:#9aa0a6')
        dedup_t = r.get('dedupType') or 'match'
        cnt_text = str(len(recs))
        if dedup_t == 'match':
            cnt_text += ' (匹配去重)'
        elif dedup_t == 'all':
            cnt_text += ' (全匹配去重)'
        cnt = QLabel(cnt_text)
        cnt.setStyleSheet('color:#ffd666')
        b_exp = QPushButton('导出'); b_exp.setFixedHeight(28)
        b_clr = QPushButton('清空'); b_clr.setFixedHeight(28)
        b_edit = QPushButton('编辑'); b_edit.setFixedHeight(28)
        b_del = QPushButton('删除'); b_del.setFixedHeight(28)
        for b in (b_exp, b_clr, b_edit, b_del):
            b.setMinimumWidth(46)
        b_exp.clicked.connect(lambda _, i=rid: self.sn_export_rule_records(i))
        b_clr.clicked.connect(lambda _, i=rid: self.sn_clear_rule_records(i))
        b_edit.clicked.connect(lambda _, i=rid: self.sn_open_editor(i))
        b_del.clicked.connect(lambda _, i=rid: self.sn_delete_rule(i))
        h.addWidget(b_fold)
        h.addWidget(en)
        h.addWidget(badge)
        h.addWidget(name)
        h.addWidget(meta, 1)
        h.addWidget(cnt)
        h.addWidget(b_exp)
        h.addWidget(b_clr)
        h.addWidget(b_edit)
        h.addWidget(b_del)
        w.setMinimumHeight(34)
        item.setSizeHint(QSize(w.sizeHint().width(), 34))
        self.sn_list.setItemWidget(item, w)
        if not folded:
            shown = self.sniffer.sort_records(recs, r)[:self.SN_MAX_ROWS]
            for rec in shown:
                self._sn_add_record_row(r, rec)
            if len(recs) > len(shown):
                self._sn_add_note_row(f'…… 其余 {len(recs) - len(shown)} 条 (查看帧/导出取完整数据)')

    def _sn_add_record_row(self, rule, rec):
        item = QListWidgetItem(self.sn_list)
        w = QWidget()
        h = QHBoxLayout(w)
        h.setContentsMargins(30, 1, 4, 1)
        h.setSpacing(6)
        ts = QLabel(rec.get('lastTs') or rec.get('ts') or '')
        ts.setStyleSheet('color:#6b7280')
        val = QLabel(self._sn_rec_value_text(rule, rec))
        val.setStyleSheet('color:#d4d4d4')
        b_view = QPushButton('查看帧')
        b_view.setFixedHeight(28)
        b_view.clicked.connect(lambda _, ru=rule, rc=rec: self.sn_view_frames(ru, rc))
        h.addWidget(ts)
        h.addWidget(val, 1)
        if rec.get('count', 1) > 1:
            c = QLabel(f"×{rec['count']}")
            c.setStyleSheet('color:#ffd666')
            h.addWidget(c)
        h.addWidget(b_view)
        w.setMinimumHeight(34)
        item.setSizeHint(QSize(w.sizeHint().width(), 34))
        self.sn_list.setItemWidget(item, w)

    def _sn_add_note_row(self, text):
        item = QListWidgetItem(self.sn_list)
        lb = QLabel(text)
        lb.setStyleSheet('color:#5a5a64; padding-left:30px')
        item.setSizeHint(QSize(200, 20))
        self.sn_list.setItemWidget(item, lb)

    def _sn_rec_value_text(self, rule, rec):
        b = hex_to_bytes(rec.get('rawHex') or '')
        if not b:
            return ''
        full = (rule.get('dedupType') or 'match') != 'match'
        disp = rule.get('dispEnc') or 'text'
        if not full:
            hl = rec.get('hl')
            if not hl:
                return ''
            seg = b[hl[0]:hl[1]]
            return self.sniffer.display_bytes(seg, disp)
        # 整帧展示: 截断到 48 字节 (与 Web 端一致)
        out = self.sniffer.display_bytes(b[:48], disp)
        return out + ('…' if len(b) > 48 else '')

    def _sn_toggle_fold(self, rid):
        self._sn_folded[rid] = not self._sn_folded.get(rid, False)
        self.sn_render()

    def _sn_set_enabled(self, rid, val):
        r = self.sniffer.find_rule(rid)
        if r is not None:
            r['enabled'] = bool(val)
            self.sn_render()

    def sn_clear_records(self):
        if not self.sniffer.records:
            return
        if QMessageBox.question(
                self, '快速匹配', '清空全部规则的记录? (规则保留)',
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
                ) == QMessageBox.StandardButton.Yes:
            self.sniffer.clear_records()
            self.sn_render()

    def sn_clear_rule_records(self, rid):
        r = self.sniffer.find_rule(rid)
        if r is None:
            return
        if QMessageBox.question(
                self, '快速匹配', f"清空规则「{r.get('name') or '未命名'}」的记录?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
                ) == QMessageBox.StandardButton.Yes:
            self.sniffer.clear_records(rid)
            self.sn_render()

    def sn_delete_rule(self, rid):
        r = self.sniffer.find_rule(rid)
        if r is None:
            return
        if QMessageBox.question(
                self, '快速匹配', f"删除规则「{r.get('name') or '未命名'}」? (其记录一并删除)",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
                ) == QMessageBox.StandardButton.Yes:
            self.sniffer.remove_rule(rid)
            self._sn_folded.pop(rid, None)
            self.sn_render()

    # ---------- 查看帧 ----------
    def _sn_frame_html(self, rule, rec):
        """原始帧 HTML: 命中段绿色高亮 (与 Web 端查看帧一致, 不可打印字符以 · 表示)"""
        disp = rule.get('dispEnc') or 'text'
        b = hex_to_bytes(rec.get('rawHex') or '') or b''
        hl = rec.get('hl')
        s0, s1 = (hl[0], hl[1]) if hl else (-1, -1)
        n = min(len(b), self.SN_FRAME_MAX_BYTES)
        parts = []
        if disp == 'hex':
            for i in range(n):
                t = f'{b[i]:02X}'
                parts.append(f'<span style="color:#3ddc84; font-weight:600;">{t}</span>' if s0 <= i < s1 else t)
            out = ' '.join(parts)
        else:
            for i in range(n):
                x = b[i]
                ch = chr(x) if 0x20 <= x < 0x7f else '·'
                ch = ch.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
                parts.append(f'<span style="color:#3ddc84; font-weight:600;">{ch}</span>' if s0 <= i < s1 else ch)
            out = ''.join(parts)
        if len(b) > n:
            out += ' …'
        return out

    def sn_view_frames(self, rule, rec):
        refs = rec.get('_refs') or [rec]
        disp = rule.get('dispEnc') or 'text'
        enc_label = 'HEX' if disp == 'hex' else '文本'
        dlg = QDialog(self)
        dlg.setWindowTitle(f"帧记录 (共 {len(refs)} 次) · 编码: {enc_label}")
        dlg.setMinimumSize(560, 420)
        v = QVBoxLayout(dlg)
        te = QTextEdit()
        te.setReadOnly(True)
        te.setStyleSheet(_TERM_STYLE)
        f = te.font()
        f.setFamily('Consolas')
        te.setFont(f)
        html = []
        for i, fr in enumerate(refs):
            ts = fr.get('ts') or fr.get('lastTs') or ''
            html.append(
                f'<div style="margin-bottom:6px;">'
                f'<span style="color:#6b7280;">[{ts}]</span> '
                f'<span style="color:#9aa0a6;">#{i + 1}</span> '
                f'{self._sn_frame_html(rule, fr)}</div>')
        te.setHtml(''.join(html) or '<span style="color:#9aa0a6;">无数据</span>')
        v.addWidget(te)
        hb = QHBoxLayout()
        hb.addStretch(1)
        b_close = QPushButton('关闭')
        b_close.clicked.connect(dlg.accept)
        hb.addWidget(b_close)
        v.addLayout(hb)
        dlg.exec()

    # ---------- 规则编辑器 ----------
    def sn_open_editor(self, rule_id=None):
        """整块表单对话框 (新增/编辑规则), 字段与 Web 端 sniffer.js 一致"""
        cur = self.sniffer.find_rule(rule_id) if rule_id else None
        dlg = QDialog(self)
        dlg.setWindowTitle('快速匹配 - ' + ('编辑规则' if cur else '添加规则'))
        dlg.setMinimumWidth(480)
        v = QVBoxLayout(dlg)
        form = QFormLayout()
        ed_name = QLineEdit((cur or {}).get('name', ''))
        form.addRow('名称', ed_name)
        cb_mode = QComboBox()
        cb_mode.addItems(['提取 (起点偏移 + 长度)', '匹配关键字 (命中即记录)'])
        cb_mode.setCurrentIndex(1 if (cur or {}).get('mode') == 'keyword' else 0)
        form.addRow('匹配模式', cb_mode)
        cb_dir = QComboBox()
        cb_dir.addItems(['仅接收', '仅发送', '全部'])
        cb_dir.setCurrentIndex({'recv': 0, 'send': 1, 'both': 2}.get((cur or {}).get('dir'), 0))
        form.addRow('方向', cb_dir)
        cb_denc = QComboBox()
        cb_denc.addItems(['HEX', '文本 (采用"显示数据"编码)'])
        cb_denc.setCurrentIndex(0 if (cur or {}).get('dispEnc') == 'hex' else 1)
        form.addRow('显示编码', cb_denc)
        cb_menc = QComboBox()
        cb_menc.addItems(['HEX (按十六进制匹配)', '文本 (按"显示数据"处编码匹配)'])
        cb_menc.setCurrentIndex(0 if (cur or {}).get('matchEnc', 'hex') == 'hex' else 1)
        form.addRow('匹配编码', cb_menc)
        ed_kw = QLineEdit((cur or {}).get('keyword', ''))
        ed_kw.setPlaceholderText('如 9B 01 或 HELLO')
        form.addRow('匹配关键字', ed_kw)
        sb_off = QSpinBox()
        sb_off.setRange(0, 65535)
        sb_off.setValue(int((cur or {}).get('startOffset') or 0))
        form.addRow('起点偏移 (字节, 从数据流开头计)', sb_off)
        sb_len = QSpinBox()
        sb_len.setRange(1, 4096)
        sb_len.setValue(int((cur or {}).get('length') or 1))
        form.addRow('提取长度 (字节)', sb_len)
        # 数据长度过滤
        h_len = QHBoxLayout()
        cb_lenop = QComboBox()
        cb_lenop.addItems(['>', '>=', '<', '<=', '='])
        cb_lenop.setCurrentText((cur or {}).get('lenOp') or '=')
        sb_lenval = QSpinBox()
        sb_lenval.setRange(0, 65535)
        sb_lenval.setValue(int((cur or {}).get('lenVal') or 0))
        sb_lenval.setSpecialValueText('不限')
        h_len.addWidget(cb_lenop)
        h_len.addWidget(sb_lenval)
        h_len.addStretch(1)
        w_len = QWidget()
        w_len.setLayout(h_len)
        form.addRow('数据长度过滤', w_len)
        cb_dedup = QComboBox()
        cb_dedup.addItems(['不去重', '匹配去重', '全匹配去重'])
        cb_dedup.setCurrentIndex({'none': 0, 'match': 1, 'all': 2}.get((cur or {}).get('dedupType'), 1))
        form.addRow('去重方式', cb_dedup)
        cb_sort = QComboBox()
        cb_sort.addItems(['按时间', '按值', '按次数'])
        cb_sort.setCurrentIndex({'time': 0, 'value': 1, 'count': 2}.get((cur or {}).get('sortKey'), 0))
        form.addRow('排序', cb_sort)
        v.addLayout(form)
        cb_acc = QCheckBox('跨帧累积 (流被拆开时勾选, 偏移更准)')
        cb_acc.setChecked(bool((cur or {}).get('accumulate', True)))
        cb_acc.setStyleSheet(_CHECK_STYLE)
        v.addWidget(cb_acc)
        cb_en = QCheckBox('启用')
        cb_en.setChecked(bool((cur or {}).get('enabled', True)))
        cb_en.setStyleSheet(_CHECK_STYLE)
        v.addWidget(cb_en)
        hb = QHBoxLayout()
        hb.addStretch(1)
        b_ok = QPushButton('保存')
        b_ok.setDefault(True)
        b_cancel = QPushButton('取消')
        hb.addWidget(b_ok)
        hb.addWidget(b_cancel)
        v.addLayout(hb)

        def sync_mode():
            kw = cb_mode.currentIndex() == 1
            for w in (ed_kw, cb_menc):
                w.setVisible(kw)
                form.labelForField(w).setVisible(kw)
            for w in (sb_off, sb_len):
                w.setVisible(not kw)
                form.labelForField(w).setVisible(not kw)
        cb_mode.currentIndexChanged.connect(lambda _: sync_mode())
        sync_mode()

        def do_save():
            mode = 'keyword' if cb_mode.currentIndex() == 1 else 'extract'
            name = ed_name.text().strip() or '未命名规则'
            keyword = ed_kw.text().strip()
            if mode == 'keyword':
                if not keyword:
                    QMessageBox.warning(dlg, '提示', '请填写匹配关键字')
                    return
                if cb_menc.currentIndex() == 0 and hex_to_bytes(keyword) is None:
                    QMessageBox.warning(dlg, '提示', '匹配关键字 HEX 格式错误 (需偶数位, 空格分隔)')
                    return
            else:
                if sb_len.value() < 1:
                    QMessageBox.warning(dlg, '提示', '提取模式请填写提取长度 (至少 1 字节)')
                    return
            data = {
                'id': (cur or {}).get('id') or new_rule_id(),
                'name': name,
                'dir': ['recv', 'send', 'both'][cb_dir.currentIndex()],
                'mode': mode,
                'keyword': keyword,
                'startOffset': sb_off.value(),
                'length': sb_len.value(),
                'matchEnc': 'hex' if cb_menc.currentIndex() == 0 else 'text',
                'dispEnc': 'hex' if cb_denc.currentIndex() == 0 else 'text',
                'lenOp': cb_lenop.currentText(),
                'lenVal': sb_lenval.value(),
                'accumulate': cb_acc.isChecked(),
                'enabled': cb_en.isChecked(),
                'dedupType': ['none', 'match', 'all'][cb_dedup.currentIndex()],
                'sortKey': ['time', 'value', 'count'][cb_sort.currentIndex()],
                'sortDir': -1,
            }
            self.sniffer.upsert_rule(data)
            self.sn_render()
            dlg.accept()
        b_ok.clicked.connect(do_save)
        b_cancel.clicked.connect(dlg.reject)
        dlg.exec()

    # ---------- 导入/导出 ----------
    def sn_export(self):
        path, _ = QFileDialog.getSaveFileName(self, '导出快速匹配规则', 'linkcom_sniffer_rules.json', 'JSON (*.json)')
        if not path:
            return
        try:
            with open(path, 'w', encoding='utf-8') as f:
                json.dump({'rules': self.sniffer.rules}, f, ensure_ascii=False, indent=2)
            self.append_log('已导出快速匹配规则: ' + path, False)
        except Exception as e:
            self.append_log('导出失败: ' + str(e), True)

    def sn_import(self):
        path, _ = QFileDialog.getOpenFileName(self, '导入快速匹配规则', '', 'JSON (*.json)')
        if not path:
            return
        try:
            with open(path, 'r', encoding='utf-8') as f:
                text = f.read()
        except Exception as e:
            self.append_log('导入失败: ' + str(e), True)
            return
        ok, msg = self.sniffer.import_rules(text)
        self.append_log(msg, not ok)
        if ok:
            self.sn_render()

    def sn_export_rule_records(self, rid):
        r = self.sniffer.find_rule(rid)
        if r is None:
            return
        safe = ''.join(ch for ch in (r.get('name') or rid) if ch not in '\\/:*?"<>|') or rid
        path, _ = QFileDialog.getSaveFileName(self, '导出匹配记录', f'linkcom_sniffer_{safe}.json', 'JSON (*.json)')
        if not path:
            return
        try:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(self.sniffer.export_rule_records(r))
            self.append_log('已导出匹配记录: ' + path, False)
        except Exception as e:
            self.append_log('导出失败: ' + str(e), True)

    def toggle_pause(self):
        self.paused = not self.paused
        self.btn_pause.setText('继续' if self.paused else '暂停')
        if not self.paused:
            self.rerender()

    def clear_log(self):
        self.history.clear()
        self.term.clear()

    def export_history(self):
        if not self.history:
            QMessageBox.information(self, '提示', '暂无历史记录')
            return
        path, _ = QFileDialog.getSaveFileName(self, '导出历史', 'linkcom-history.txt', 'Text (*.txt)')
        if not path:
            return
        lines = []
        for ts, cls, buf in self.history:
            if self.mode_text and self.mode_hex:
                lines.append(f'[{ts}] {self.dir_label(cls)} 文本: {text_of(buf, self.encoding)}')
                lines.append(f'[{ts}] {self.dir_label(cls)} HEX: {hex_lines(buf).replace(chr(10), " ")}')
            elif self.mode_hex:
                lines.append(f'[{ts}] {self.dir_label(cls)} HEX: {hex_lines(buf).replace(chr(10), " ")}')
            else:
                lines.append(f'[{ts}] {self.dir_label(cls)} 文本: {text_of(buf, self.encoding)}')
        try:
            with open(path, 'w', encoding='utf-8') as f:
                f.write('\n'.join(lines) + '\n')
            self.append_log('已导出历史: ' + path, False)
        except Exception as e:
            self.append_log('导出失败: ' + str(e), True)

    def dir_label(self, cls):
        if cls == 'tx': return '[→发送]'
        if cls == 'ltx': return '[Link_发送]'
        return '[←接收]'

    # ---------------- WebSocket 信号 ----------------
    @Slot(bool)
    def on_ws_open(self, opened):
        if opened:
            self.ws_dot.setStyleSheet('color:orange')
            self.ws_stat.setText('已连服务器, 共享中')
        else:
            self.ws_dot.setStyleSheet('color:gray')
            self.ws_stat.setText('服务器断开, 重连中…')

    @Slot(str)
    def on_server_error(self, m):
        """服务器返回错误(如房间码已被占用/密码错误): 弹窗提示并写日志"""
        self.append_log('错误: ' + m, True)
        if m:
            QMessageBox.warning(self, '提示', m)

    @Slot(str, object)
    def on_joined(self, room, peers):
        self.ws_dot.setStyleSheet('color:green')
        self.ws_stat.setText('共享中')
        self.lb_room.setText(room)
        self.lb_peers.setText(str(peers.get('links', 0)))
        self.append_log('已进入共享房间 ' + room, False)
        # 加入后立即下发完整配置 (通道类型 + 串口参数 + 聚合参数), 让链接端立刻看到
        self.send_config()
        # 服务器在共享端接管时会复位串口状态, 这里补发一次当前通道状态
        self._report_serial_state()
        # 共享中显示可点击的共享链接
        self._build_share_links()
        self.link_label.setVisible(True)

    @Slot(bool, int)
    def on_peers(self, share, links):
        self.lb_peers.setText(str(links))

    def send_config(self):
        """把当前通道类型 + 串口参数 + 聚合参数 下发给链接端"""
        if not self.client:
            return
        c = self._collect_cfg()
        mode = c['mode']
        if mode == 'serial':
            s = c['serial']
            cfg = {
                'baudRate': s['baudRate'], 'dataBits': s['dataBits'],
                'stopBits': s['stopBits'], 'parity': s['parity'],
                'flowControl': s['flowControl'], 'encoding': s['encoding'],
            }
        else:
            cfg = {}  # TCP 模式不携带 COM 参数
        agg = {'flushMs': self.sb_flush.value(), 'maxBufKb': self.sb_buf.value()}
        self.client.send_config(cfg, mode, agg, port_open=bool(self.channel and self.channel.is_open()))

    @Slot(object, str, object)
    def on_remote_cfg(self, cfg, mode, agg):
        """链接端请求修改参数: 实时同步聚合参数, 串口模式下重设串口"""
        log = []
        # 1) 聚合参数实时生效 (所有模式)
        if agg:
            try:
                if 'flushMs' in agg:
                    self.sb_flush.setValue(int(agg['flushMs']))
                if 'maxBufKb' in agg:
                    self.sb_buf.setValue(int(agg['maxBufKb']))
                self.flush_ms = self.sb_flush.value()
                self.max_buf_kb = self.sb_buf.value()
                log.append(f"聚合={self.flush_ms}ms/{self.max_buf_kb}KB")
            except Exception as e:
                self.append_log('应用聚合参数失败: ' + str(e), True)
        # 2) 串口参数: 仅 serial 模式应用 (TCP 模式忽略 COM 参数)
        is_serial = (mode == 'serial') or (mode is None and self.tabs.currentIndex() == 0)
        if cfg and is_serial:
            try:
                if cfg.get('baudRate') is not None:
                    self.cb_baud.setCurrentText(str(cfg['baudRate']))
                if cfg.get('dataBits') is not None:
                    self.cb_dbits.setCurrentText(str(cfg['dataBits']))
                if cfg.get('stopBits') is not None:
                    self.cb_sbits.setCurrentText(str(cfg['stopBits']))
                if cfg.get('parity'):
                    self.cb_parity.setCurrentText(str(cfg['parity']))
                if cfg.get('flowControl'):
                    self.cb_flow.setCurrentText(str(cfg['flowControl']))
                if cfg.get('encoding'):
                    self.encoding = cfg['encoding']
                    self.cb_enc.setCurrentText(cfg['encoding'])
                log.append(f"串口={cfg.get('baudRate')}/{cfg.get('dataBits')}/{cfg.get('stopBits')}/{cfg.get('parity')}/{cfg.get('flowControl')}/{str(cfg.get('encoding')).upper()}")
            except Exception as e:
                self.append_log('应用串口参数失败: ' + str(e), True)
        elif cfg and not is_serial:
            # TCP 模式: 链接端下发的 COM 参数忽略, 仅保留聚合同步
            pass
        # 3) 若串口已打开, 按新参数重开 (实时生效)
        if cfg and is_serial and self.channel and self.channel.is_open():
            self.append_log('链接端修改参数, 正在按新配置重连串口…', False)
            self.close_channel()
            self.open_channel()
            if self.channel and self.channel.is_open():
                self.send_config()  # 重连成功后回执新配置, 保持链接端一致
        # 日志
        if log:
            self.append_log('链接端请求修改参数: ' + ' | '.join(log), False)

    # ---------------- 共享链接 ----------------
    def _build_share_links(self):
        """根据当前 server/房间码/密码生成网页链接与 linkcom:// 唤起链接"""
        room = self.ed_room.text().strip()
        pwd = self.ed_pwd.text().strip()
        server = self.ed_server.text().strip()
        # ws://host:port/path  ->  http(s)://host:port/path
        web = server
        if web.startswith('wss://'):
            web = 'https://' + web[len('wss://'):]
        elif web.startswith('ws://'):
            web = 'http://' + web[len('ws://'):]
        q = f'mode=link&room={room}'
        if pwd:
            q += f'&pwd={pwd}'
        web_url = web + ('&' if ('?' in web) else '?') + q
        # linkcom:// 一键唤起本机客户端 (含密码自动填入)
        linkcom_url = f'linkcom://?room={room}&pwd={pwd}&server={server}&mode=link'
        self._web_url = web_url
        self._linkcom_url = linkcom_url

    def on_share_link_click(self, _=None):
        # 用默认浏览器打开网页链接 (对方手机/浏览器用), 不再自动唤起 linkcom:// 避免系统弹窗
        import webbrowser
        if getattr(self, '_web_url', None):
            QApplication.clipboard().setText(self._web_url)
            webbrowser.open(self._web_url)
            self.append_log('已在浏览器打开共享链接, 并复制到剪贴板: ' + self._web_url, False)
        # 若本机已注册 linkcom:// 协议, 可手动复制到终端/运行框用桌面端一键进房
        if getattr(self, '_linkcom_url', None):
            self.append_log('本机客户端链接(可选手动使用): ' + self._linkcom_url, False)

    # ---------------- 工具 ----------------
    def append_log(self, text, is_err=False):
        ts = self.now_ts()
        color = '#ff6b6b' if is_err else '#9aa0a6'
        ts_html = f'<span style="color:#6b7280">[{ts}]</span> ' if self.show_ts else ''
        safe = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        self.term.append(f'{ts_html}<span style="color:{color};font-weight:600">[系统]</span> <span style="color:{color}">{safe}</span>')
        if self.auto_scroll:
            self.term.moveCursor(QTextCursor.End)
        self.status.showMessage(text if not is_err else '错误: ' + text)

    def refresh_com(self):
        try:
            import serial.tools.list_ports
            ports = [p.device for p in serial.tools.list_ports.comports()]
        except Exception:
            ports = []
        cur = self.cb_com.currentText()
        self.cb_com.clear()
        if ports:
            self.cb_com.addItems(ports)
        else:
            # 无已连接 COM: 显示提示且不可作为有效选择
            self.cb_com.addItems(['当前无可用 COM 设备'])
        if cur and cur in [self.cb_com.itemText(i) for i in range(self.cb_com.count())]:
            self.cb_com.setCurrentText(cur)

    @staticmethod
    def _gen_room():
        import random
        import string
        return ''.join(random.choices(string.ascii_uppercase + string.digits, k=6))

    @staticmethod
    def now_ts():
        t = time.localtime()
        return time.strftime('%H:%M:%S.', t) + f'{int(time.time()*1000)%1000:03d}'

    @staticmethod
    def fmt(n):
        if n < 1024: return f'{n} B'
        if n < 1024*1024: return f'{n/1024:.1f} KB'
        return f'{n/1024/1024:.2f} MB'

    def closeEvent(self, event):
        self._collect_cfg()
        save_config(self.cfg)
        self.close_channel()
        self.disconnect_server()
        event.accept()
