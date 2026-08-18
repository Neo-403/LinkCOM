"""网络工具: 枚举本机网卡 IP (用于多网卡多 IP 选择)"""
import socket


def list_local_ips():
    """返回本机所有非回环 IPv4 地址列表 (含可读名)"""
    ips = []
    try:
        hostname = socket.gethostname()
        infos = socket.getaddrinfo(hostname, None, socket.AF_INET, socket.SOCK_STREAM)
        for info in infos:
            ip = info[4][0]
            if ip and ip != '127.0.0.1' and ip not in ips:
                ips.append(ip)
    except Exception:
        pass
    # 兜底: 通过 UDP 探测出口 IP
    if not ips:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            s.close()
            if ip not in ips:
                ips.append(ip)
        except Exception:
            pass
    if '127.0.0.1' not in ips:
        ips.insert(0, '127.0.0.1')
    return ips
