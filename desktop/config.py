"""LinkCOM 桌面端 - 配置读写 (config.json)"""
import json
import os

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'config.json')


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
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
