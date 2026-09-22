/*
 * serial-config.js — 共享端/链接端串口参数统一配置源
 * 两端均引用本文件，确保可选值、默认值、中文标签完全一致，避免双端配置不一致导致串口断开。
 */
(function (global) {
  'use strict';

  // 波特率可选列表（默认 115200）
  var BAUD_RATES = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600];

  // 数据位（默认 8；串口只有 5~8 位, 不存在 4 位数据位）
  var DATA_BITS = [5, 6, 7, 8];

  // 停止位（默认 1）
  var STOP_BITS = [1, 1.5, 2];

  // 校验位：value 必须与 Web Serial API 一致（none/odd/even/mark/space）
  // 注意：mark/space 多数浏览器 Web Serial 不支持，openPort 时会被 validateSerialOpts 拦截并提示
  var PARITY = [
    { value: 'none', label: 'None(无校验)' },
    { value: 'odd', label: 'Odd(奇校验)' },
    { value: 'even', label: 'Even(偶校验)' },
    { value: 'mark', label: 'Mark(标记)' },
    { value: 'space', label: 'Space(空位)' }
  ];

  // 流控：value 必须与 Web Serial API 一致（none/hardware/software）
  // 注意：software(软件流控) 浏览器 Web Serial 不支持，openPort 时会被拦截并提示
  var FLOW_CONTROL = [
    { value: 'none', label: 'None(无)' },
    { value: 'software', label: 'XON/XOFF(软件流控)' },
    { value: 'hardware', label: 'RTS/CTS(硬件流控)' }
  ];

  // 编码（默认 GBK）
  var ENCODINGS = [
    { value: 'gbk', label: 'GBK' },
    { value: 'utf8', label: 'UTF-8' }
  ];

  // 默认值
  var DEFAULTS = {
    baudRate: 115200,
    dataBits: 8,
    stopBits: 1,
    parity: 'none',
    flowControl: 'none',
    encoding: 'gbk'
  };

  // 生成 <option> 列表字符串（数值型选项 value 与文本相同）
  function optsNum(arr, selected) {
    return arr.map(function (v) {
      var s = (String(v) === String(selected)) ? ' selected' : '';
      return '<option value="' + v + '"' + s + '>' + v + '</option>';
    }).join('');
  }

  // 生成带 label 的选项字符串
  function optsObj(arr, selected) {
    return arr.map(function (o) {
      var s = (o.value === selected) ? ' selected' : '';
      return '<option value="' + o.value + '"' + s + '>' + o.label + '</option>';
    }).join('');
  }

  var SERIAL_UI = {
    BAUD_RATES: BAUD_RATES,
    DATA_BITS: DATA_BITS,
    STOP_BITS: STOP_BITS,
    PARITY: PARITY,
    FLOW_CONTROL: FLOW_CONTROL,
    ENCODINGS: ENCODINGS,
    DEFAULTS: DEFAULTS,

    // 渲染共享端表单（select id: baud/dbits/sbits/parity/flow）
    fillShare: function () {
      var b = document.getElementById('baud');
      if (b) b.innerHTML = optsNum(BAUD_RATES, DEFAULTS.baudRate);
      var d = document.getElementById('dbits');
      if (d) d.innerHTML = optsNum(DATA_BITS, DEFAULTS.dataBits);
      var s = document.getElementById('sbits');
      if (s) s.innerHTML = optsNum(STOP_BITS, DEFAULTS.stopBits);
      var p = document.getElementById('parity');
      if (p) p.innerHTML = optsObj(PARITY, DEFAULTS.parity);
      var f = document.getElementById('flow');
      if (f) f.innerHTML = optsObj(FLOW_CONTROL, DEFAULTS.flowControl);
    },

    // 渲染链接端配置表单（select id: cfgBaud/cfgData/cfgStop/cfgParity/cfgFlow/cfgEnc）
    fillLink: function () {
      var b = document.getElementById('cfgBaud');
      if (b) b.innerHTML = optsNum(BAUD_RATES, DEFAULTS.baudRate);
      var d = document.getElementById('cfgData');
      if (d) d.innerHTML = optsNum(DATA_BITS, DEFAULTS.dataBits);
      var s = document.getElementById('cfgStop');
      if (s) s.innerHTML = optsNum(STOP_BITS, DEFAULTS.stopBits);
      var p = document.getElementById('cfgParity');
      if (p) p.innerHTML = optsObj(PARITY, DEFAULTS.parity);
      var f = document.getElementById('cfgFlow');
      if (f) f.innerHTML = optsObj(FLOW_CONTROL, DEFAULTS.flowControl);
      var e = document.getElementById('cfgEnc');
      if (e) e.innerHTML = optsObj(ENCODINGS, DEFAULTS.encoding);
    },

    // 渲染共享端/链接端的显示编码下拉（id: encoding），默认由 DEFAULTS.encoding 决定
    fillEncoding: function () {
      var e = document.getElementById('encoding');
      if (e) e.innerHTML = optsObj(ENCODINGS, DEFAULTS.encoding);
    }
  };

  global.SERIAL_UI = SERIAL_UI;
})(window);
