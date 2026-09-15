"""LinkCOM 桌面端 - 快速匹配 (Sniffer) 核心逻辑 (无 Qt 依赖)

与 Web 端 public/sniffer.js 的规则/记录格式互通 (JSON 可互导):
  mode=keyword : 匹配关键字模式. 在流中找关键字, 命中即记一条; 高亮命中段
  mode=extract : 提取模式. 按"起点偏移(字节) + 长度(字节)"直接提取, 不依赖关键字; 高亮提取段
  两种模式均支持数据长度过滤 lenOp/lenVal (=0 不限制) 与跨帧累积 accumulate
记录按命中值/整帧聚合去重 (dedupType: none/match/all), 支持按时间/值/次数排序
"""
import json
import random
import string
import time

MAX_RECORDS = 5000        # 内存中保留的记录上限 (最新在前)
MAX_ACC_BUF = 65536       # 跨帧累积缓冲上限 (字节)
MAX_FRAME_BYTES = 4096    # 单条记录保留的原始帧字节上限, 超出截断 (查看帧仍可高亮命中段)

DEFAULT_RULE = {
    'id': '', 'name': '', 'dir': 'recv', 'mode': 'extract',
    'keyword': '', 'startOffset': 0, 'length': 0,
    'matchEnc': 'hex', 'dispEnc': 'text',
    'lenOp': '=', 'lenVal': 0,
    'dedupType': 'match', 'sortKey': 'time', 'sortDir': -1,
    'accumulate': True, 'enabled': True,
}


def new_rule_id():
    return str(int(time.time() * 1000)) + ''.join(random.choices(string.ascii_lowercase + string.digits, k=5))


def now_ts():
    return time.strftime('%H:%M:%S')


def hex_of(buf) -> str:
    return ' '.join(f'{b:02X}' for b in bytes(buf))


def hex_to_bytes(s):
    """'AA BB CC' / 'AABBCC' -> bytes; 奇数位或无有效字符返回 None (非 HEX 字符被忽略)"""
    if s is None:
        return None
    clean = ''.join(ch for ch in str(s) if ch in '0123456789abcdefABCDEF')
    if len(clean) % 2 != 0:
        return None
    if not clean:
        return None
    return bytes(int(clean[i:i + 2], 16) for i in range(0, len(clean), 2))


def normalize_rule(r):
    """套用默认值并校验字段 (保留未知字段, 与 Web 端导入行为一致)"""
    rule = dict(DEFAULT_RULE)
    if isinstance(r, dict):
        rule.update(r)
    if not rule.get('id'):
        rule['id'] = new_rule_id()
    if rule.get('dir') not in ('recv', 'send', 'both'):
        rule['dir'] = 'recv'
    if rule.get('mode') not in ('keyword', 'extract'):
        rule['mode'] = 'extract'
    if rule.get('matchEnc') not in ('hex', 'text'):
        rule['matchEnc'] = 'hex'
    if rule.get('dispEnc') not in ('hex', 'text', 'ascii'):
        rule['dispEnc'] = 'text'
    if rule.get('dedupType') not in ('none', 'match', 'all'):
        rule['dedupType'] = 'match'
    if rule.get('sortKey') not in ('time', 'value', 'count'):
        rule['sortKey'] = 'time'
    try:
        rule['sortDir'] = int(rule.get('sortDir', -1))
    except (TypeError, ValueError):
        rule['sortDir'] = -1
    for k in ('startOffset', 'length', 'lenVal'):
        try:
            rule[k] = int(rule.get(k) or 0)
        except (TypeError, ValueError):
            rule[k] = 0
    if rule['startOffset'] < 0:
        rule['startOffset'] = 0
    if rule['length'] < 0:
        rule['length'] = 0
    if rule['lenVal'] < 0:
        rule['lenVal'] = 0
    rule['keyword'] = str(rule.get('keyword') or '')
    rule['name'] = str(rule.get('name') or '')
    rule['accumulate'] = bool(rule.get('accumulate', True))
    rule['enabled'] = bool(rule.get('enabled', True))
    return rule


class Sniffer:
    """快速匹配引擎. 由 GUI 线程直接调用 (feed/scan 均为同步纯逻辑)。"""

    def __init__(self, enc_provider=None):
        self.rules = []
        self.records = []   # 最新在前: {ruleId, rawHex, hl:[start,end], ts}
        self._acc_recv = bytearray()
        self._acc_send = bytearray()
        self._enc_provider = enc_provider or (lambda: 'utf8')

    # ---------- 编码 ----------
    def term_enc(self) -> str:
        try:
            return self._enc_provider() or 'utf8'
        except Exception:
            return 'utf8'

    def rule_bytes_of(self, rule):
        """关键字按匹配编码解释成待匹配字节 (matchEnc=hex -> HEX; 否则按终端编码 gbk/utf8)"""
        raw = (rule.get('keyword') or '').strip()
        if not raw:
            return None
        if rule.get('matchEnc') == 'hex':
            return hex_to_bytes(raw)
        enc = 'gbk' if self.term_enc() == 'gbk' else 'utf-8'
        try:
            return raw.encode(enc)
        except Exception:
            return raw.encode('utf-8', 'replace')

    def display_bytes(self, b, disp_enc=None) -> str:
        """按规则显示编码把字节解码为字符串 (hex/ascii/text)"""
        disp_enc = disp_enc or 'text'
        if disp_enc == 'hex':
            return hex_of(b)
        if disp_enc == 'ascii':
            return ''.join(chr(x) if 0x20 <= x < 0x7f else '.' for x in b)
        enc = 'gbk' if self.term_enc() == 'gbk' else 'utf-8'
        try:
            return bytes(b).decode(enc, errors='replace')
        except Exception:
            return bytes(b).decode('latin-1', errors='replace')

    # ---------- 数据入口 ----------
    def feed(self, buf, cls) -> bool:
        """旁路监听一条数据 (cls: tx/stx/ltx 为发送方向, 其余为接收方向). 返回是否有新记录"""
        if not buf:
            return False
        is_tx = cls in ('tx', 'stx', 'ltx')
        d = 'send' if is_tx else 'recv'
        arr = bytes(buf)
        if any(r.get('enabled', True) and r.get('accumulate', True) for r in self.rules):
            acc = self._acc_send if is_tx else self._acc_recv
            acc.extend(arr)
            if len(acc) > MAX_ACC_BUF:
                del acc[:len(acc) - MAX_ACC_BUF]
            changed = self.scan(bytes(acc), d)
            # 累积缓冲在"已匹配到记录"后清空, 避免历史无限累积导致同一条被反复记录
            if changed:
                acc.clear()
            return changed
        return self.scan(arr, d)

    @staticmethod
    def _len_ok(rule, n) -> bool:
        val = rule.get('lenVal') or 0
        if not val:
            return True
        op = rule.get('lenOp') or '='
        if op == '>':
            return n > val
        if op == '>=':
            return n >= val
        if op == '<':
            return n < val
        if op == '<=':
            return n <= val
        return n == val

    def scan(self, data, d) -> bool:
        if not data:
            return False
        changed = False
        for r in self.rules:
            if not r.get('enabled', True):
                continue
            rd = r.get('dir', 'recv')
            if rd != 'both' and rd != d:
                continue
            if r.get('mode') == 'keyword':
                kw = self.rule_bytes_of(r)
                if not kw:
                    continue
                off = 0
                while off <= len(data) - len(kw):
                    pos = data.find(kw, off)
                    if pos < 0:
                        break
                    if not self._len_ok(r, len(kw)):
                        off = pos + len(kw)
                        continue
                    self.push_record(r['id'], hex_of(data), [pos, pos + len(kw)])
                    changed = True
                    off = pos + len(kw)
            else:
                # 提取模式: 起点偏移 + 长度, 直接取原始字节
                start = r.get('startOffset') or 0
                length = r.get('length') or 0
                if not length:
                    continue
                if start < 0 or start + length > len(data):
                    continue
                if not self._len_ok(r, length):
                    continue
                self.push_record(r['id'], hex_of(data), [start, start + length])
                changed = True
        return changed

    def push_record(self, rule_id, frame_hex, hl=None):
        """记录一条命中. 与 Web 端一致: 每次命中都记录, 去重/计数在渲染时按规则配置计算"""
        if not frame_hex:
            return
        # 截断超长帧 (如跨帧累积的大缓冲), 避免内存/配置文件膨胀; '…' 为截断标记
        units = frame_hex.split(' ')
        if len(units) > MAX_FRAME_BYTES:
            frame_hex = ' '.join(units[:MAX_FRAME_BYTES]) + ' …'
        self.records.insert(0, {'ruleId': rule_id, 'rawHex': frame_hex,
                                'hl': list(hl) if hl else None, 'ts': now_ts()})
        if len(self.records) > MAX_RECORDS:
            del self.records[MAX_RECORDS:]

    # ---------- 记录聚合/排序 ----------
    def records_for(self, rule):
        """取某条规则要展示的记录 (按规则 dedupType 聚合). 每条含 count/ts/lastTs/_refs"""
        rid = rule['id']
        lst = [rec for rec in self.records if rec.get('ruleId') == rid]
        dt = rule.get('dedupType') or 'match'
        if dt == 'none':
            return [dict(rec, count=1, lastTs=rec.get('ts') or '', _refs=[rec]) for rec in lst]

        def key(rec):
            if dt == 'all':
                return rec.get('rawHex') or ''
            hl = rec.get('hl')
            if not hl:
                return ''
            b = hex_to_bytes(rec.get('rawHex') or '')
            if b is None or hl[1] > len(b):
                return ''
            return hex_of(b[hl[0]:hl[1]])

        out = []
        first = {}
        for rec in lst:
            k = key(rec)
            ex = first.get(k)
            if ex is not None:
                ex['count'] += 1
                ex['_refs'].append(rec)
                if len(ex['_refs']) > 50:
                    ex['_refs'].pop(0)
                ex['lastTs'] = rec.get('ts') or ex['lastTs']
            else:
                e = {'ruleId': rid, 'rawHex': rec.get('rawHex') or '', 'hl': rec.get('hl'),
                     'count': 1, 'ts': rec.get('ts') or '', 'lastTs': rec.get('ts') or '',
                     '_refs': [rec]}
                first[k] = e
                out.append(e)
        return out

    def sort_records(self, recs, rule):
        key = rule.get('sortKey') or 'time'
        d = rule.get('sortDir')
        d = -1 if d is None else int(d)

        def sk(rec):
            if key == 'count':
                return rec.get('count', 1)
            if key == 'value':
                return self.display_value(rec, rule)
            return rec.get('lastTs') or ''

        return sorted(recs, key=sk, reverse=(d == -1))

    def display_value(self, rec, rule) -> str:
        """按规则显示编码解码命中段 (hl 区间)"""
        hl = rec.get('hl')
        if not hl:
            return ''
        b = hex_to_bytes(rec.get('rawHex') or '')
        if b is None:
            return ''
        seg = b[hl[0]:hl[1]]
        if not seg:
            return ''
        return self.display_bytes(seg, rule.get('dispEnc') or 'text')

    # ---------- 规则管理 ----------
    def upsert_rule(self, data):
        for i, r in enumerate(self.rules):
            if r['id'] == data['id']:
                self.rules[i] = data
                return
        self.rules.append(data)

    def remove_rule(self, rule_id):
        self.rules = [r for r in self.rules if r['id'] != rule_id]
        self.clear_records(rule_id)

    def clear_records(self, rule_id=None):
        if rule_id is None:
            self.records.clear()
        else:
            self.records = [rec for rec in self.records if rec.get('ruleId') != rule_id]

    def find_rule(self, rule_id):
        return next((x for x in self.rules if x['id'] == rule_id), None)

    def new_rule(self):
        return normalize_rule(None)

    # ---------- 持久化 / 导入导出 ----------
    def load_storage(self, data):
        if not isinstance(data, dict):
            return
        rules = data.get('rules')
        if isinstance(rules, list):
            self.rules = [normalize_rule(r) for r in rules]
        records = data.get('records')
        if isinstance(records, list):
            out = []
            for rec in records:
                if isinstance(rec, dict) and isinstance(rec.get('rawHex'), str) and rec['rawHex']:
                    hl = rec.get('hl')
                    out.append({
                        'ruleId': rec.get('ruleId'),
                        'rawHex': rec['rawHex'],
                        'hl': [int(hl[0]), int(hl[1])] if isinstance(hl, (list, tuple)) and len(hl) >= 2 else None,
                        'ts': rec.get('ts') or '',
                    })
            self.records = out[:MAX_RECORDS]

    def to_storage(self, cap=1000):
        """存入配置文件: 规则全量, 记录仅保留最近 cap 条"""
        return {'rules': self.rules, 'records': self.records[:cap]}

    def export_rules(self) -> str:
        return json.dumps({'rules': self.rules}, ensure_ascii=False, indent=2)

    def import_rules(self, text):
        """导入 Web 端导出的规则 JSON. 返回 (是否成功, 消息)"""
        try:
            data = json.loads(text)
        except Exception as e:
            return False, '导入失败: ' + str(e)
        rules = data.get('rules') if isinstance(data, dict) else data
        if not isinstance(rules, list) or not rules:
            return False, '导入失败: 文件中没有规则'
        self.rules = [normalize_rule(r) for r in rules]
        return True, '已导入 ' + str(len(self.rules)) + ' 条规则'

    def export_rule_records(self, rule) -> str:
        """导出某条规则的记录 (格式与 Web 端一致)"""
        recs = []
        for rec in self.records:
            if rec.get('ruleId') != rule['id']:
                continue
            hl = rec.get('hl')
            recs.append({
                'ts': rec.get('ts') or '',
                'rawHex': rec.get('rawHex') or '',
                'hl': ({'start': hl[0], 'end': hl[1]} if hl else None),
                'value': self.display_value(rec, rule),
            })
        return json.dumps({'rule': rule.get('name') or rule['id'], 'dispEnc': rule.get('dispEnc'),
                           'records': recs}, ensure_ascii=False, indent=2)
