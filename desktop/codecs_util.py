"""编解码工具: UTF-8 / GBK 文本与字节互转 (Python 标准库支持)"""
import codecs


def decode_text(buf: bytes, encoding: str) -> str:
    enc = 'gbk' if encoding == 'gbk' else 'utf-8'
    try:
        return buf.decode(enc, errors='replace')
    except Exception:
        return buf.decode('latin-1', errors='replace')


def encode_text(s: str, encoding: str) -> bytes:
    enc = 'gbk' if encoding == 'gbk' else 'utf-8'
    try:
        return s.encode(enc)
    except Exception:
        return s.encode('utf-8')


def hex_lines(buf: bytes, width: int = 16) -> str:
    parts = []
    for i in range(0, len(buf), width):
        sl = buf[i:i + width]
        parts.append(' '.join(f'{b:02X}' for b in sl))
    return '\n'.join(parts)


def text_of(buf: bytes, encoding: str) -> str:
    """文本模式下不可打印字符用 . 替代 (与 Web 端一致)"""
    s = decode_text(buf, encoding)
    out = []
    for ch in s:
        c = ord(ch)
        if c == 0x0d or c == 0x0a or (0x20 <= c < 0x7f) or c > 0x7f:
            out.append(ch)
        else:
            out.append('.')
    return ''.join(out)
