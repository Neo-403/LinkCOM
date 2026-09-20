import 'dart:convert';
import 'dart:typed_data';
import 'package:gbk_codec/gbk_codec.dart';

// 串口字节流编解码: UTF-8 / GBK (兼容中文设备)
// 注意: 必须用 gbk_bytes (正确的双字节合并解码), 而非 gbk (逐字节会乱码)
String decodeBytes(List<int> bytes, String encoding) {
  if (encoding == 'gbk') return gbk_bytes.decode(bytes);
  return utf8.decode(bytes, allowMalformed: true);
}

List<int> encodeString(String text, String encoding) {
  if (encoding == 'gbk') return gbk_bytes.encode(text);
  return utf8.encode(text);
}

// 解析 HEX 字符串为字节; 非法(空或奇数位)返回 null
Uint8List? parseHexBytes(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.isEmpty || clean.length.isOdd) return null;
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// 发送输入框 → 字节: HEX 模式解析十六进制; 文本模式按编码编码, 可选追加 \r\n
// 返回 null 表示无法编码 (如 HEX 格式错误)
Uint8List? encodeSendInput(String text,
    {required bool hex, required bool crlf, required String encoding}) {
  if (text.isEmpty) return null;
  if (hex) return parseHexBytes(text);
  return Uint8List.fromList(encodeString(crlf ? '$text\r\n' : text, encoding));
}
