#!/usr/bin/env python3
"""
同步版本号：以根目录 VERSION 为唯一来源，生成 public/version.js 供 Web 端使用。
桌面端在运行时直接读取 VERSION，无需此脚本。

用法：
  python sync_version.py        # 生成 public/version.js
也可在 npm 中调用： "sync-version": "python sync_version.py"
"""
import os
import re

ROOT = os.path.dirname(os.path.abspath(__file__))
VERSION_FILE = os.path.join(ROOT, 'VERSION')
OUT_FILE = os.path.join(ROOT, 'public', 'version.js')


def read_version():
    with open(VERSION_FILE, 'r', encoding='utf-8') as f:
        v = f.read().strip()
    if not re.match(r'^\d+\.\d+\.\d+$', v):
        raise SystemExit(f'VERSION 格式应为 x.y.z，当前为: {v!r}')
    return v


def main():
    v = read_version()
    js = (
        '// 此文件由 sync_version.py 自动生成，请勿手动修改\n'
        f'window.APP_VERSION = {v!r};\n'
    )
    os.makedirs(os.path.dirname(OUT_FILE), exist_ok=True)
    with open(OUT_FILE, 'w', encoding='utf-8') as f:
        f.write(js)
    print(f'已生成 {os.path.relpath(OUT_FILE, ROOT)} (APP_VERSION = {v})')


if __name__ == '__main__':
    main()
