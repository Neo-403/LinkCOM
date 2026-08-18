/* LinkCOM 链接端逻辑: 手机/电脑浏览器经 WebSocket 远程收发共享串口数据
 * 改进: 文本+HEX 多选分屏; GBK/UTF-8; 历史重渲染; 连接前禁用发送
 */
(function () {
  'use strict';

  let ws = null, wsOpen = false, joined = false;
  let shareOnline = false;           // 共享端是否在线 (可发送的前提)
  let room = '';
  let paused = false;
  let rxBytes = 0, txBytes = 0;
  let enc = 'utf8';

  const $ = (id) => document.getElementById(id);
  const term = $('terminal');
  const hint = $('hint');
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
  function setHint(msg, isErr) { hint.textContent = msg || ''; hint.className = 'hint' + (isErr ? ' err' : ''); }
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
  // 方向标识：本端发出=Link_发送，共享端通道来的(回执/发送)=←接收
  function dirLabel(cls) {
    if (cls === 'tx') return '[Link_发送]';
    return '[←接收]';
  }
  function buildLineEl(item, wantText, wantHex) {
    const wrap = document.createElement('div'); wrap.className = 'line ' + item.cls;
    const ts = document.createElement('span'); ts.className = 'ts'; ts.textContent = item.ts;
    const dir = document.createElement('span'); dir.className = 'dir'; dir.textContent = dirLabel(item.cls);
    wrap.appendChild(ts); wrap.appendChild(dir);
    if (wantText && wantHex) {
      const t = document.createElement('span'); t.className = 'pane-text'; t.textContent = textOf(item.buf);
      const h = document.createElement('span'); h.className = 'pane-hex hex'; h.textContent = hexLines(item.buf);
      wrap.appendChild(t); wrap.appendChild(h);
    } else if (wantHex) {
      const h = document.createElement('span'); h.className = 'hex'; h.textContent = hexLines(item.buf);
      wrap.appendChild(h);
    } else { wrap.appendChild(document.createTextNode(textOf(item.buf).replace(/\r\n?/g, ' '))); }
    return wrap;
  }
  function rerender() {
    const wantText = $('modeText').checked, wantHex = $('modeHex').checked;
    term.innerHTML = ''; term.classList.toggle('split', wantText && wantHex);
    for (const item of history) term.appendChild(buildLineEl(item, wantText, wantHex));
    if ($('autoScroll').checked) term.scrollTop = term.scrollHeight;
  }
  function appendData(buf, cls) {
    if (paused) { pushHistory(buf, cls); return; }
    const wantText = $('modeText').checked, wantHex = $('modeHex').checked;
    term.appendChild(buildLineEl({ ts: nowTs(), cls, buf }, wantText, wantHex));
    if ($('autoScroll').checked) term.scrollTop = term.scrollHeight;
    while (term.childElementCount > MAX_HISTORY) term.removeChild(term.firstChild);
  }
  function appendSys(text, cls) {
    if (paused) return;
    const div = document.createElement('div'); div.className = 'line ' + (cls || 'sys');
    const ts = document.createElement('span'); ts.className = 'ts'; ts.textContent = nowTs();
    div.appendChild(ts); div.appendChild(document.createTextNode('[系统] ' + text));
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
  // 把链接端修改后的参数回传给服务器 (再转发给共享端)
  function sendCfgToShare() {
    if (!joined || !wsOpen) { setHint('未连接房间, 无法应用配置', true); return; }
    const cfg = {
      baudRate: parseInt($('cfgBaud').value, 10),
      dataBits: parseInt($('cfgData').value, 10),
      stopBits: parseInt($('cfgStop').value, 10),
      parity: $('cfgParity').value,
      flowControl: $('cfgFlow').value,
      encoding: $('cfgEnc').value,
    };
    ws.send(JSON.stringify({ t: 'serial-config', cfg }));
    $('cfgHint').textContent = '已发送配置到共享端, 等待其应用…';
    appendSys(`已请求修改串口参数: ${cfg.baudRate}/${cfg.dataBits}/${cfg.stopBits}/${cfg.parity}/${cfg.flowControl}/${cfg.encoding.toUpperCase()}`, 'sys');
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
      wsOpen = false; joined = false; wsDot.className = 'status-dot'; wsStat.textContent = '断开, 重连中…';
      shareStat.textContent = '离线'; setSendEnabled(false);
      if (room) setTimeout(connectWs, 2000);
    };
    ws.onerror = () => {};
    ws.onmessage = (ev) => { let m; try { m = JSON.parse(ev.data); } catch { return; } handleServer(m); };
  }
  function doJoin() { if (!wsOpen) return; ws.send(JSON.stringify({ t: 'join', room, role: 'link', pwd: $('pwd').value })); }
  function setSendEnabled(on) {
    $('sendText').disabled = !on; $('btnSend').disabled = !on;
    $('sendHex').disabled = !on; $('sendCRLF').disabled = !on;
    $('sendText').placeholder = on ? '输入要发送到共享串口的内容 (Enter 发送, Shift+Enter 换行)'
      : '先输入房间码并点击「连接房间」, 连接成功后此处可发送';
  }
  function handleServer(m) {
    switch (m.t) {
      case 'ok':
        joined = true; wsDot.className = 'status-dot on'; wsStat.textContent = '已连接房间';
        shareOnline = !!m.peers.share;
        shareStat.textContent = shareOnline ? '在线' : '离线';
        setSendEnabled(shareOnline); appendSys(`已进入房间 ${m.room}`);
        if (!shareOnline) appendSys('当前共享端未连接串口或已停止共享, 暂时无法发送', 'sys');
        break;
      case 'err':
        setHint('错误: ' + m.msg, true); appendSys('错误: ' + m.msg, 'err');
        break;
      case 'peers':
        shareOnline = !!m.share;
        shareStat.textContent = shareOnline ? '在线' : '离线';
        setSendEnabled(shareOnline);
        if (!shareOnline) setHint('共享端已停止共享或断开, 暂时无法发送', false);
        else setHint('');
        break;
      case 'serial-data':
        if (m.from === 'share') {
          const buf = b64ToBuf(m.buf);
          rxBytes += buf.length; rxStat.textContent = fmtBytes(rxBytes);
          // 来自共享端通道的数据（串口回执 / 共享端发送）
          pushHistory(buf, 'rx'); appendData(buf, 'rx');
        }
        break;
      case 'serial-config':
        if (m.cfg) applyRemoteCfg(m.cfg);
        break;
      case 'closed':
        shareOnline = false;
        appendSys('共享端断开: ' + (m.reason || ''), 'sys'); shareStat.textContent = '离线'; setSendEnabled(false);
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
    $('sendText').value = ''; setHint('');
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

  // 事件绑定
  $('btnConnect').onclick = doConnect;
  $('btnSend').onclick = doSend;
  $('sendText').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); doSend(); } });
  $('modeText').onchange = rerender;
  $('modeHex').onchange = rerender;
  $('encoding').onchange = () => { enc = $('encoding').value; rerender(); };
  $('btnPause').onclick = () => { paused = !paused; $('btnPause').textContent = paused ? '继续' : '暂停'; };
  $('btnClear').onclick = () => { history.length = 0; term.innerHTML = ''; };
  $('btnExportHistory').onclick = exportHistory;
  $('btnApplyCfg').onclick = sendCfgToShare;

  setHint('输入共享端提供的房间码与密码(若有), 点击连接即可远程调试串口。');
  setSendEnabled(false);

  // 支持从共享端切换过来时通过 ?room=&pwd= 自动预填并连接同一房间
  const qp = new URLSearchParams(location.search);
  const qRoom = qp.get('room'), qPwd = qp.get('pwd');
  if (qRoom) $('room').value = qRoom;
  if (qPwd) $('pwd').value = qPwd;
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
