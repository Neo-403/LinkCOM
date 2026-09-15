"""LinkCOM 桌面端 - 配置读写 (linkcom.zwzw)

配置文件查找优先级:
  1. 程序同目录下的 linkcom.zwzw (便携模式: 打包 exe 为 exe 所在目录, 开发态为源码目录)
  2. 用户目录下 LinkCOM/linkcom.zwzw (同目录没有时使用, 目录与文件在保存时自动创建)

同目录无配置时落到用户目录, 兼顾便携使用与程序被放在只读位置 (如 Program Files) 时仍可保存参数。
"""
import json
import os
import sys


def _config_dir():
    # 打包(exe)时为 exe 所在目录; 开发时为源码目录
    if getattr(sys, 'frozen', False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


LOCAL_CONFIG_PATH = os.path.join(_config_dir(), 'linkcom.zwzw')
USER_CONFIG_PATH = os.path.join(os.path.expanduser('~'), 'LinkCOM', 'linkcom.zwzw')


def get_config_path():
    """实际使用的配置路径: 同目录存在 linkcom.zwzw 则优先, 否则用用户目录下的 LinkCOM/linkcom.zwzw"""
    if os.path.exists(LOCAL_CONFIG_PATH):
        return LOCAL_CONFIG_PATH
    return USER_CONFIG_PATH


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
        "sniffer": {
            "rules": [],
            "records": [],
        },
    }


def load_config(path=None):
    path = path or get_config_path()
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


def save_config(cfg, path=None):
    path = path or get_config_path()
    # 目录只读等异常时静默失败, 不阻塞程序; 用户目录 LinkCOM/ 不存在时自动创建
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
    except Exception:
        pass
