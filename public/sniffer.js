/* LinkCOM 快速匹配 (Sniffer) 模块 —— 共享端/链接端通用, 独立可移除
 *
 * 两种并列匹配模式:
 *  mode=keyword : 匹配关键字模式. 在流中找关键字, 命中即记一条; 高亮匹配到的关键字段
 *  mode=extract : 提取模式. 按"起点偏移(字节) + 长度(字节)"直接从数据提取, 不依赖关键字; 高亮提取段
 *  两种模式均支持数据长度过滤 lenOp(> ≥ < ≤ =)/lenVal(=0 不限制)
 *    keyword 模式 -> 该次命中从关键字起到"下一个关键字/缓冲结尾"的字节长度
 *    extract 模式 -> 提取段的字节长度
 *  - 在 appendData() 旁路调用 Sniffer.feed(buf, cls)
 *  - 记录按提取值聚合: 重复计数 + 首/最近时间 + 原始帧(可查看, 命中段绿色高亮)
 *  - 规则存浏览器 localStorage, 支持导出/导入; 不进房间配置
 */
(function () {
  'use strict';

  function uid() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function hexToBytes(s) {
    const clean = String(s || '').replace(/[^0-9a-fA-F]/g, '');
    if (clean.length % 2 !== 0) return null;
    const out = new Uint8Array(clean.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
    return out;
  }
  function bytesToHex(buf) {
    return Array.from(buf).map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
  }
  // 把 "AA BB CC" 拆成 [ {hex:'AA', raw:0xAA}, ... ]
  function hexToUnits(hexStr) {
    return hexStr.split(' ').filter(Boolean).map((h) => ({ hex: h, byte: parseInt(h, 16) }));
  }

  function decodeField(buf, enc) {
    if (enc === 'hex') return bytesToHex(buf);
    if (enc === 'ascii') return Array.from(buf).map((b) => (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '.').join('');
    try {
      if (enc === 'gbk' && window.GbkUtil) return window.GbkUtil.decodeGbk(buf);
      if (enc === 'utf8' && window.GbkUtil) return window.GbkUtil.decodeUtf8(buf);
    } catch (e) { /* fall through */ }
    return Array.from(buf).map((b) => (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '.').join('');
  }

  // 取记录的原始字节(完整帧)
  function rawBytesOf(rec) { return hexToBytes(rec.rawHex.replace(/ /g, '')); }
  // 取记录高亮区间对应的字节(提取/匹配段)
  function hlBytesOf(rec) {
    if (!rec.hl) return null;
    const all = rawBytesOf(rec);
    return all.subarray(rec.hl.start, rec.hl.end);
  }
  // 按规则显示编码呈现记录(仅匹配部分)
  function displayValue(sniffer, rec) {
    const rule = sniffer.rules.find((x) => x.id === rec.ruleId);
    const enc = sniffer.dispEncOf(rule);
    const bytes = hlBytesOf(rec);
    if (!bytes || !bytes.length) return '';
    return decodeField(bytes, enc);
  }

  // 记录行展示的 HTML: full=true 时显示完整帧并高亮匹配区间(与查看帧一致); 否则仅显示匹配部分
  function recordValueHtml(sniffer, rec, full) {
    const rule = sniffer.rules.find((x) => x.id === rec.ruleId);
    const enc = sniffer.dispEncOf(rule);
    const hl = rec.hl;
    const MAX = 48; // 行内最多显示的字节数, 超出截断, 详情见查看帧
    if (!full) {
      const bytes = hlBytesOf(rec);
      return escapeHtml(decodeField(bytes || new Uint8Array(0), enc));
    }
    if (enc === 'hex') {
      const us = hexToUnits(rec.rawHex);
      const shown = us.slice(0, MAX);
      const html = shown.map((u, idx) => `<span class="${hl && idx >= hl.start && idx < hl.end ? 'hl' : ''}">${u.hex}</span>`).join(' ');
      return us.length > MAX ? html + ' …' : html;
    }
    // 文本类: 按字节显示, 不可打印以·表示
    const all = rawBytesOf(rec);
    const shown = all.slice(0, MAX);
    const html = Array.from(shown).map((b, idx) => {
      const ch = (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '·';
      return `<span class="${hl && idx >= hl.start && idx < hl.end ? 'hl' : ''}">${escapeHtml(ch)}</span>`;
    }).join('');
    return all.length > MAX ? html + '…' : html;
  }

  function lenOk(op, val, dataLen) {
    if (!val) return true;
    if (op === '>') return dataLen > val;
    if (op === '>=') return dataLen >= val;
    if (op === '<') return dataLen < val;
    if (op === '<=') return dataLen <= val;
    return dataLen === val;
  }

  function indexOfBytes(data, kw, from) {
    for (let i = from; i <= data.length - kw.length; i++) {
      let ok = true;
      for (let k = 0; k < kw.length; k++) if (data[i + k] !== kw[k]) { ok = false; break; }
      if (ok) return i;
    }
    return -1;
  }

  class Sniffer {
    constructor(opts) {
      this.storageKey = opts.storageKey;
      this.hint = opts.hint || function () {};
      this.rules = [];
      this.allRecords = [];
      this.accRecv = [];
      this.accSend = [];
      this.el = {};
      this._collapsed = {};
    }

    async init() {
      this.cacheEls();
      this.bindStatic();
      const local = this.loadLocal();
      if (local) {
        if (Array.isArray(local.rules)) this.rules = local.rules;
        if (Array.isArray(local.records)) this.allRecords = local.records;
        if (local.collapsed && typeof local.collapsed === 'object') this._collapsed = local.collapsed;
      }
      this.renderRules();
      this.renderRecords();
      if (this.el.panel) this.el.panel.classList.add('collapsed');
    }

    // 终端当前显示编码(gbk/utf8), 用于 dispEnc='text' 的解码
    termEnc() {
      const el = document.getElementById('encoding');
      return (el && el.value) || 'utf8';
    }
    // 规则实际显示编码: dispEnc='text' 时使用终端编码(gbk/utf8), 其余原样
    dispEncOf(rule) {
      if (!rule) return 'ascii';
      if (rule.dispEnc === 'text') return this.termEnc();
      return rule.dispEnc || 'ascii';
    }
    // 关键字模式: 按 matchEnc 把用户输入解释成待匹配的字节序列
    //   matchEnc='hex'  -> 输入按 HEX(空格分隔)解析
    //   matchEnc='text' -> 输入按文本(采用终端编码 gbk/utf8)编码成字节
    keywordBytes(rule) {
      const raw = (rule.keyword || '').trim();
      if (!raw) return null;
      if (rule.matchEnc === 'hex') return hexToBytes(raw);
      // 文本模式: 用终端编码把字符串编码成字节
      const enc = this.termEnc();
      const s = raw;
      try {
        if (enc === 'gbk' && window.GbkUtil) return window.GbkUtil.encodeGbk(s);
        // utf8 编码
        return new Uint8Array(new TextEncoder().encode(s));
      } catch (e) {
        return new Uint8Array(new TextEncoder().encode(s));
      }
    }

    cacheEls() {
      this.el.panel = document.getElementById('snPanel');
      this.el.rulesList = document.getElementById('snRules');
      this.el.summary = document.getElementById('snSummary');
      this.el.addBtn = document.getElementById('snAddBtn');
      this.el.impBtn = document.getElementById('snImportBtn');
      this.el.impFile = document.getElementById('snImportFile');
      this.el.expBtn = document.getElementById('snExportBtn');
      this.el.clearBtn = document.getElementById('snClearBtn');
    }

    feed(buf, cls) {
      const isTx = (cls === 'tx' || cls === 'stx' || cls === 'ltx');
      const dir = isTx ? 'send' : 'recv';
      if (!buf || !buf.length) return;
      const arr = (buf instanceof Uint8Array) ? buf : new Uint8Array(buf);
      const needAcc = this.rules.some((r) => r.enabled && r.accumulate);
      if (needAcc) {
        const acc = isTx ? this.accSend : this.accRecv;
        for (let i = 0; i < arr.length; i++) acc.push(arr[i]);
        if (acc.length > 65536) acc.splice(0, acc.length - 65536);
        const changed = this.scan(new Uint8Array(acc), dir);
        // 累积缓冲在"已匹配到完整帧"后清空, 避免历史无限累积导致同一条被反复记录
        if (changed) { acc.length = 0; }
      } else {
        this.scan(arr, dir);
      }
    }

    scan(data, dir) {
      if (!data || !data.length) return;
      let changed = false;
      for (const r of this.rules) {
        if (!r.enabled) continue;
        if (r.dir !== 'both' && r.dir !== dir) continue;

        if (r.mode === 'keyword') {
          const kw = this.keywordBytes(r);
          if (!kw || !kw.length) continue;
          let off = 0;
          while (off <= data.length - kw.length) {
            const pos = indexOfBytes(data, kw, off);
            if (pos < 0) break;
            // 高亮仅命中关键字段本身, 不延伸到帧尾
            const segLen = kw.length;
            if (!lenOk(r.lenOp, r.lenVal, segLen)) { off = pos + kw.length; continue; }
            this.pushRecord(r.id, bytesToHex(data), { start: pos, end: pos + segLen });
            changed = true;
            off = pos + kw.length;
          }
        } else {
          // extract 模式: 起点偏移 + 长度, 不依赖关键字, 不需要匹配编码(直接取原始字节)
          const startOff = r.startOffset || 0;
          const len = r.length || 0;
          if (!len) continue;
          if (startOff < 0 || startOff + len > data.length) continue;
          if (!lenOk(r.lenOp, r.lenVal, len)) continue;
          // 完整帧 = 本次扫描的数据; 高亮区间 = 提取段
          this.pushRecord(r.id, bytesToHex(data), { start: startOff, end: startOff + len });
          changed = true;
        }
      }
      if (changed) {
        this.renderRecords();
        this.persist();
      }
      return changed;
    }

    // 仅记录原始帧 + 高亮区间; 去重/排序在渲染时按规则配置计算
    pushRecord(ruleId, frameHex, hl) {
      if (!frameHex) return;
      // 防止同一数据被重复扫描产生完全相同的一条(如累积缓冲边界重复)
      const top = this.allRecords[0];
      if (top && top.ruleId === ruleId && top.rawHex === frameHex &&
          ((!top.hl && !hl) || (top.hl && hl && top.hl.start === hl.start && top.hl.end === hl.end))) {
        return;
      }
      this.allRecords.unshift({ ruleId, rawHex: frameHex, hl: hl || null, ts: nowTs(), frames: [frameHex] });
      if (this.allRecords.length > 20000) this.allRecords.pop();
    }

    // 取某条规则当前要展示的记录(按规则 dedup/sort)
    // dedupType: none(不去重) / match(匹配去重) / all(全匹配去重)
    // 每条结果带 _refs: 指向原始 allRecords 条目数组(用于查看帧精确展示对应帧)
    recordsFor(rule) {
      const list = this.allRecords.filter((r) => r.ruleId === rule.id);
      const dt = rule.dedupType || (rule.dedup ? 'match' : 'none');
      if (dt === 'none') {
        return list.map((rec) => ({ ruleId: rec.ruleId, rawHex: rec.rawHex, hl: rec.hl, count: 1, ts: rec.ts, lastTs: rec.ts, frames: rec.frames.slice(), _refs: [rec] }));
      }
      // 匹配去重: 仅按命中区间字节是否一致聚合; 全匹配去重: 整帧完全相同才聚合
      const matchKey = (rec) => {
        if (dt === 'all') return rec.rawHex;
        const b = hlBytesOf(rec);
        return b ? bytesToHex(b) : '';
      };
      const map = new Map();
      const out = [];
      for (const rec of list) {
        const key = matchKey(rec);
        const ex = map.get(key);
        if (ex) { ex.count++; ex._refs.push(rec); if (ex._refs.length > 50) ex._refs.shift(); ex.lastTs = rec.ts; }
        else { const e = { ruleId: rec.ruleId, rawHex: rec.rawHex, hl: rec.hl, count: 1, ts: rec.ts, lastTs: rec.ts, frames: rec.frames.slice(), _refs: [rec] }; map.set(key, e); out.push(e); }
      }
      return out;
    }

    // ---------- 渲染 ----------
    renderRules() {
      const box = this.el.rulesList;
      if (!box) return;
      box.innerHTML = '';
      if (!this.rules.length) {
        box.innerHTML = '<div class="sn-empty">暂无规则, 点击「添加规则」新建</div>';
      }
      let total = 0;
      for (const r of this.rules) {
        const recs = this.recordsFor(r);
        total += recs.length;
        const div = document.createElement('div');
        div.className = 'sn-rule' + (r.enabled ? '' : ' off');
        const modeLabel = r.mode === 'keyword' ? '匹配关键字' : '提取';
        const lenFilter = r.lenVal ? ` 长${r.lenOp || '='}${r.lenVal}` : '';
        const meta = r.mode === 'keyword'
          ? `${dirLabel(r.dir)} | 匹配:${escapeHtml(r.keyword || '-')}${lenFilter} | 匹:${r.matchEnc}→显:${r.dispEnc === 'hex' ? 'HEX' : '文本'}`
          : `${dirLabel(r.dir)} | 偏移:${r.startOffset || 0} 取${r.length || 0}字节${lenFilter} | 显:${r.dispEnc === 'hex' ? 'HEX' : '文本'}`;
        const collapsed = this._collapsed[r.id] ? ' collapsed' : '';
        div.innerHTML = `
          <div class="sn-rule-main" data-rid="${r.id}">
            <button class="sn-fold" data-act="fold" data-id="${r.id}" title="折叠/展开">${this._collapsed[r.id] ? '▸' : '▾'}</button>
            <label class="sn-en"><input type="checkbox" data-act="en" data-id="${r.id}" ${r.enabled ? 'checked' : ''}></label>
            <span class="sn-badge ${r.enabled ? 'sn-active' : ''}">${modeLabel}</span>
            <span class="sn-name">${escapeHtml(r.name)}</span>
            <span class="sn-meta">${meta}${r.accumulate ? ' | 累积' : ''}</span>
            <span class="sn-rec-count">${recs.length}${r.dedupType === 'match' ? ' (匹配去重)' : r.dedupType === 'all' ? ' (全匹配去重)' : ''}</span>
            <span class="grow"></span>
            <button class="btn sm danger" data-act="exp" data-id="${r.id}">导出</button>
            <button class="btn sm danger" data-act="clr" data-id="${r.id}">清空</button>
            <button class="btn sm danger" data-act="edit" data-id="${r.id}">编辑</button>
            <button class="btn sm danger" data-act="del" data-id="${r.id}">删除</button>
          </div>
          <div class="sn-rule-recs${collapsed}"></div>`;
        box.appendChild(div);
        const recBox = div.querySelector('.sn-rule-recs');
        this.renderRecordsInto(recBox, r, recs);
      }
      if (this.el.summary) {
        const en = this.rules.filter((r) => r.enabled).length;
        this.el.summary.textContent = `规则 ${en}/${this.rules.length} · 记录 ${total}`;
      }
    }

    renderRecords() { this.renderRules(); }

    // 把某规则的记录渲染到指定容器内
    renderRecordsInto(box, rule, recs) {
      if (!box) return;
      box.innerHTML = '';
      if (!recs.length) { box.innerHTML = '<div class="sn-empty sm">无匹配记录</div>'; return; }
      const key = rule.sortKey || 'time', dir = (rule.sortDir == null ? -1 : rule.sortDir);
      const arr = recs.slice().sort((a, b) => {
        let c;
        if (key === 'count') c = a.count - b.count;
        else if (key === 'value') {
          const va = displayValue(this, a), vb = displayValue(this, b);
          c = va < vb ? -1 : va > vb ? 1 : 0;
        } else c = a.lastTs < b.lastTs ? -1 : a.lastTs > b.lastTs ? 1 : 0;
        return c * dir;
      });
      const full = (rule.dedupType || (rule.dedup ? 'match' : 'none')) !== 'match';
      for (let i = 0; i < arr.length; i++) {
        const rec = arr[i];
        const div = document.createElement('div');
        div.className = 'sn-rec';
        const valHtml = recordValueHtml(this, rec, full);
        const row = `
          <span class="sn-rec-time">${rec.lastTs}</span>
          <span class="sn-rec-val${full ? '' : ' hl-val'}">${valHtml}</span>
          ${rec.count > 1 ? `<span class="sn-rec-cnt">×${rec.count}</span>` : ''}
          <span class="grow"></span>
          <button class="btn sm ghost" data-act="view" data-rid="${rule.id}" data-i="${i}">查看帧</button>`;
        div.innerHTML = `<div class="sn-rec-row">${row}</div>`;
        box.appendChild(div);
      }
    }

    // ---------- 规则编辑器 ----------
    openEditor(ruleId) {
      const r = ruleId ? this.rules.find((x) => x.id === ruleId) : null;
      const isNew = !r;
      const cur = r || { id: uid(), name: '', dir: 'recv', mode: 'extract', keyword: '', startOffset: 0, length: 0, matchEnc: 'hex', dispEnc: 'text', dedupType: 'match', lenOp: '=', lenVal: 0, accumulate: true, enabled: true };
      const dlg = document.createElement('div');
      dlg.className = 'sn-dlg-mask';
      dlg.innerHTML = `
        <div class="sn-dlg sn-dlg-wide">
          <h3>${isNew ? '添加规则' : '编辑规则'}</h3>
          <div class="sn-form">
            <div class="sn-grid">
              <label class="sn-g-2col">名称<input id="snE_name" value="${escapeHtml(cur.name)}" placeholder="如: 读卡序列号"></label>
              <label>匹配模式
                <select id="snE_mode">
                  <option value="extract" ${cur.mode === 'extract' ? 'selected' : ''}>提取(起点偏移 + 长度)</option>
                  <option value="keyword" ${cur.mode === 'keyword' ? 'selected' : ''}>匹配关键字(命中即记录)</option>
                </select>
              </label>
              <label>方向
                <select id="snE_dir">
                  <option value="recv" ${cur.dir === 'recv' ? 'selected' : ''}>仅接收</option>
                  <option value="send" ${cur.dir === 'send' ? 'selected' : ''}>仅发送</option>
                  <option value="both" ${cur.dir === 'both' ? 'selected' : ''}>全部</option>
                </select>
              </label>
              <label>显示编码(记录呈现)
                <select id="snE_denc">
                  <option value="hex" ${cur.dispEnc === 'hex' ? 'selected' : ''}>HEX</option>
                  <option value="text" ${cur.dispEnc !== 'hex' ? 'selected' : ''}>文本(采用"显示数据"编码)</option>
                </select>
              </label>
              <label class="sn-menc-field" style="display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--muted)">匹配编码(决定关键字如何解释)
                <select id="snE_menc">
                  <option value="hex" ${cur.matchEnc === 'hex' ? 'selected' : ''}>HEX(按十六进制匹配)</option>
                  <option value="text" ${cur.matchEnc === 'text' ? 'selected' : ''}>文本(按"显示数据"处编码匹配)</option>
                </select>
              </label>
            </div>
            <div class="sn-kw-fields">
              <label class="sn-g-2col">匹配关键字(HEX 或文本, 与匹配编码对应)<input id="snE_kw" value="${escapeHtml(cur.keyword)}" placeholder="如 9B 01 或 HELLO"></label>
            </div>
            <div class="sn-extract-fields">
              <label>起点偏移(字节, 从数据流开头计)<input id="snE_startoff" type="number" min="0" value="${cur.startOffset || 0}"></label>
              <label>提取长度(字节)<input id="snE_len" type="number" min="1" value="${cur.length || 0}"></label>
            </div>
            <div class="sn-row-group sn-opts-row">
              <label class="sn-row sn-len-filter"><span>数据长度过滤</span>
                <select id="snE_lenop">
                  <option value=">" ${cur.lenOp === '>' ? 'selected' : ''}>&gt;</option>
                  <option value=">=" ${cur.lenOp === '>=' ? 'selected' : ''}>&ge;</option>
                  <option value="<" ${cur.lenOp === '<' ? 'selected' : ''}>&lt;</option>
                  <option value="<=" ${cur.lenOp === '<=' ? 'selected' : ''}>&le;</option>
                  <option value="=" ${cur.lenOp === '=' ? 'selected' : ''}>=</option>
                </select>
                <input id="snE_lenval" type="number" min="0" value="${cur.lenVal || 0}" placeholder="0=不限制">
              </label>
              <label class="sn-row" style="gap:6px">去重方式
                <select id="snE_dedupType">
                  <option value="none" ${(cur.dedupType || (cur.dedup ? 'match' : 'none')) === 'none' ? 'selected' : ''}>不去重</option>
                  <option value="match" ${(cur.dedupType || (cur.dedup ? 'match' : 'none')) === 'match' ? 'selected' : ''}>匹配去重</option>
                  <option value="all" ${(cur.dedupType || (cur.dedup ? 'match' : 'none')) === 'all' ? 'selected' : ''}>全匹配去重</option>
                </select>
              </label>
              <label class="sn-row" style="gap:6px">排序
                <select id="snE_sort">
                  <option value="time" ${(cur.sortKey || 'time') === 'time' ? 'selected' : ''}>按时间</option>
                  <option value="value" ${(cur.sortKey || 'time') === 'value' ? 'selected' : ''}>按值</option>
                  <option value="count" ${(cur.sortKey || 'time') === 'count' ? 'selected' : ''}>按次数</option>
                </select>
              </label>
            </div>
            <label class="sn-row"><input id="snE_acc" type="checkbox" ${cur.accumulate ? 'checked' : ''}> 跨帧累积(流被拆开时勾选, 偏移更准)</label>
            <label class="sn-row"><input id="snE_en" type="checkbox" ${cur.enabled ? 'checked' : ''}> 启用</label>
          </div>
          <div class="sn-dlg-bar">
            <span class="grow"></span>
            <button class="btn sm ghost" id="snE_cancel">取消</button>
            <button class="btn sm primary" id="snE_save">保存</button>
          </div>
        </div>`;
      document.body.appendChild(dlg);
      const syncMode = () => {
        const m = dlg.querySelector('#snE_mode').value;
        dlg.querySelector('.sn-kw-fields').classList.toggle('show', m === 'keyword');
        dlg.querySelector('.sn-extract-fields').classList.toggle('show', m === 'extract');
        dlg.querySelector('.sn-menc-field').style.display = (m === 'keyword') ? '' : 'none';
      };
      dlg.querySelector('#snE_mode').onchange = syncMode;
      syncMode();
      const close = () => dlg.remove();
      dlg.querySelector('#snE_cancel').onclick = close;
      dlg.querySelector('#snE_save').onclick = () => {
        const mode = dlg.querySelector('#snE_mode').value;
        const dir = dlg.querySelector('#snE_dir').value;
        const len = parseInt(dlg.querySelector('#snE_len').value, 10) || 0;
        const startOff = parseInt(dlg.querySelector('#snE_startoff').value, 10) || 0;
        const lenVal = parseInt(dlg.querySelector('#snE_lenval').value, 10) || 0;
        let keyword = '';
        if (mode === 'keyword') {
          keyword = dlg.querySelector('#snE_kw').value.trim();
          const mEnc = dlg.querySelector('#snE_menc').value;
          if (mEnc === 'hex' && !hexToBytes(keyword)) { alert('匹配关键字 HEX 格式错误(需偶数位, 空格分隔)'); return; }
          if (!keyword) { alert('请填写匹配关键字'); return; }
        } else {
          if (!len) { alert('提取模式请填写提取长度(至少 1 字节)'); return; }
        }
        const data = {
          id: cur.id,
          name: dlg.querySelector('#snE_name').value.trim() || '未命名规则',
          dir, mode, keyword, startOffset: startOff, length: len,
          matchEnc: dlg.querySelector('#snE_menc').value,
          dispEnc: dlg.querySelector('#snE_denc').value,
          lenOp: dlg.querySelector('#snE_lenop').value,
          lenVal,
          accumulate: dlg.querySelector('#snE_acc').checked,
          enabled: dlg.querySelector('#snE_en').checked,
          dedupType: dlg.querySelector('#snE_dedupType').value,
          sortKey: dlg.querySelector('#snE_sort').value,
          sortDir: -1,
        };
        if (isNew) this.rules.push(data); else Object.assign(r, data);
        this.renderRules();
        this.persist();
        close();
      };
    }

    // 查看帧: 仅展示当前记录对应的帧(去重=该组所有帧; 未去重=该条一条)
    viewFrames(rule, rec) {
      if (!rec) return;
      const enc = this.dispEncOf(rule);
      const refs = rec._refs && rec._refs.length ? rec._refs : [{ rawHex: rec.rawHex, hl: rec.hl, ts: rec.lastTs }];
      const dlg = document.createElement('div');
      dlg.className = 'sn-dlg-mask';
      // 每条命中用各自的 hl 区间高亮 [hl.start, hl.end); 显示按规则 dispEnc 解码
      const body = refs.map((h, i) => {
        const hl = h.hl;
        const all = rawBytesOf(h);
        let html;
        if (enc === 'hex') {
          const us = hexToUnits(h.rawHex);
          html = us.map((u, idx) => `<span class="${hl && idx >= hl.start && idx < hl.end ? 'hl' : ''}">${u.hex}</span>`).join(' ');
        } else {
          // 文本/编码类: 按字节高亮, 不可打印以·表示
          html = Array.from(all).map((b, idx) => {
            const ch = (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '·';
            return `<span class="${hl && idx >= hl.start && idx < hl.end ? 'hl' : ''}">${escapeHtml(ch)}</span>`;
          }).join('');
        }
        return `<div class="sn-frame">
            <span class="sn-frame-ts">${h.ts}</span><span class="sn-frame-idx">#${i + 1}</span>
            <code>${html}</code>
          </div>`;
      }).join('');
      dlg.innerHTML = `
        <div class="sn-dlg">
          <h3>帧记录 (共 ${refs.length} 次) · 编码: ${enc}</h3>
          <div class="sn-frames">${body}</div>
          <div class="sn-dlg-bar"><span class="grow"></span><button class="btn sm ghost" id="snF_close">关闭</button></div>
        </div>`;
      document.body.appendChild(dlg);
      dlg.querySelector('#snF_close').onclick = () => dlg.remove();
    }

    // ---------- 绑定 ----------
    bindStatic() {
      const self = this;
      if (this.el.addBtn) this.el.addBtn.onclick = () => self.openEditor(null);
      if (this.el.clearBtn) this.el.clearBtn.onclick = () => {
        if (confirm('清空全部规则的记录? (规则保留)')) { self.allRecords = []; self.renderRecords(); self.persist(); }
      };
      if (this.el.expBtn) this.el.expBtn.onclick = () => self.exportRules();
      if (this.el.impBtn && this.el.impFile) {
        this.el.impBtn.onclick = () => self.el.impFile.click();
        this.el.impFile.onchange = (e) => self.importRules(e);
      }
      if (this.el.rulesList) {
        this.el.rulesList.onclick = (e) => {
          const btn = e.target.closest('[data-act]');
          if (!btn) {
            // 点击规则头部空白处也可折叠/展开
            const head = e.target.closest('.sn-rule-main');
            if (head) {
              const rid = head.getAttribute('data-rid');
              if (rid) { self._collapsed[rid] = !self._collapsed[rid]; self.renderRules(); self.persist(); }
            }
            return;
          }
          const id = btn.getAttribute('data-id');
          const act = btn.getAttribute('data-act');
          if (act === 'view') {
            const rid = btn.getAttribute('data-rid');
            const ri = parseInt(btn.getAttribute('data-i'), 10);
            const rule = self.rules.find((x) => x.id === rid);
            if (rule) {
              const recs = self.recordsFor(rule);
              const rec = recs[ri];
              if (rec) self.viewFrames(rule, rec);
            }
            return;
          }
          const r = self.rules.find((x) => x.id === id);
          if (!r) return;
          if (act === 'en') { r.enabled = btn.checked; self.renderRules(); self.persist(); }
          else if (act === 'edit') self.openEditor(id);
          else if (act === 'del') {
            if (confirm('删除规则「' + r.name + '」?')) {
              self.rules = self.rules.filter((x) => x.id !== id);
              self.allRecords = self.allRecords.filter((x) => x.ruleId !== id);
              self.renderRules(); self.persist();
            }
          } else if (act === 'clr') {
            if (confirm('清空规则「' + r.name + '」的记录?')) {
              self.allRecords = self.allRecords.filter((x) => x.ruleId !== id);
              self.renderRules(); self.persist();
            }
          } else if (act === 'exp') {
            self.exportRecords(r);
          } else if (act === 'fold') {
            self._collapsed[id] = !self._collapsed[id];
            self.renderRules(); self.persist();
          }
        };
      }
      const toggle = document.getElementById('snToggle');
      if (toggle && this.el.panel) {
        toggle.onclick = () => {
          const c = self.el.panel.classList.toggle('collapsed');
          toggle.textContent = c ? '展开' : '收起';
        };
        // 点击面板标题栏空白处(非按钮)也可切换整个面板展开/收起
        const snBar = this.el.panel.querySelector('.sn-bar');
        snBar && snBar.addEventListener('click', (e) => {
          if (e.target.closest('button')) return; // 按钮各自处理, 避免误触/双触发
          const c = self.el.panel.classList.toggle('collapsed');
          toggle.textContent = c ? '展开' : '收起';
        });
      }
    }

    // ---------- 持久化 ----------
    loadLocal() {
      try { return JSON.parse(localStorage.getItem(this.storageKey) || 'null'); } catch (e) { return null; }
    }
    persist() {
      try {
        localStorage.setItem(this.storageKey, JSON.stringify({ rules: this.rules, records: this.allRecords, collapsed: this._collapsed }));
      } catch (e) {}
    }
    exportRules() {
      const blob = new Blob([JSON.stringify({ rules: this.rules }, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = 'linkcom_sniffer_rules.json';
      a.click(); URL.revokeObjectURL(url);
    }
    // 仅导出某条规则的记录
    exportRecords(rule) {
      const recs = this.allRecords.filter((x) => x.ruleId === rule.id).map((r) => ({
        ts: r.ts, rawHex: r.rawHex, hl: r.hl,
        value: displayValue(this, { ruleId: r.ruleId, rawHex: r.rawHex, hl: r.hl }),
      }));
      const blob = new Blob([JSON.stringify({ rule: rule.name, dispEnc: rule.dispEnc, records: recs }, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = `linkcom_sniffer_${rule.name || rule.id}.json`;
      a.click(); URL.revokeObjectURL(url);
    }
    importRules(e) {
      const file = e.target.files && e.target.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = () => {
        try {
          const data = JSON.parse(reader.result);
          if (Array.isArray(data.rules)) {
            this.rules = data.rules.map((r) => Object.assign({ id: uid(), name: '', dir: 'recv', mode: 'extract', keyword: '', startOffset: 0, length: 0, matchEnc: 'hex', dispEnc: 'text', dedupType: 'match', lenOp: '=', lenVal: 0, accumulate: true, enabled: true, sortKey: 'time', sortDir: -1 }, r));
            this.renderRules(); this.persist();
            this.hint('已导入 ' + this.rules.length + ' 条规则');
          } else this.hint('文件格式不正确', true);
        } catch (err) { this.hint('导入失败: ' + err.message, true); }
        e.target.value = '';
      };
      reader.readAsText(file);
    }
  }

  function nowTs() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }
  function dirLabel(d) { return d === 'send' ? '仅发送' : d === 'both' ? '全部' : '仅接收'; }

  window.Sniffer = Sniffer;
})();
