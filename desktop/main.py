"""LinkCOM 桌面端 - 入口

用法:
  python main.py                     正常启动
  python main.py "linkcom://?room=R1&pwd=&server=ws://127.0.0.1:8080&mode=tcpClient"
                                      通过 URL Scheme 预填配置

URL Scheme 注册 (Windows, 管理员运行一次):
  python main.py --register   写入注册表 HKEY_CURRENT_USER\\Software\\Classes\\linkcom
"""
import os
import sys

from PySide6.QtWidgets import QApplication, QMessageBox

from config import load_config
from main_window import MainWindow
from url_scheme import parse_linkcom_uri


def register_url_scheme():
    """在 Windows 注册表注册 linkcom:// 协议, 调用本 exe/脚本"""
    try:
        import winreg
    except ImportError:
        print('仅 Windows 支持注册 URL Scheme')
        return False
    exe = os.path.abspath(sys.argv[0])
    # 若是打包后的 exe 直接用; 否则用 python 脚本路径
    if exe.lower().endswith('.exe'):
        command = f'"{exe}" "%1"'
    else:
        command = f'"{sys.executable}" "{exe}" "%1"'
    try:
        key = winreg.CreateKey(winreg.HKEY_CURRENT_USER, r'Software\Classes\linkcom')
        winreg.SetValue(key, '', winreg.REG_SZ, 'URL:LinkCOM Protocol')
        winreg.SetValueEx(key, 'URL Protocol', 0, winreg.REG_SZ, '')
        cmd_key = winreg.CreateKey(key, r'shell\open\command')
        winreg.SetValue(cmd_key, '', winreg.REG_SZ, command)
        winreg.CloseKey(cmd_key)
        winreg.CloseKey(key)
        print('已注册 linkcom:// 协议 -> ' + command)
        return True
    except Exception as e:
        print('注册失败(需管理员权限): ' + str(e))
        return False


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--register':
        ok = register_url_scheme()
        input('按回车退出...' if not ok else '注册成功, 按回车退出...')
        return

    cfg = load_config()
    startup = {}
    # 若第一个参数为 linkcom://... 则解析
    if len(sys.argv) > 1 and sys.argv[1].lower().startswith('linkcom://'):
        startup = parse_linkcom_uri(sys.argv[1])

    app = QApplication(sys.argv)
    win = MainWindow(cfg, startup)
    win.show()
    sys.exit(app.exec())


if __name__ == '__main__':
    main()
