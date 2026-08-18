"""解析 linkcom:// URL Scheme 启动参数

格式: linkcom://?room=XXX&pwd=YYY&server=ws://host:port&mode=serial
支持带/不带 ? 前缀两种写法。
"""
import urllib.parse


def parse_linkcom_uri(uri: str):
    if not uri:
        return {}
    s = uri.strip()
    if s.lower().startswith('linkcom://'):
        s = s[len('linkcom://'):]
    # 去掉可能的 //
    if s.startswith('///'):
        s = s[3:]
    elif s.startswith('//'):
        s = s[2:]
    # 允许带 ? 或不带
    if s.startswith('?'):
        s = s[1:]
    # 也可能直接是 room=xxx 形式
    try:
        params = urllib.parse.parse_qs(s, keep_blank_values=True)
    except Exception:
        return {}
    out = {}
    for k in ('room', 'pwd', 'server', 'mode', 'basepath'):
        if k in params and params[k]:
            val = params[k][0]
            if k == 'basepath':
                k = 'basePath'
            out[k] = val
    return out
