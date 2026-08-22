/* LinkCOM 链接端逻辑: 手机/电脑浏览器经 WebSocket 远程收发共享串口数据
 * 改进: 文本+HEX 多选分屏; GBK/UTF-8; 历史重渲染; 连接前禁用发送
 */
(function () {
  'use strict';

  let ws = null, wsOpen = false, joined = false;
  let shareOnline = false;           // 共享端是否在线 (WebSocket 已连且在房间内)
  let sharePortOpen = false;         // 共享端串口是否已打开 (可发送的前提之一)
  let shareMode = 'serial';          // 共享端通道类型: serial | tcpClient | tcpServer
  let room = '';
  let paused = false;
  let rxBytes = 0, txBytes = 0;
  let enc = 'utf8';
  let autoScroll = true;
  const UI_KEY = 'linkcom_ui_link';
  function loadUiCfg() {
    try {
      const s = JSON.parse(localStorage.getItem(UI_KEY) || '{}');
      if (typeof s.enc === 'string') enc = s.enc;
      if (typeof s.modeText === 'boolean') $('modeText').checked = s.modeText;
      if (typeof s.modeHex === 'boolean') $('modeHex').checked = s.modeHex;
      if (typeof s.modeTs === 'boolean') $('modeTs').checked = s.modeTs;
      if (typeof s.autoScroll === 'boolean') { autoScroll = s.autoScroll; $('autoScroll').checked = autoScroll; }
      if (typeof s.sendHex === 'boolean') $('sendHex').checked = s.sendHex;
      if (typeof s.sendCRLF === 'boolean') $('sendCRLF').checked = s.sendCRLF;
    } catch (e) {}
  }
  function saveUiCfg() {
    try {
      localStorage.setItem(UI_KEY, JSON.stringify({
        enc,
        modeText: $('modeText').checked,
        modeHex: $('modeHex').checked,
        modeTs: $('modeTs').checked,
        autoScroll,
        sendHex: $('sendHex').checked,
        sendCRLF: $('sendCRLF').checked,
      }));
    } catch (e) {}
  }

  const $ = (id) => document.getElementById(id);
  const term = $('terminal');
  const hint = $('hint');
  const hintClose = $('hintClose');
  if (hintClose) hintClose.onclick = () => hint.classList.add('hidden');
  const wsDot = $('wsDot'), wsStat = $('wsStat');
  const roomStat = $('roomStat'), shareStat = $('shareStat');
  const rxStat = $('rxStat'), txStat = $('txStat');

  function b64ToBuf(b64) {
    const bin = atob(b64); const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    return arr;
  }
  function bufToB64(buf) {
    let bin = ''; for (let i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
    return btoa(bin);
  }
  function nowTs() {
    const d = new Date(); const p = (n) => String(n).padStart(2, '0');
    return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${String(d.getMilliseconds()).padStart(3, '0')}`;
  }
  let hintTimer = null;
  function setHint(msg, isErr) {
    if (hintTimer) { clearTimeout(hintTimer); hintTimer = null; }
    if (msg) {
      let t = hint.querySelector('.toast-text');
      if (!t) { t = document.createElement('span'); t.className = 'toast-text'; hint.appendChild(t); }
      t.textContent = msg;
      hint.classList.toggle('err', !!isErr);
      hint.classList.remove('hidden');
      // 非报错信息 1s 后自动关闭; 报错信息保持弹窗, 手动关闭
      if (!isErr) {
        const snap = msg;
        hintTimer = setTimeout(() => { if (t.textContent === snap) hint.classList.add('hidden'); }, 1000);
      }
    } else {
      hint.classList.add('hidden');
    }
  }
  function fmtBytes(n) {
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / 1024 / 1024).toFixed(2) + ' MB';
  }
  function decodeText(buf) { return enc === 'gbk' ? GbkUtil.decodeGbk(buf) : GbkUtil.decodeUtf8(buf); }

  const history = [];
  const MAX_HISTORY = 5000;
  function pushHistory(buf, cls) { history.push({ ts: nowTs(), cls, buf: buf.slice() }); if (history.length > MAX_HISTORY) history.shift(); }
  function hexLines(buf) {
    const parts = [];
    for (let i = 0; i < buf.length; i += 16) {
      const slice = buf.subarray(i, i + 16);
      parts.push(Array.from(slice).map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' '));
    }
    return parts.join('\n');
  }
  // 整段不分行 HEX(界面显示用): 放不下时由 CSS 自然换行, 不强制 16 字节断行
  function hexLine(buf) {
    return Array.from(buf).map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
  }
  // 文本片段(界面显示用): 保留消息内换行, 并在原始换行处追加灰色 ↩︎ 标记
  function textFrag(buf) {
    const frag = document.createDocumentFragment();
    let s = ''; const str = decodeText(buf);
    for (const ch of str) {
      const c = ch.charCodeAt(0);
      if (c === 0x0d || c === 0x0a || (c >= 0x20 && c < 0x7f) || c > 0x7f) s += ch; else s += '.';
    }
    const lines = s.split(/\r\n|\r|\n/);
    lines.forEach((ln, i) => {
      frag.appendChild(document.createTextNode(ln));
      if (i < lines.length - 1) {
        // ↩︎ 放在前一行末尾, 之后才换行
        const e = document.createElement('span'); e.className = 'eol'; e.textContent = '↩︎';
        frag.appendChild(e);
        frag.appendChild(document.createTextNode('\n'));
      }
    });
    return frag;
  }
  function textOf(buf) {
    let s = ''; const str = decodeText(buf);
    for (const ch of str) {
      const c = ch.charCodeAt(0);
      if (c === 0x0d || c === 0x0a || (c >= 0x20 && c < 0x7f) || c > 0x7f) s += ch; else s += '.';
    }
    return s;
  }
  // 按当前显示模式把单条历史渲染为纯文本 (用于导出文件, 始终带时间 + 方向标识)
  function fmtHistoryLine(item, wantText, wantHex) {
    const dir = dirLabel(item.cls);
    if (wantText && wantHex) {
      return `[${item.ts}] ${dir} 文本: ${textOf(item.buf)}\n[${item.ts}] ${dir} HEX: ${hexLines(item.buf).replace(/\n/g, ' ')}`;
    }
    if (wantHex) return `[${item.ts}] ${dir} HEX: ${hexLines(item.buf).replace(/\n/g, ' ')}`;
    return `[${item.ts}] ${dir} 文本: ${textOf(item.buf)}`;
  }
  // 方向标识：本端发出=Link_发送，共享端主动发送=共享端发送，共享端通道来的(回执)=←接收
  function dirLabel(cls) {
    if (cls === 'tx') return '[Link_发送]';
    if (cls === 'stx') return '[共享端发送]';
    return '[←接收]';
  }
  function buildLineEl(item, wantText, wantHex) {
    const wrap = document.createElement('div'); wrap.className = 'line ' + item.cls;
    if ($('modeTs').checked) {
      const ts = document.createElement('span'); ts.className = 'ts'; ts.textContent = item.ts;
      wrap.appendChild(ts);
    }
    const dir = document.createElement('span'); dir.className = 'dir'; dir.textContent = dirLabel(item.cls);
    wrap.appendChild(dir);
    if (wantText && wantHex) {
      const t = document.createElement('span'); t.className = 'pane-text'; t.appendChild(textFrag(item.buf));
      const h = document.createElement('span'); h.className = 'pane-hex hex'; h.textContent = hexLine(item.buf);
      wrap.appendChild(t); wrap.appendChild(h);
    } else if (wantHex) {
      const h = document.createElement('span'); h.className = 'hex'; h.textContent = hexLine(item.buf);
      wrap.appendChild(h);
    } else {
      // 文本模式：保留消息内换行, 行尾灰色 ↩︎ 标记区分"真实换行"与"放不下换行"
      const t = document.createElement('span'); t.className = 'line-text'; t.appendChild(textFrag(item.buf));
      wrap.appendChild(t);
    }
    return wrap;
  }
  function rerender() {
    const wantText = $('modeText').checked, wantHex = $('modeHex').checked;
    term.innerHTML = ''; term.classList.toggle('split', wantText && wantHex);
    for (const item of history) term.appendChild(buildLineEl(item, wantText, wantHex));
    if (autoScroll) term.scrollTop = term.scrollHeight;
  }
  function appendData(buf, cls) {
    if (paused) { pushHistory(buf, cls); return; }
    if (window.sniffer) window.sniffer.feed(buf, cls);  // 快速匹配旁路监听
    const wantText = $('modeText').checked, wantHex = $('modeHex').checked;
    term.appendChild(buildLineEl({ ts: nowTs(), cls, buf }, wantText, wantHex));
    if (autoScroll) term.scrollTop = term.scrollHeight;
    while (term.childElementCount > MAX_HISTORY) term.removeChild(term.firstChild);
  }
  function appendSys(text, cls) {
    if (paused) return;
    const div = document.createElement('div'); div.className = 'line ' + (cls || 'sys');
    if ($('modeTs').checked) {
      const ts = document.createElement('span'); ts.className = 'ts'; ts.textContent = nowTs();
      div.appendChild(ts);
    }
    div.appendChild(document.createTextNode('[系统] ' + text));
    term.appendChild(div);
  }
  // 把共享端下发的串口参数填充到可编辑表单
  function applyRemoteCfg(cfg) {
    if (!cfg) return;
    if (cfg.baudRate != null) $('cfgBaud').value = String(cfg.baudRate);
    if (cfg.dataBits != null) $('cfgData').value = String(cfg.dataBits);
    if (cfg.stopBits != null) $('cfgStop').value = String(cfg.stopBits);
    if (cfg.parity) $('cfgParity').value = cfg.parity;
    if (cfg.flowControl) $('cfgFlow').value = cfg.flowControl;
    if (cfg.encoding) { enc = cfg.encoding; $('cfgEnc').value = cfg.encoding; $('encoding').value = cfg.encoding; }
    rerender();
  }
  // 根据共享端通道类型调整链接端配置面板: TCP 模式隐藏 COM 配置并显示协议名
  function updateShareModeUI(mode) {
    shareMode = mode || 'serial';
    const isSerial = shareMode === 'serial';
    const labels = { serial: '串口 (COM)', tcpClient: 'TCP 客户端', tcpServer: 'TCP 服务器' };
    const protoName = labels[shareMode] || shareMode;
    const protoEl = $('shareProto');
    if (protoEl) protoEl.textContent = protoName;
    // 隐藏/显示 COM 相关配置项
    document.querySelectorAll('.cfg-com').forEach((el) => { el.style.display = isSerial ? '' : 'none'; });
    const comNote = $('cfgComNote');
    if (comNote) comNote.style.display = isSerial ? 'none' : '';
  }
  // 把链接端修改后的参数(含聚合参数)回传给服务器 (再转发给共享端)
  function sendCfgToShare() {
    if (!joined || !wsOpen) { setHint('未连接房间, 无法应用配置', true); return; }
    // 聚合参数无论何种模式都下发, 使共享端按链接端设定的聚合工作
    const agg = {
      flushMs: parseInt($('cfgFlushMs').value, 10) || 0,
      maxBufKb: parseInt($('cfgMaxBuf').value, 10) || 1,
    };
    let msg = { t: 'serial-config', agg, mode: shareMode };
    // 仅串口模式同步 COM 参数
    if (shareMode === 'serial') {
      msg.cfg = {
        baudRate: parseInt($('cfgBaud').value, 10),
        dataBits: parseInt($('cfgData').value, 10),
        stopBits: parseInt($('cfgStop').value, 10),
        parity: $('cfgParity').value,
        flowControl: $('cfgFlow').value,
        encoding: $('cfgEnc').value,
      };
    }
    ws.send(JSON.stringify(msg));
    $('cfgHint').textContent = '已发送配置到共享端';
    appendSys(shareMode === 'serial'
      ? `已请求修改串口参数: ${msg.cfg.baudRate}/${msg.cfg.dataBits}/${msg.cfg.stopBits}/${msg.cfg.parity}/${msg.cfg.flowControl}/${msg.cfg.encoding.toUpperCase()}`
      : `已请求修改聚合参数(共享端为${shareMode === 'tcpClient' ? 'TCP 客户端' : 'TCP 服务器'}, 仅同步聚合): ${agg.flushMs}ms / ${agg.maxBufKb}KB`,
      'sys');
  }

  function wsUrl() { const proto = location.protocol === 'https:' ? 'wss' : 'ws'; const p = location.pathname.replace(/\/[^/]*$/, ''); const base = p && p !== '/' ? p : ''; return `${proto}://${location.host}${base}/ws`; }
  function connectWs() {
    if (ws) { try { ws.close(); } catch {} }
    ws = new WebSocket(wsUrl());
    ws.onopen = () => {
      wsOpen = true; wsDot.className = 'status-dot warn'; wsStat.textContent = '已连服务器';
      if (room) doJoin();
    };
    ws.onclose = () => {
      wsOpen = false; joined = false; sharePortOpen = false; wsDot.className = 'status-dot'; wsStat.textContent = '断开, 重连中…';
      shareStat.textContent = '离线'; updateSendState();
      if (room) setTimeout(connectWs, 2000);
    };
    ws.onerror = () => {};
    ws.onmessage = (ev) => { let m; try { m = JSON.parse(ev.data); } catch { return; } handleServer(m); };
  }
  function doJoin() { if (!wsOpen) return; ws.send(JSON.stringify({ t: 'join', room, role: 'link', pwd: $('pwd').value })); }
  // 综合判断链接端当前是否允许发送: 已加入房间 + 共享端在线 + 共享端串口已打开
  function updateSendState() {
    const canSend = joined && wsOpen && shareOnline && sharePortOpen;
    $('sendText').disabled = !canSend; $('btnSend').disabled = !canSend;
    $('sendHex').disabled = !canSend; $('sendCRLF').disabled = !canSend;
    $('sendText').placeholder = canSend ? '输入要发送到共享串口的内容 (Enter 发送, Shift+Enter 换行)'
      : '等待共享端打开串口后, 此处可发送';
    // 共享端状态文案: 区分"在线但未打开串口"
    if (!shareOnline) shareStat.textContent = '离线';
    else if (!sharePortOpen) shareStat.textContent = '串口未打开';
    else shareStat.textContent = '在线';
  }
  function handleServer(m) {
    switch (m.t) {
      case 'ok':
        joined = true; wsDot.className = 'status-dot on'; wsStat.textContent = '已连接房间';
        shareOnline = !!m.peers.share;
        sharePortOpen = !!(m.peers && m.peers.sharePortOpen);
        updateSendState(); appendSys(`已进入房间 ${m.room}`);
        if (!shareOnline) appendSys('当前共享端未连接串口或已停止共享, 暂时无法发送', 'sys');
        else if (!sharePortOpen) appendSys('共享端已连接, 但串口尚未打开, 请让其打开串口后再发送', 'sys');
        break;
      case 'err':
        setHint('错误: ' + m.msg, true); appendSys('错误: ' + m.msg, 'err');
        break;
      case 'peers':
        shareOnline = !!m.share;
        sharePortOpen = !!(m.sharePortOpen);
        updateSendState();
        if (!shareOnline) setHint('共享端已停止共享或断开, 暂时无法发送', false);
        else if (!sharePortOpen) setHint('共享端串口未打开, 暂无法发送, 请先让其打开串口', false);
        else setHint('');
        break;
      case 'serial-data':
        if (m.from === 'share') {
          const buf = b64ToBuf(m.buf);
          rxBytes += buf.length; rxStat.textContent = fmtBytes(rxBytes);
          // 来自共享端: kind='tx' 为共享端主动发送(显示为"共享端发送")，否则为通道回执(←接收)
          const isTx = m.kind === 'tx';
          pushHistory(buf, isTx ? 'stx' : 'rx'); appendData(buf, isTx ? 'stx' : 'rx');
        }
        break;
      case 'serial-config':
        if (m.from === 'share') {
          if (m.mode) updateShareModeUI(m.mode);
          if (m.cfg) applyRemoteCfg(m.cfg);
          if (m.agg) {
            $('cfgFlushMs').value = m.agg.flushMs;
            $('cfgMaxBuf').value = m.agg.maxBufKb;
          }
          // 同步串口打开状态(共享端下发完整配置时一并携带)
          if (typeof m.portOpen === 'boolean') { sharePortOpen = m.portOpen; updateSendState(); }
          appendSys('已同步共享端配置', 'sys');
          rerender();
        }
        break;
      case 'serial-state':
        // 共享端串口实时打开/关闭状态
        if (typeof m.portOpen === 'boolean') {
          sharePortOpen = m.portOpen;
          updateSendState();
          if (!sharePortOpen && shareOnline) setHint('共享端串口已关闭, 暂无法发送, 请先让其打开串口', false);
          else if (sharePortOpen && shareOnline) setHint('');
        }
        break;
      case 'closed':
        shareOnline = false; sharePortOpen = false;
        appendSys('共享端断开: ' + (m.reason || ''), 'sys'); updateSendState();
        setHint('共享端已停止共享, 发送失败: 对方已断开连接, 无法下发到串口', true);
        break;
    }
  }

  function doConnect() {
    room = $('room').value.trim();
    if (!room) { setHint('请填写房间码', true); return; }
    if (!wsOpen) connectWs(); else doJoin();
    $('btnConnect').textContent = '重新连接';
  }

  function doSend() {
    const txt = $('sendText').value;
    if (!txt && !$('sendHex').checked) return;
    if (!joined || !wsOpen) { setHint('未连接到房间', true); return; }
    if (!shareOnline) { setHint('发送失败: 共享端已停止共享或断开, 无法下发到串口', true); return; }
    if (!sharePortOpen) { setHint('发送失败: 共享端串口未打开, 请先让其打开串口', true); return; }
    let buf;
    if ($('sendHex').checked) {
      const clean = txt.replace(/[^0-9a-fA-F]/g, '');
      if (clean.length % 2 !== 0) { setHint('HEX 格式错误: 字节数必须为偶数', true); return; }
      buf = new Uint8Array(clean.length / 2);
      for (let i = 0; i < buf.length; i++) buf[i] = parseInt(clean.substr(i * 2, 2), 16);
    } else {
      let s = txt;
      if ($('sendCRLF').checked) s += '\r\n';
      buf = enc === 'gbk' ? GbkUtil.encodeGbk(s) : GbkUtil.encodeUtf8(s);
    }
    ws.send(JSON.stringify({ t: 'serial-data', buf: bufToB64(buf) }));
    txBytes += buf.length; txStat.textContent = fmtBytes(txBytes);
    pushHistory(buf, 'tx'); appendData(buf, 'tx');
    setHint('');
  }

  // ---------- 快速发送 (QuickSend) ----------
  function quickItemToBuf(it) {
    if (it.hex) {
      const clean = it.data.replace(/[^0-9a-fA-F]/g, '');
      if (clean.length % 2 !== 0) throw new Error('HEX 格式错误: 字节数必须为偶数');
      const buf = new Uint8Array(clean.length / 2);
      for (let i = 0; i < buf.length; i++) buf[i] = parseInt(clean.substr(i * 2, 2), 16);
      return buf;
    }
    let s = it.data;
    if (it.crlf) s += '\r\n';
    return enc === 'gbk' ? GbkUtil.encodeGbk(s) : GbkUtil.encodeUtf8(s);
  }
  const qs = new QuickSend({
    storageKey: 'linkcom_quicksend_link',
    defaultsUrl: 'quick-send-defaults.json',
    hint: setHint,
    onSend: (it) => {
      if (!joined || !wsOpen) { setHint('快速发送失败 (' + it.name + '): 未连接到房间', true); return; }
      if (!shareOnline) { setHint('快速发送失败 (' + it.name + '): 共享端已停止共享或断开, 无法下发到串口', true); return; }
      if (!sharePortOpen) { setHint('快速发送失败 (' + it.name + '): 共享端串口未打开, 请先让其打开串口', true); return; }
      let buf;
      try { buf = quickItemToBuf(it); }
      catch (e) { setHint('快速发送失败 (' + it.name + '): ' + e.message, true); return; }
      ws.send(JSON.stringify({ t: 'serial-data', buf: bufToB64(buf) }));
      txBytes += buf.length; txStat.textContent = fmtBytes(txBytes);
      pushHistory(buf, 'tx'); appendData(buf, 'tx');
    },
  });
  qs.init();

  // ---------- 历史导出 ----------
  function exportHistory() {
    if (!history.length) { setHint('暂无历史记录可导出', true); return; }
    const mt = $('modeText').checked, mh = $('modeHex').checked;
    const lines = history.map((h) => fmtHistoryLine(h, mt, mh));
    const blob = new Blob([lines.join('\n') + '\n'], { type: 'text/plain; charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'linkcom-history-' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.txt';
    a.click();
    URL.revokeObjectURL(url);
    setHint('已导出历史记录 (' + history.length + ' 条)');
  }

  // 统一渲染串口参数下拉（共享端与链接端共用 serial-config.js，确保一致性）
  if (window.SERIAL_UI) {
    SERIAL_UI.fillLink();
    SERIAL_UI.fillEncoding();
    enc = SERIAL_UI.DEFAULTS.encoding;
  }
  // 恢复界面配置(显示/发送选项)
  loadUiCfg();

  // 事件绑定
  $('btnConnect').onclick = doConnect;
  $('btnSend').onclick = doSend;
  $('sendText').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); doSend(); } });
  $('modeText').onchange = () => { rerender(); saveUiCfg(); };
  $('modeHex').onchange = () => { rerender(); saveUiCfg(); };
  $('modeTs').onchange = () => { rerender(); saveUiCfg(); };
  $('encoding').onchange = () => { enc = $('encoding').value; rerender(); saveUiCfg(); };
  $('autoScroll').onchange = () => { autoScroll = $('autoScroll').checked; saveUiCfg(); };
  $('sendHex').onchange = saveUiCfg;
  $('sendCRLF').onchange = saveUiCfg;
  $('btnPause').onclick = () => { paused = !paused; $('btnPause').textContent = paused ? '继续' : '暂停'; };
  $('btnClear').onclick = () => { history.length = 0; term.innerHTML = ''; };
  $('btnExportHistory').onclick = exportHistory;
  $('btnApplyCfg').onclick = sendCfgToShare;

  // 房间配置面板折叠/展开 (移动端空间优化)
  (function () {
    const bar = $('configBar');
    const head = $('configHead');
    const sum = $('configSummary');
    if (!bar || !head) return;
    function updateSummary() {
      const r = ($('room').value || '').trim();
      sum.textContent = r ? '房间 ' + r : '未设置房间';
    }
    head.addEventListener('click', () => {
      bar.classList.toggle('collapsed');
      head.querySelector('.chev').textContent = bar.classList.contains('collapsed') ? '▸' : '▾';
    });
    // 窄屏默认收起
    if (window.innerWidth <= 768) {
      bar.classList.add('collapsed');
      head.querySelector('.chev').textContent = '▸';
    }
    $('room').addEventListener('input', updateSummary);
    updateSummary();
  })();

  setHint('输入共享端提供的房间码与密码(若有), 点击连接即可远程调试串口。');
  updateSendState();

  // 支持从共享端切换过来时通过 ?room=&pwd= 自动预填并连接同一房间
  const qp = new URLSearchParams(location.search);
  const qRoom = qp.get('room'), qPwd = qp.get('pwd');
  if (qRoom) $('room').value = qRoom;
  if (qPwd) $('pwd').value = qPwd;
  // 同步折叠头摘要
  const _sum = $('configSummary'); if (_sum) _sum.textContent = '房间 ' + (qRoom || '');
  // 快速匹配模块 (独立, 可移除)
  window.sniffer = new Sniffer({ storageKey: 'linkcom_sniffer_link', hint: setHint });
  sniffer.init();

  connectWs();
  if (qRoom) {
    setHint('正在连接共享房间 ' + qRoom + ' …');
    // 等待 WebSocket 连上后由 onopen 自动 doJoin; 若已连上则主动连接
    if (wsOpen) doConnect();
    else {
      const _open = ws.onopen;
      ws.onopen = () => { if (_open) _open(); doConnect(); };
    }
  }
})();
