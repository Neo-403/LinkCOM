/* GBK 编解码 (纯前端, 无依赖)
 * 解码: 使用浏览器原生 TextDecoder('gbk') (完整支持 GBK)
 * 编码: 首次使用时遍历合法 GBK 双字节空间, 借助浏览器解码器反推 Unicode->GBK 映射表
 */
(function (global) {
  'use strict';

  let encMap = null; // Map<unicodeChar, [b1, b2]>

  function buildEncMap() {
    if (encMap) return encMap;
    encMap = new Map();
    let dec;
    try { dec = new TextDecoder('gbk'); } catch (e) { dec = new TextDecoder('utf-8'); }
    for (let b1 = 0x81; b1 <= 0xfe; b1++) {
      for (let b2 = 0x40; b2 <= 0xfe; b2++) {
        if (b2 === 0x7f) continue;
        const ch = dec.decode(new Uint8Array([b1, b2]));
        if (ch && ch.length === 1 && ch.charCodeAt(0) !== 0xfffd) {
          if (!encMap.has(ch)) encMap.set(ch, [b1, b2]);
        }
      }
    }
    return encMap;
  }

  function encodeGbk(str) {
    const m = buildEncMap();
    const out = [];
    for (const c of str) {
      const code = c.charCodeAt(0);
      if (code < 0x80) {
        out.push(code);
      } else {
        const e = m.get(c);
        if (e) out.push(e[0], e[1]);
        else out.push(0x3f); // '?'
      }
    }
    return new Uint8Array(out);
  }

  function decodeGbk(bytes) {
    try { return new TextDecoder('gbk').decode(bytes); }
    catch (e) { return new TextDecoder('utf-8').decode(bytes); }
  }

  function decodeUtf8(bytes) {
    return new TextDecoder('utf-8').decode(bytes);
  }
  function encodeUtf8(str) {
    return new TextEncoder().encode(str);
  }

  global.GbkUtil = {
    encodeGbk, decodeGbk, encodeUtf8, decodeUtf8,
    isGbkSupported() {
      try { return typeof TextDecoder !== 'undefined' && new TextDecoder('gbk').encoding.toLowerCase() === 'gbk'; }
      catch (e) { return false; }
    }
  };
})(window);
