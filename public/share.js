/* LinkCOM 共享端逻辑: Web Serial 读本地串口 + WebSocket 转发
 * 改进: 打开串口/共享 独立; 文本+HEX 多选分屏; GBK/UTF-8; 历史重渲染; 房间码随机
 */
(function () {
  'use strict';

  // ---------- 状态 ----------
  let port = null;
  let reader = null, writer = null;
  let keepReading = false, readLoopRunning = false, portOpen = false;
  let ws = null, wsOpen = false, joined = false;
  let room = '';
  let paused = false;
  let rxBytes = 0, txBytes = 0;
  let enc = 'utf8';                  // utf8 | gbk
  const history = [];                // { ts, cls, buf:Uint8Array }
  const MAX_HISTORY = 5000;

  // ---------- DOM ----------
  const $ = (id) => document.getElementById(id);
  const term = $('terminal');
  const hint = $('hint');
  const wsDot = $('wsDot'), wsStat = $('wsStat');
  const roomStat = $('roomStat'), peerStat = $('peerStat');
  const rxStat = $('rxStat'), txStat = $('txStat');

  // ---------- 工具 ----------
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
  function decodeText(buf) {
    return enc === 'gbk' ? GbkUtil.decodeGbk(buf) : GbkUtil.decodeUtf8(buf);
  }

  // ---------- 历史 + 渲染 ----------
  function pushHistory(buf, cls) {
    history.push({ ts: nowTs(), cls, buf: buf.slice() });
    if (history.length > MAX_HISTORY) history.shift();
  }
  function hexLines(buf) {
    const parts = [];
    for (let i = 0; i < buf.length; i += 16) {
      const slice = buf.subarray(i, i + 16);
      parts.push(Array.from(slice).map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' '));
    }
    return parts.join('\n');
  }
  function textOf(buf) {
    // 文本模式下保留 \r\n, 其它不可打印用 .
    let s = ''; const str = decodeText(buf);
    for (const ch of str) {
      const c = ch.charCodeAt(0);
      if (c === 0x0d || c === 0x0a || (c >= 0x20 && c < 0x7f) || c > 0x7f) s += ch;
      else s += '.';
    }
    return s;
  }
  // 方向标识：本端发出=→发送，串口回执=←接收，链接端发来=Link_发送
  function dirLabel(cls) {
    if (cls === 'tx') return '[→发送]';
    if (cls === 'ltx') return '[Link_发送]';
    return '[←接收]';
  }
  function buildLineEl(item, wantText, wantHex) {
    const wrap = document.createElement('div');
    wrap.className = 'line ' + item.cls;
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
    } else {
      // 文本模式：回车换行折叠为空格，保证单行紧凑显示，复制格式与链接端一致
      wrap.appendChild(document.createTextNode(textOf(item.buf).replace(/\r\n?/g, ' ')));
    }
    return wrap;
  }
  function rerender() {
    const wantText = $('modeText').checked, wantHex = $('modeHex').checked;
    term.innerHTML = '';
    term.classList.toggle('split', wantText && wantHex);
    for (const item of history) term.appendChild(buildLineEl(item, wantText, wantHex));
    if ($('autoScroll').checked) term.scrollTop = term.scrollHeight;
  }
  function appendData(buf, cls) {
    if (paused) { pushHistory(buf, cls); return; }
    const wantText = $('modeText').checked, wantHex = $('modeHex').checked;
    const el = buildLineEl({ ts: nowTs(), cls, buf }, wantText, wantHex);
    term.appendChild(el);
    if ($('autoScroll').checked) term.scrollTop = term.scrollHeight;
    // 限制 DOM 行数
    while (term.childElementCount > MAX_HISTORY) term.removeChild(term.firstChild);
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

  // ---------- WebSocket ----------
  function wsUrl() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    // 从当前页面路径推导子路径前缀, 支持 Nginx 反代到子路径 (如 /linkcom)
    const p = location.pathname.replace(/\/[^/]*$/, ''); // 去掉文件名, 得到 "/linkcom" 或 ""
    const base = p && p !== '/' ? p : '';
    return `${proto}://${location.host}${base}/ws`;
  }
  function connectWs() {
    if (ws) { try { ws.close(); } catch {} }
    ws = new WebSocket(wsUrl());
    ws.onopen = () => {
      wsOpen = true;
      if (joined || room) { wsDot.className = 'status-dot warn'; wsStat.textContent = '已连服务器'; doJoin(); }
      else { wsDot.className = 'status-dot warn'; wsStat.textContent = '已连服务器, 未共享'; }
    };
    ws.onclose = () => {
      wsOpen = false; joined = false;
      wsDot.className = 'status-dot'; wsStat.textContent = '服务器断开, 重连中…';
      peerStat.textContent = '0';
      if (room) setTimeout(connectWs, 2000);
    };
    ws.onerror = () => {};
    ws.onmessage = (ev) => { let m; try { m = JSON.parse(ev.data); } catch { return; } handleServer(m); };
  }
  function doJoin() {
    if (!wsOpen) return;
    ws.send(JSON.stringify({ t: 'join', room, role: 'share', pwd: $('pwd').value }));
  }
  function handleServer(m) {
    switch (m.t) {
      case 'ok':
        joined = true;
        wsDot.className = 'status-dot on'; wsStat.textContent = '共享中';
        roomStat.textContent = m.room; peerStat.textContent = m.peers.links;
        appendSys(`已进入共享房间 ${m.room}`);
        // 立即下发当前串口参数, 让链接端马上看到
        if (wsOpen) ws.send(JSON.stringify({ t: 'serial-config', cfg: serialCfg() }));
        break;
      case 'err':
        setHint('服务器错误: ' + m.msg, true); appendSys('错误: ' + m.msg, 'err');
        break;
      case 'peers':
        peerStat.textContent = m.links;
        break;
      case 'serial-data':
        if (m.from === 'link') {
          const buf = b64ToBuf(m.buf);
          writeSerial(buf);
          txBytes += buf.length; txStat.textContent = fmtBytes(txBytes);
          pushHistory(buf, 'ltx'); appendData(buf, 'ltx');
        }
        break;
      case 'closed':
        appendSys('链接端断开: ' + (m.reason || ''), 'sys');
        break;
      case 'serial-config':
        if (m.from === 'link' && m.cfg) applyRemoteCfg(m.cfg);
        break;
    }
  }
  // 链接端请求修改串口参数: 更新本地表单并重启串口 (Web Serial 打开后不能直接改参数)
  async function applyRemoteCfg(cfg) {
    // 只取 Web Serial 支持的合法参数, 避免非法枚举导致 open() 抛错使串口断开
    if (cfg.baudRate != null) $('baud').value = cfg.baudRate;
    if (cfg.dataBits != null) $('dbits').value = cfg.dataBits;
    if (cfg.stopBits != null) $('sbits').value = cfg.stopBits;
    if (cfg.parity) $('parity').value = String(cfg.parity).toLowerCase();
    if (cfg.flowControl) $('flow').value = String(cfg.flowControl).toLowerCase();
    if (cfg.encoding) enc = cfg.encoding;
    if (joined && wsOpen) ws.send(JSON.stringify({ t: 'serial-config', cfg: serialCfg() }));
    appendSys(`链接端请求修改串口参数: ${cfg.baudRate}/${cfg.dataBits}/${cfg.stopBits}/${cfg.parity}/${cfg.flowControl}/${cfg.encoding.toUpperCase()}`, 'sys');
    if (portOpen) {
      const err = validateSerialOpts();
      if (err) { appendSys('未重开串口: ' + err + '。请在链接端选择受支持的参数后重试', 'err'); return; }
      appendSys('正在按新参数重开串口…', 'sys');
      await closePort();
      // 等待底层串口彻底释放, 避免 close 未完成就 open 造成异常断开
      await new Promise((r) => setTimeout(r, 80));
      await openPort();
      if (portOpen) appendSys('串口已按新参数重新打开', 'sys');
      else appendSys('串口重开失败, 请手动点击「打开串口」', 'err');
    }
  }
  function appendSys(text, cls) {
    if (paused) return;
    const div = document.createElement('div'); div.className = 'line ' + (cls || 'sys');
    const ts = document.createElement('span'); ts.className = 'ts'; ts.textContent = nowTs();
    div.appendChild(ts); div.appendChild(document.createTextNode('[系统] ' + text));
    term.appendChild(div);
  }

  // ---------- Web Serial ----------
  function serialSupported() { return 'serial' in navigator; }
  // 校验 Web Serial API 实际支持的串口参数, 不支持的直接提示而非静默断开
  function validateSerialOpts() {
    const dbits = parseInt($('dbits').value, 10);
    const parity = $('parity').value;
    const flow = $('flow').value;
    if (!(dbits >= 5 && dbits <= 8)) return `数据位 ${dbits} 不被浏览器支持 (仅支持 5~8)`;
    if (!['none', 'odd', 'even'].includes(parity)) return `校验位 ${parity} 不被当前浏览器 Web Serial 支持 (仅支持 None/Odd/Even)`;
    if (flow === 'software') return `流控 XON/XOFF(软件流控) 不被当前浏览器 Web Serial 支持`;
    return null;
  }
  async function pickPort() {
    if (!serialSupported()) { setHint('当前浏览器不支持 Web Serial API。请用桌面版 Chrome/Edge (https)。', true); return; }
    try {
      port = await navigator.serial.requestPort();
      const info = port.getInfo();
      let name = '已选串口 ✓';
      if (info.usbVendorId) name = `USB#${info.usbVendorId.toString(16)}:${info.usbProductId ? info.usbProductId.toString(16) : '??'} ✓`;
      $('btnPick').textContent = name;
      setHint('已选择串口 (浏览器出于安全不暴露 COM 口号, 以 USB 标识显示)。');
    } catch (e) { setHint('选择串口失败: ' + e.message, true); }
  }
  async function openPort() {
    if (!serialSupported()) { setHint('浏览器不支持 Web Serial, 无法打开', true); return; }
    if (!port) { setHint('请先选择 COM 口', true); return; }
    const err = validateSerialOpts();
    if (err) { setHint('无法打开串口: ' + err, true); appendSys('无法打开串口: ' + err, 'err'); return; }
    try {
      await port.open({
        baudRate: parseInt($('baud').value, 10),
        dataBits: parseInt($('dbits').value, 10),
        stopBits: parseInt($('sbits').value, 10),
        parity: $('parity').value,
        flowControl: $('flow').value === 'hardware' ? 'hardware' : undefined,
      });
      writer = port.writable.getWriter();
      portOpen = true; keepReading = true; readLoopRunning = false;
      readLoop();
      $('btnOpen').textContent = '关闭串口';
      $('btnOpen').classList.remove('teal');
      appendSys(`串口已打开 ${$('baud').value} ${$('dbits').value}${$('parity').value[0].toUpperCase()}${$('sbits').value}`);
      // 已共享则通知参数变更
      if (joined && wsOpen) ws.send(JSON.stringify({ t: 'serial-config', cfg: serialCfg() }));
    } catch (e) { setHint('打开串口失败: ' + e.message, true); }
  }
  async function closePort() {
    keepReading = false;
    try { if (reader) await reader.cancel(); } catch {}
    try { if (writer) writer.releaseLock(); } catch {}
    try { if (port) await port.close(); } catch {}
    portOpen = false; writer = null;
    $('btnOpen').textContent = '打开串口';
    $('btnOpen').classList.add('teal');
    appendSys('串口已关闭');
  }
  function serialCfg() {
    return { baudRate: $('baud').value, dataBits: $('dbits').value, stopBits: $('sbits').value,
      parity: $('parity').value, flowControl: $('flow').value, encoding: enc };
  }
  async function readLoop() {
    if (readLoopRunning) return;
    readLoopRunning = true;
    while (keepReading && port && port.readable) {
      reader = port.readable.getReader();
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          if (value && value.length) {
            rxBytes += value.length; rxStat.textContent = fmtBytes(rxBytes);
            pushHistory(value, 'rx'); appendData(value, 'rx');
            if (wsOpen && joined) ws.send(JSON.stringify({ t: 'serial-data', buf: bufToB64(value), src: 'share' }));
          }
        }
      } catch (e) { appendSys('读串口: ' + e.message, 'err'); }
      finally { try { reader.releaseLock(); } catch {} }
    }
    readLoopRunning = false;
  }
  async function writeSerial(buf) {
    if (!portOpen) { setHint('串口未打开, 无法发送', true); return; }
    if (!writer) { try { writer = port.writable.getWriter(); } catch { return; } }
    try { await writer.write(buf); } catch (e) { appendSys('写入串口失败: 串口可能已关闭或被释放, 请重新打开串口', 'err'); }
  }

  // ---------- 共享控制 ----------
  function startShare() {
    room = $('room').value.trim() || room;
    if (!room) { setHint('房间码不能为空', true); return; }
    $('room').value = room;
    if (!wsOpen) connectWs();
    else doJoin();
    $('btnShare').textContent = '停止共享';
    $('btnShare').onclick = stopShare;
  }
  function stopShare() {
    if (ws && wsOpen) ws.send(JSON.stringify({ t: 'bye' }));
    joined = false;
    wsDot.className = 'status-dot warn'; wsStat.textContent = '已连服务器, 未共享';
    roomStat.textContent = '-';
    $('btnShare').textContent = '开始共享';
    // 统一渲染串口参数下拉（共享端与链接端共用 serial-config.js，确保一致性）
  if (window.SERIAL_UI) {
    SERIAL_UI.fillShare();
    SERIAL_UI.fillEncoding();
    enc = SERIAL_UI.DEFAULTS.encoding;
  }

  $('btnShare').onclick = startShare;
    appendSys('已停止共享');
  }

  // ---------- 发送 ----------
  function doSend() {
    const txt = $('sendText').value;
    if (!txt && !$('sendHex').checked) return;
    if (!portOpen) { setHint('串口未打开, 无法发送', true); return; }
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
    writeSerial(buf);
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
    storageKey: 'linkcom_quicksend_share',
    defaultsUrl: 'quick-send-defaults.json',
    hint: setHint,
    onSend: (it) => {
      if (!portOpen) { setHint('串口未打开, 无法发送: ' + it.name, true); return; }
      let buf;
      try { buf = quickItemToBuf(it); }
      catch (e) { setHint('快速发送失败 (' + it.name + '): ' + e.message, true); return; }
      writeSerial(buf);
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

  // ---------- 事件绑定 ----------
  $('btnPick').onclick = pickPort;
  $('btnOpen').onclick = () => { if (portOpen) closePort(); else openPort(); };
  // 统一渲染串口参数下拉（共享端与链接端共用 serial-config.js，确保一致性）
  if (window.SERIAL_UI) {
    SERIAL_UI.fillShare();
    SERIAL_UI.fillEncoding();
    enc = SERIAL_UI.DEFAULTS.encoding;
  }

  // 右上「切换到链接端」：新开标签页打开 link.html, 并带上当前房间码/密码, 方便直接连接同一房间 (保留本页)
  (function () {
    const sw = $('switchLink');
    if (!sw) return;
    sw.addEventListener('click', (e) => {
      e.preventDefault();
      const params = new URLSearchParams();
      const r = $('room').value.trim();
      const p = $('pwd').value.trim();
      if (r) params.set('room', r);
      if (p) params.set('pwd', p);
      const q = params.toString();
      // 新开窗口, 保留当前共享端页面
      window.open('link.html' + (q ? '?' + q : ''), '_blank', 'noopener');
    });
  })();

  // 分享房间链接：生成含 room+pwd 的 link.html 链接, 点击复制给对端, 对端打开即可直接进入房间
  (function () {
    const btn = $('btnShareLink');
    if (!btn) return;
    btn.addEventListener('click', async () => {
      const r = $('room').value.trim();
      if (!r) { alert('请先填写并连接房间码后再分享链接'); return; }
      const p = $('pwd').value.trim();
      const params = new URLSearchParams();
      params.set('room', r);
      if (p) params.set('pwd', p);
      const url = location.origin + location.pathname.replace(/share\.html$/, '') + 'link.html?' + params.toString();
      try {
        await navigator.clipboard.writeText(url);
        const old = btn.textContent;
        btn.textContent = '已复制链接 ✓';
        setTimeout(() => { btn.textContent = old; }, 1500);
        appendSys('已复制房间链接到剪贴板: ' + url);
      } catch (err) {
        // 剪贴板不可用时降级为 prompt 让用户手动复制
        window.prompt('复制以下房间链接发送给对端:', url);
      }
    });
  })();

  $('btnShare').onclick = startShare;
  $('btnSend').onclick = doSend;
  $('sendText').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); doSend(); }
  });
  $('modeText').onchange = rerender;
  $('modeHex').onchange = rerender;
  $('encoding').onchange = () => { enc = $('encoding').value; rerender(); if (joined && wsOpen) ws.send(JSON.stringify({ t: 'serial-config', cfg: serialCfg() })); };
  $('btnPause').onclick = () => { paused = !paused; $('btnPause').textContent = paused ? '继续' : '暂停'; };
  $('btnClear').onclick = () => { history.length = 0; term.innerHTML = ''; };
  $('btnExportHistory').onclick = exportHistory;
  ['baud', 'dbits', 'sbits', 'parity', 'flow'].forEach((id) => {
    $(id).addEventListener('change', () => {
      if (joined && wsOpen) ws.send(JSON.stringify({ t: 'serial-config', cfg: serialCfg() }));
    });
  });

  // 房间码默认随机
  $('room').value = 'R' + Math.random().toString(36).slice(2, 6).toUpperCase();

  if (!serialSupported()) {
    setHint('当前浏览器不支持 Web Serial API。请用桌面版 Chrome / Edge, 并通过 http(s) 访问。', true);
    $('btnPick').disabled = true; $('btnOpen').disabled = true;
  } else {
    setHint('提示: 手机无法使用 Web Serial, 请在本机电脑用 Chrome/Edge 共享。选 COM 口后可先本地调试, 再点开始共享。');
  }
  connectWs();
})();
