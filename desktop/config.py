"""LinkCOM 桌面端 - 配置读写 (linkcom.zwzw, 存于 exe/源码同目录)

打包为 exe 后 __file__ 指向只读的临时目录(_MEIPASS), 不能再写 config.json,
因此配置统一存到程序所在目录下的 linkcom.zwzw, 保证每次打开参数不丢失。
"""
import json
import os
import sys


def _config_dir():
    # 打包(exe)时存到 exe 所在目录; 开发时存到源码目录
    if getattr(sys, 'frozen', False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


CONFIG_PATH = os.path.join(_config_dir(), 'linkcom.zwzw')


def default_config():
    return {
        "server": "ws://127.0.0.1:8080",
        "basePath": "",
        "room": "",
        "pwd": "",
        "mode": "serial",
        "serial": {
            "port": "",
            "baudRate": 9600,
            "dataBits": 8,
            "stopBits": 1,
            "parity": "none",
            "flowControl": "none",
            "encoding": "gbk",
        },
        "tcpClient": {
            "localIp": "",
            "localPort": "",
            "remoteHost": "",
            "remotePort": "",
        },
        "tcpServer": {
            "localIp": "",
            "localPort": "",
        },
        "display": {
            "modeText": True,
            "modeHex": False,
            "encoding": "gbk",
            "autoScroll": True,
            "paused": False,
        },
    }


def load_config(path=CONFIG_PATH):
    cfg = default_config()
    if os.path.exists(path):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            # 深合并简单层
            for k, v in data.items():
                if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                    cfg[k].update(v)
                else:
                    cfg[k] = v
        except Exception:
            pass
    return cfg


def save_config(cfg, path=CONFIG_PATH):
    # 目录只读等异常时静默失败, 不阻塞程序
    try:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
    except Exception:
        pass
