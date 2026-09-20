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
FLUTTER_OUT_FILE = os.path.join(ROOT, 'linkcom_flutter', 'lib', 'version.dart')
PKG_FILE = os.path.join(ROOT, 'package.json')
FLUTTER_PUBSPEC = os.path.join(ROOT, 'linkcom_flutter', 'pubspec.yaml')


def sync_package_json(v):
    """同步 package.json 的 version 字段, 使其也由 VERSION 控制。"""
    import json
    if not os.path.exists(PKG_FILE):
        return
    with open(PKG_FILE, 'r', encoding='utf-8') as f:
        pkg = json.load(f)
    if pkg.get('version') != v:
        pkg['version'] = v
        with open(PKG_FILE, 'w', encoding='utf-8') as f:
            json.dump(pkg, f, ensure_ascii=False, indent=2)
            f.write('\n')
        print(f'Updated {os.path.relpath(PKG_FILE, ROOT)} version -> {v}')


def sync_pubspec(v):
    """同步 linkcom_flutter/pubspec.yaml 的 version = x.y.z+build (保留既有构建号)。

    Flutter 端 Android 的 versionName/versionCode 与 Windows 产物命名都取自这里,
    必须与根 VERSION 保持一致, 否则 Release 里会出现两个不同的版本号。
    """
    if not os.path.exists(FLUTTER_PUBSPEC):
        return
    with open(FLUTTER_PUBSPEC, 'r', encoding='utf-8') as f:
        text = f.read()
    m = re.search(r'^version:\s*\d+\.\d+\.\d+(?:\+(\d+))?\s*$', text, re.M)
    if not m:
        return
    build = m.group(1) or '1'
    new_line = f'version: {v}+{build}'
    if m.group(0) == new_line:
        return
    text = text[:m.start()] + new_line + text[m.end():]
    with open(FLUTTER_PUBSPEC, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print(f'Updated {os.path.relpath(FLUTTER_PUBSPEC, ROOT)} version -> {v}+{build}')


def read_version():
    with open(VERSION_FILE, 'r', encoding='utf-8') as f:
        v = f.read().strip()
    if not re.match(r'^\d+\.\d+\.\d+$', v):
        raise SystemExit(f'VERSION 格式应为 x.y.z，当前为: {v!r}')
    return v


def gen_flutter(v):
    """生成 Flutter 端 lib/version.dart (linkcom_flutter 工程)。"""
    dart = (
        '// 由 sync_version.py 依据根目录 VERSION 自动生成, 勿手动修改\n'
        f"const String appVersion = {v!r};\n"
    )
    os.makedirs(os.path.dirname(FLUTTER_OUT_FILE), exist_ok=True)
    with open(FLUTTER_OUT_FILE, 'w', encoding='utf-8') as f:
        f.write(dart)
    print(f'Generated {os.path.relpath(FLUTTER_OUT_FILE, ROOT)} (appVersion = {v})')


def main():
    v = read_version()
    js = (
        '// 此文件由 sync_version.py 自动生成，请勿手动修改\n'
        f'window.APP_VERSION = {v!r};\n'
    )
    os.makedirs(os.path.dirname(OUT_FILE), exist_ok=True)
    with open(OUT_FILE, 'w', encoding='utf-8') as f:
        f.write(js)
    print(f'Generated {os.path.relpath(OUT_FILE, ROOT)} (APP_VERSION = {v})')
    gen_flutter(v)
    sync_package_json(v)
    sync_pubspec(v)


if __name__ == '__main__':
    main()
