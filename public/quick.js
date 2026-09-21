/* LinkCOM 快速发送模块 (共享端/链接端通用) */
(function () {
  'use strict';

  // 单条结构: { id, name, hex(bool), crlf(bool), data(string), delay(ms, 本条发送后延迟), checked(bool, 是否参与顺序/轮询) }
  function uid() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function defaultItems() {
    return [
      { id: uid(), name: 'AT 测试', hex: false, crlf: true, data: 'AT', delay: 0, checked: true },
      { id: uid(), name: '查询版本', hex: false, crlf: true, data: 'AT+VERSION?', delay: 0, checked: true },
      { id: uid(), name: 'HEX 握手', hex: true, crlf: false, data: 'AA BB CC DD', delay: 0, checked: true },
    ];
  }

  class QuickSend {
    constructor(opts) {
      this.storageKey = opts.storageKey;       // localStorage 键
      this.defaultsUrl = opts.defaultsUrl;     // 服务器默认示例 URL
      this.onSend = opts.onSend;               // (item) => void  实际发送逻辑由调用方注入
      this.hint = opts.hint || function () {}; // (msg, isErr) => void
      this.items = [];
      this.runTimer = null;
      this.runIndex = 0;
      this.runMode = 'stop';                   // 'stop' | 'seq' | 'poll'
      this.editorId = null;                    // 当前编辑的条目 id (null=新增)
      this.dragId = null;
      this.el = {};
    }

    // 初始化: 加载本地 -> 若无则拉默认 -> 渲染
    async init() {
      this.cacheEls();
      this.bindStatic();
      // 不自动加载默认示例: 首次进入为空, 由用户手动「添加」或「重置为默认」
      const local = this.loadLocal();
      if (local && Array.isArray(local.items)) {
        this.items = local.items;
      }
      this.render();
      // 默认展开面板, 方便首次使用直接看到快速发送列表
      if (this.el.panel) this.el.panel.classList.remove('collapsed');
    }

    cacheEls() {
      this.el.panel = document.getElementById('qsPanel');
      this.el.list = document.getElementById('qsList');
      this.el.summary = document.getElementById('qsSummary');
      this.el.runState = document.getElementById('qsRunState');
      this.el.seqBtn = document.getElementById('qsSeqBtn');
      this.el.pollBtn = document.getElementById('qsPollBtn');
      this.el.stopBtn = document.getElementById('qsStopBtn');
      this.el.checkAll = document.getElementById('qsCheckAll');
      this.el.addBtn = document.getElementById('qsAddBtn');
      this.el.impBtn = document.getElementById('qsImportBtn');
      this.el.impFile = document.getElementById('qsImportFile');
      this.el.expBtn = document.getElementById('qsExportBtn');
      this.el.resetBtn = document.getElementById('qsResetBtn');
      this.el.toggleBtn = document.getElementById('qsToggle');
      // 模态框
      this.el.mask = document.getElementById('qsModalMask');
      this.el.name = document.getElementById('qsEditName');
      this.el.data = document.getElementById('qsEditData');
      this.el.hex = document.getElementById('qsEditHex');
      this.el.crlf = document.getElementById('qsEditCrlf');
      this.el.delay = document.getElementById('qsEditDelay');
      this.el.save = document.getElementById('qsEditSave');
      this.el.cancel = document.getElementById('qsEditCancel');
    }

    bindStatic() {
      this.el.addBtn && this.el.addBtn.addEventListener('click', () => this.openEditor(null));
      this.el.seqBtn && this.el.seqBtn.addEventListener('click', () => this.runSeq());
      this.el.pollBtn && this.el.pollBtn.addEventListener('click', () => this.runPoll());
      this.el.stopBtn && this.el.stopBtn.addEventListener('click', () => this.stopRun());
      this.el.expBtn && this.el.expBtn.addEventListener('click', () => this.exportJson());
      this.el.resetBtn && this.el.resetBtn.addEventListener('click', () => this.resetToDefaults());
      this.el.impBtn && this.el.impBtn.addEventListener('click', () => this.el.impFile && this.el.impFile.click());
      this.el.impFile && this.el.impFile.addEventListener('change', (e) => this.importJson(e));
      this.el.toggleBtn && this.el.toggleBtn.addEventListener('click', () => this.toggle());
      // 点击标题栏空白处(非按钮)也可切换整个面板展开/收起
      const qsBar = this.el.panel.querySelector('.qs-bar');
      qsBar && qsBar.addEventListener('click', (e) => {
        if (e.target.closest('button')) return; // 按钮各自处理, 避免误触/双触发
        this.toggle();
      });
      this.el.checkAll && this.el.checkAll.addEventListener('change', () => this.setAllChecked(this.el.checkAll.checked));
      // 模态框
      this.el.save && this.el.save.addEventListener('click', () => this.saveEditor());
      this.el.cancel && this.el.cancel.addEventListener('click', () => this.closeEditor());
      this.el.mask && this.el.mask.addEventListener('click', (e) => { if (e.target === this.el.mask) this.closeEditor(); });
    }

    // ---------- 存储 ----------
    loadLocal() {
      try {
        const raw = localStorage.getItem(this.storageKey);
        return raw ? JSON.parse(raw) : null;
      } catch { return null; }
    }
    saveLocal() {
      try {
        localStorage.setItem(this.storageKey, JSON.stringify({ version: 1, items: this.items }));
      } catch (e) {
        this.hint('保存到本地缓存失败: ' + e.message, true);
      }
    }
    async loadDefaults() {
      try {
        const resp = await fetch(this.defaultsUrl + '?t=' + Date.now());
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        const j = await resp.json();
        if (j && Array.isArray(j.items)) {
          this.items = j.items.map((it) => ({
            id: uid(),
            name: it.name || '未命名',
            hex: !!it.hex,
            crlf: !!it.crlf,
            data: it.data || '',
            delay: Math.max(0, parseInt(it.delay, 10) || 0),
            checked: it.checked !== false,
          }));
          this.saveLocal();
        }
      } catch (e) {
        this.hint('加载服务器默认示例失败, 已使用内置示例: ' + e.message, false);
        this.items = defaultItems();
      }
    }
    async resetToDefaults() {
      if (!confirm('确定用服务器默认示例覆盖当前列表吗? 本地修改将丢失')) return;
      this.stopRun();
      this.items = [];
      await this.loadDefaults();
      this.render();
      this.hint('已重置为服务器默认示例');
    }

    // ---------- 折叠/展开 ----------
    toggle() {
      if (!this.el.panel) return;
      this.el.panel.classList.toggle('collapsed');
      this.syncToggleLabel();
    }
    syncToggleLabel() {
      if (!this.el.toggleBtn || !this.el.panel) return;
      this.el.toggleBtn.textContent = this.el.panel.classList.contains('collapsed') ? '展开' : '收起';
    }

    // ---------- 渲染 ----------
    render() {
      const list = this.el.list;
      list.innerHTML = '';
      if (!this.items.length) {
        this.el.summary.textContent = '暂无快速发送条目, 点击"添加"或"重置为默认示例"。';
      } else {
        const n = this.items.filter((x) => x.checked !== false).length;
        this.el.summary.textContent = `共 ${this.items.length} 条, 已勾选 ${n} 条`;
      }
      this.items.forEach((it) => list.appendChild(this.renderItem(it)));
      if (this.el.checkAll) {
        const all = this.items.length > 0 && this.items.every((x) => x.checked !== false);
        this.el.checkAll.checked = all;
      }
      this.saveLocal();
      this.syncToggleLabel();
      this.updateRunState();
    }

    renderItem(it) {
      const div = document.createElement('div');
      div.className = 'qs-item';
      div.draggable = true;
      div.dataset.id = it.id;

      // 参与顺序/轮询的勾选框
      const chk = document.createElement('input');
      chk.type = 'checkbox';
      chk.className = 'qs-check';
      chk.checked = it.checked !== false;
      chk.title = '勾选后参与顺序/轮询发送';
      chk.addEventListener('change', () => {
        it.checked = chk.checked;
        this.render();
      });

      const name = document.createElement('span');
      name.className = 'qs-name';
      name.textContent = it.name;
      name.title = it.name;

      const data = document.createElement('span');
      data.className = 'qs-data';
      data.textContent = it.data;
      data.title = it.data;

      const tag = document.createElement('span');
      tag.className = 'qs-tag' + (it.hex ? ' hex' : '');
      tag.textContent = it.hex ? 'HEX' : '文本';

      // 本条延迟(ms) 内联输入, 手动填写即存 (不提供上下箭头, 直接在框内改)
      const delay = document.createElement('input');
      delay.type = 'number';
      delay.className = 'qs-delay';
      delay.min = '0';
      delay.inputMode = 'numeric';
      delay.value = Math.max(0, parseInt(it.delay, 10) || 0);
      delay.title = '本条发送后延迟(ms), 再发下一条 (手动填写)';
      delay.addEventListener('change', () => {
        it.delay = Math.max(0, parseInt(delay.value, 10) || 0);
        this.saveLocal();
      });
      const delayWrap = document.createElement('span');
      delayWrap.className = 'qs-delay-wrap';
      delayWrap.appendChild(document.createTextNode('延迟'));
      delayWrap.appendChild(delay);
      delayWrap.appendChild(document.createTextNode('ms'));

      const send = mkBtn('发送', 'btn primary', () => this.sendOne(it));
      const edit = mkBtn('编辑', 'btn', () => this.openEditor(it.id));
      const del = mkBtn('删除', 'btn danger', () => this.remove(it.id));

      // 三个操作按钮包进 .qs-actions, 便于移动端整体布局(flex/上下排)
      const actions = document.createElement('span');
      actions.className = 'qs-actions';
      actions.appendChild(send);
      actions.appendChild(edit);
      actions.appendChild(del);

      div.appendChild(chk);
      div.appendChild(name);
      div.appendChild(data);
      div.appendChild(tag);
      div.appendChild(delayWrap);
      div.appendChild(actions);

      // 拖拽排序
      div.addEventListener('dragstart', () => { this.dragId = it.id; div.classList.add('dragging'); });
      div.addEventListener('dragend', () => { this.dragId = null; div.classList.remove('dragging'); document.querySelectorAll('.qs-item.drop-before').forEach((e) => e.classList.remove('drop-before')); });
      div.addEventListener('dragover', (e) => { e.preventDefault(); if (this.dragId && this.dragId !== it.id) div.classList.add('drop-before'); });
      div.addEventListener('dragleave', () => div.classList.remove('drop-before'));
      div.addEventListener('drop', (e) => {
        e.preventDefault();
        div.classList.remove('drop-before');
        this.dropOn(it.id);
      });
      return div;
    }

    setAllChecked(v) {
      this.items.forEach((it) => { it.checked = v; });
      this.render();
    }

    dropOn(targetId) {
      if (!this.dragId || this.dragId === targetId) return;
      const from = this.items.findIndex((x) => x.id === this.dragId);
      const to = this.items.findIndex((x) => x.id === targetId);
      if (from < 0 || to < 0) return;
      const [moved] = this.items.splice(from, 1);
      this.items.splice(to, 0, moved);
      this.render();
    }

    // ---------- 发送 ----------
    sendOne(it) {
      if (typeof this.onSend === 'function') this.onSend(it);
    }

    runSeq() {
      this.stopRun();
      this.runList = this.items.filter((x) => x.checked !== false);
      if (!this.runList.length) { this.hint('没有勾选的条目, 无法顺序发送', true); return; }
      this.runMode = 'seq';
      this.runIndex = 0;
      this.step();
      this.updateRunState();
    }

    runPoll() {
      this.stopRun();
      this.runList = this.items.filter((x) => x.checked !== false);
      if (!this.runList.length) { this.hint('没有勾选的条目, 无法轮询发送', true); return; }
      this.runMode = 'poll';
      this.runIndex = 0;
      this.step();
      this.updateRunState();
    }

    step() {
      if (this.runMode === 'stop') return;
      if (this.runIndex >= this.runList.length) {
        if (this.runMode === 'poll') {
          this.runIndex = 0; // 循环
        } else {
          this.stopRun();
          this.hint('顺序发送完成');
          return;
        }
      }
      const it = this.runList[this.runIndex];
      this.sendOne(it);
      this.runIndex++;
      // 间隔 = 本条 delay(ms)
      const gap = Math.max(0, parseInt(it && it.delay, 10) || 0);
      this.runTimer = setTimeout(() => this.step(), gap);
    }

    stopRun() {
      if (this.runTimer) { clearTimeout(this.runTimer); this.runTimer = null; }
      this.runMode = 'stop';
      this.runIndex = 0;
      this.runList = [];
      this.updateRunState();
    }

    updateRunState() {
      if (!this.el.runState) return;
      if (this.runMode === 'seq') {
        this.el.runState.className = 'qs-run-state run';
        this.el.runState.textContent = `顺序发送中 (${this.runIndex}/${this.runList.length})`;
      } else if (this.runMode === 'poll') {
        this.el.runState.className = 'qs-run-state poll';
        this.el.runState.textContent = `轮询发送中 (第 ${this.runIndex} 条)`;
      } else {
        this.el.runState.className = 'qs-run-state stop';
        this.el.runState.textContent = '空闲';
      }
    }

    // ---------- 增删改 ----------
    remove(id) {
      this.items = this.items.filter((x) => x.id !== id);
      this.render();
    }

    openEditor(id) {
      this.editorId = id;
      const it = id ? this.items.find((x) => x.id === id) : null;
      this.el.name.value = it ? it.name : '';
      this.el.data.value = it ? it.data : '';
      this.el.hex.checked = it ? !!it.hex : false;
      this.el.crlf.checked = it ? !!it.crlf : true;
      this.el.delay.value = it ? Math.max(0, parseInt(it.delay, 10) || 0) : 0;
      // 双重保险: 同时用 class 与内联 style 控制显隐, 确保一定能关掉
      this.el.mask.classList.remove('hidden');
      this.el.mask.style.display = 'flex';
      this.el.name.focus();
    }

    closeEditor() {
      this.el.mask.classList.add('hidden');
      this.el.mask.style.display = 'none';
      this.editorId = null;
    }

    saveEditor() {
      const name = this.el.name.value.trim() || '未命名';
      const data = this.el.data.value;
      if (this.editorId) {
        const it = this.items.find((x) => x.id === this.editorId);
        if (it) { it.name = name; it.data = data; it.hex = this.el.hex.checked; it.crlf = this.el.crlf.checked; it.delay = Math.max(0, parseInt(this.el.delay.value, 10) || 0); }
      } else {
        this.items.push({ id: uid(), name, hex: this.el.hex.checked, crlf: this.el.crlf.checked, data, delay: Math.max(0, parseInt(this.el.delay.value, 10) || 0), checked: true });
      }
      this.closeEditor();
      this.render();
      this.hint('已保存');
    }

    // ---------- 导入导出 ----------
    exportJson() {
      const blob = new Blob([JSON.stringify({ version: 1, items: this.items }, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = 'linkcom-quicksend-' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.json';
      a.click();
      URL.revokeObjectURL(url);
    }

    importJson(e) {
      const file = e.target.files && e.target.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = () => {
        try {
          const j = JSON.parse(reader.result);
          if (!j || !Array.isArray(j.items)) throw new Error('格式不正确: 缺少 items 数组');
          const items = j.items.map((it) => ({
            id: uid(),
            name: it.name || '未命名',
            hex: !!it.hex,
            crlf: !!it.crlf,
            data: it.data || '',
            delay: Math.max(0, parseInt(it.delay, 10) || 0),
            checked: it.checked !== false,
          }));
          if (!items.length) throw new Error('文件中没有条目');
          this.items = items;
          this.render();
          this.hint('已导入 ' + items.length + ' 条');
        } catch (err) {
          this.hint('导入失败: ' + err.message, true);
        } finally {
          e.target.value = '';
        }
      };
      reader.readAsText(file);
    }
  }

  function mkBtn(text, cls, onClick) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = cls;
    b.textContent = text;
    b.addEventListener('click', onClick);
    return b;
  }

  window.QuickSend = QuickSend;
})();
