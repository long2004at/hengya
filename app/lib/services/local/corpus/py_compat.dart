// 恒牙（hengya）· 端上语料抽取 · Python 标准库行为等价层（py_compat）
// ============================================================================
//
// Phase 3a（extract_pptx 移植）引入。对拍基准是
// automation/server-pipeline/extract_pptx.py（Python 参考实现，纯标准库）。
// 为保证 Dart 输出与 Python 金样逐字节一致，本文件精确复刻其中
// 会影响输出的 Python 标准库行为；每处均注明 Python 侧依据与实测探针结论
// （2026-09-06 于 Python 3.12.0 实测）。
//
// 覆盖：
//   - pyStrip            str.strip()（空白集与 Dart trim() 不同：剥 \x1c-\x1f，
//                         不剥 U+FEFF）
//   - posixDirname/Basename/Join/Normpath、resolveZipPart
//                         posixpath.dirname/basename/join/normpath 及
//                         extract_pptx._resolve_part（normpath+lstrip("/")）
//   - pyPathName/Stem/ParentName
//                         Windows pathlib 的 name/stem/parent.name
//                         （stem 的后缀规则：`0 < i < len(name)-1`）
//   - pyDateFromIso      datetime.datetime.fromisoformat(...).date().isoformat()
//                         的常用取值子集（见函数头差异说明）
//   - fileMtimeIsoDate   mtime 兜底日期（本地时区，OSError → ""）
//   - md5File            hashlib.md5 分块读文件（1MB 块，同 MD5_CHUNK）
//   - pyJsonDumps / serializeChunksJsonl
//                         json.dumps(obj, ensure_ascii=False) 的扁平 map 版：
//                         分隔符 (", ", ": ")、字段按插入序、转义集与
//                         Python 完全一致（含 \u 小写十六进制）
//
// 复用约定：Phase 3b（extract_pdf / extract_docx 移植）同样 import 本文件，
// 不再各自另写等价层。

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// ------------------------------------------------------------- str.strip ----

/// Python str.isspace() 空白集（CPython _PyUnicode_IsWhitespace，实测与
/// Python 3.12 一致）：0x09-0x0D、0x1C-0x1F、0x20、0x85、0xA0、0x1680、
/// 0x2000-0x200A、0x2028、0x2029、0x202F、0x205F、0x3000。
/// 与 Dart String.trim() 的两处差异必须保留：Python 剥 \x1C-\x1F，
/// Dart 剥 U+FEFF；本函数按 Python 口径。
bool _isPyWhitespace(int cp) {
  if (cp < 0x20) {
    return (cp >= 0x09 && cp <= 0x0d) || (cp >= 0x1c);
  }
  if (cp == 0x20) return true;
  return cp == 0x85 ||
      cp == 0xa0 ||
      cp == 0x1680 ||
      (cp >= 0x2000 && cp <= 0x200a) ||
      cp == 0x2028 ||
      cp == 0x2029 ||
      cp == 0x202f ||
      cp == 0x205f ||
      cp == 0x3000;
}

/// 等价 Python `s.strip()`：按 _isPyWhitespace 剥两端。
/// （所有 Python 侧 .strip() 调用点——_join_runs/标题/块文本/日期捕获——
/// 都必须走这里，不能用 String.trim()。）
String pyStrip(String s) {
  var start = 0;
  var end = s.length;
  while (start < end && _isPyWhitespace(s.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isPyWhitespace(s.codeUnitAt(end - 1))) {
    end--;
  }
  return (start == 0 && end == s.length) ? s : s.substring(start, end);
}

// ----------------------------------------------------------- posixpath ----

/// 等价 posixpath.dirname：`p[:i]`，i = p.rfind('/') + 1。
String posixDirname(String p) => p.substring(0, p.lastIndexOf('/') + 1);

/// 等价 posixpath.basename：`p[i:]`，i = p.rfind('/') + 1。
String posixBasename(String p) => p.substring(p.lastIndexOf('/') + 1);

/// 等价 posixpath.join 两参数：绝对段替换前缀；空串直通。
String posixJoin2(String a, String b) {
  if (b.startsWith('/')) return b;
  if (a.isEmpty) return b;
  return a.endsWith('/') ? '$a$b' : '$a/$b';
}

/// 等价 posixpath.join(a, b, c, ...)：从左折叠。
String posixJoin(List<String> parts) {
  var result = '';
  for (final p in parts) {
    result = posixJoin2(result, p);
  }
  return result;
}

/// 等价 posixpath.normpath（Python 3.12 实测对拍）：
/// 丢弃空段与 "."；".." 在绝对路径且无可弹段时丢弃、否则弹上一段，
/// 相对路径开头的 ".." 保留；双前导斜杠按 POSIX 保留两根；
/// 结果为空 → "."。
String posixNormpath(String path) {
  var initialSlashes = path.startsWith('/') ? 1 : 0;
  if (initialSlashes == 1 && path.startsWith('//') && !path.startsWith('///')) {
    initialSlashes = 2; // POSIX 允许恰好两根
  }
  final newComps = <String>[];
  for (final comp in path.split('/')) {
    if (comp.isEmpty || comp == '.') continue;
    if (comp == '..') {
      if ((initialSlashes == 0 && newComps.isEmpty) ||
          (newComps.isNotEmpty && newComps.last == '..')) {
        newComps.add(comp);
      } else if (newComps.isNotEmpty) {
        newComps.removeLast();
      }
      // 绝对路径且无可弹段：丢弃（同 normpath("/../x") → "/x"）
    } else {
      newComps.add(comp);
    }
  }
  var joined = newComps.join('/');
  if (initialSlashes > 0) {
    joined = '/' * initialSlashes + joined;
  }
  return joined.isEmpty ? '.' : joined;
}

/// 等价 extract_pptx.py `_resolve_part`：
/// `posixpath.normpath(posixpath.join(dirname(base), target)).lstrip("/")`。
/// rels 相对地址（如 ../notesSlides/notesSlide1.xml）→ zip 部件名。
String resolveZipPart(String basePart, String target) {
  final resolved = posixNormpath(posixJoin2(posixDirname(basePart), target));
  return resolved.replaceAll(RegExp(r'^/+'), ''); // lstrip("/")
}

// ------------------------------------------------------- pathlib（Win）----

/// 按 / 与 \ 切分（Windows pathlib 两种分隔符都认），丢弃空段与 "." 段，
/// 并丢弃盘符段（如 "D:"——pathlib 视为 drive，不占 name）。
/// ".." 段保留为普通段（同 pathlib.parts）。
List<String> _pyWinComps(String path) {
  final comps = path
      .split(RegExp(r'[/\\]'))
      .where((c) => c.isNotEmpty && c != '.')
      .toList();
  if (comps.isNotEmpty && RegExp(r'^[A-Za-z]:$').hasMatch(comps.first)) {
    comps.removeAt(0);
  }
  return comps;
}

/// 等价 Windows `Path(p).name`。
String pyPathName(String path) {
  final comps = _pyWinComps(path);
  return comps.isEmpty ? '' : comps.last;
}

/// 等价 Windows `Path(p).stem`：name 去末个后缀。
/// Python 后缀判定 `0 < i < len(name) - 1`（i = name.rfind('.')）：
/// "x." 后缀为空 → stem "x."；".bashrc" → stem ".bashrc"；
/// "a.b.pptx" → stem "a.b"。（与 Dart path.basenameWithoutExtension
/// 在尾部点名上不同，故自实现。）
String pyPathStem(String path) {
  final name = pyPathName(path);
  final i = name.lastIndexOf('.');
  if (i > 0 && i < name.length - 1) {
    return name.substring(0, i);
  }
  return name;
}

/// 等价 Windows `Path(p).parent.name`：倒数第二段；无则 ""。
/// （Path("x.pptx").parent.name == ""；Path("D:/a/b/x.pptx").parent.name
/// == "b"；Path("D:/x.pptx").parent 是盘根 → name ""。）
String pyPathParentName(String path) {
  final comps = _pyWinComps(path);
  return comps.length >= 2 ? comps[comps.length - 2] : '';
}

// -------------------------------------------- datetime.fromisoformat ----

int _daysInMonth(int year, int month) {
  switch (month) {
    case 1:
    case 3:
    case 5:
    case 7:
    case 8:
    case 10:
    case 12:
      return 31;
    case 4:
    case 6:
    case 9:
    case 11:
      return 30;
    case 2:
      final leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
      return leap ? 29 : 28;
    default:
      return 0;
  }
}

String _pad4(int v) => v.toString().padLeft(4, '0');
String _pad2(int v) => v.toString().padLeft(2, '0');

/// 等价 `datetime.datetime.fromisoformat(s).date().isoformat()`，
/// 解析失败返回 null（调用方走 mtime 兜底，同 Python except ValueError）。
///
/// 覆盖 Python 3.12 fromisoformat 的常用取值子集（实测对拍）：
///   "YYYY-MM-DD"、"YYYYMMDD"、可带单字符分隔符 + "HH[:MM[:SS[.f+]]]"、
///   可带时区 "±HH[:MM[:SS[.f+]]]" 或 Z（Python 侧先做了
///   .replace("Z", "+00:00")，此处入参一般已无 Z）。
/// 范围校验同 Python：月 1-12、日按月、时 0-23、分/秒 0-59、
/// 偏移绝对值 < 24 小时。
///
/// 与 Python 的已知差异（OOXML 实际取值不涉及，见 extract_pptx.dart 文件头）：
///   - 周日期（"2025-W38-6"）与年积日不支持 → null 走 mtime 兜底；
///   - 分/秒上的小数（如 "14:51.5"）不支持。
String? pyDateFromIso(String s) {
  if (s.length < 8) return null;
  final md = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  int y;
  int mo;
  int d;
  String rest;
  if (md != null) {
    y = int.parse(md.group(1)!);
    mo = int.parse(md.group(2)!);
    d = int.parse(md.group(3)!);
    rest = s.substring(10);
  } else {
    final mb = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(s);
    if (mb == null) return null;
    y = int.parse(mb.group(1)!);
    mo = int.parse(mb.group(2)!);
    d = int.parse(mb.group(3)!);
    rest = s.substring(8);
  }
  if (mo < 1 || mo > 12) return null;
  if (d < 1 || d > _daysInMonth(y, mo)) return null;
  final datePart = '${_pad4(y)}-${_pad2(mo)}-${_pad2(d)}';
  if (rest.isEmpty) return datePart;
  if (rest.length == 1) return null; // 仅有分隔符 → Python 报 ValueError
  final timeStr = rest.substring(1); // 分隔符：任意单字符（T/空格/…）
  final tm = RegExp(r'^(\d{2})(?::?(\d{2}))?(?::?(\d{2})(?:[.,]\d+)?)?')
      .firstMatch(timeStr);
  if (tm == null) return null;
  final hh = int.parse(tm.group(1)!);
  final mi = tm.group(2) == null ? 0 : int.parse(tm.group(2)!);
  final ss = tm.group(3) == null ? 0 : int.parse(tm.group(3)!);
  if (hh > 23 || mi > 59 || ss > 59) return null;
  final tail = timeStr.substring(tm.end);
  if (tail.isEmpty) return datePart;
  if (tail == 'Z' || tail == 'z') return datePart;
  final off =
      RegExp(r'^([+-])(\d{2})(?::?(\d{2}))?(?::?(\d{2})(?:[.,]\d+)?)?$')
          .firstMatch(tail);
  if (off == null) return null;
  final oh = int.parse(off.group(2)!);
  final om = off.group(3) == null ? 0 : int.parse(off.group(3)!);
  final os = off.group(4) == null ? 0 : int.parse(off.group(4)!);
  if (oh > 23 || om > 59 || os > 59) return null;
  if (oh * 3600 + om * 60 + os >= 86400) return null; // Python 偏移 < 24h
  return datePart;
}

/// 等价 extract_pptx.py 的 mtime 兜底：
/// `datetime.fromtimestamp(os.path.getmtime(path)).date().isoformat()`
/// —— 本地时区日期；OSError → ""（lastModifiedSync 的各类 FileSystemException
/// 含 PathNotFound 均对应）。
String fileMtimeIsoDate(String path) {
  try {
    final dt = File(path).lastModifiedSync();
    return '${_pad4(dt.year)}-${_pad2(dt.month)}-${_pad2(dt.day)}';
  } on FileSystemException {
    return '';
  }
}

// ------------------------------------------------------------------ md5 ----

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value ??= data;
  }

  @override
  void close() {}
}

/// 等价 extract_pptx.py `md5_file`：分块读文件算 md5（大文件不整载内存）。
/// 块大小 1MB 同 Python MD5_CHUNK。
String md5File(String path) {
  final collector = _DigestCollector();
  final sink = md5.startChunkedConversion(collector);
  final raf = File(path).openSync();
  try {
    const chunkSize = 1 << 20;
    final buf = Uint8List(chunkSize);
    while (true) {
      final n = raf.readIntoSync(buf, 0, chunkSize);
      if (n <= 0) break;
      sink.add(n == chunkSize ? buf : Uint8List.view(buf.buffer, 0, n));
    }
  } finally {
    raf.closeSync();
  }
  sink.close();
  return collector.value!.toString();
}

// ------------------------------------------------------- json.dumps 风格 ----

/// Python json.dumps 转义集（ensure_ascii=False 路径，C 加速器与纯 Python
/// 实现一致）：`"` → \"、`\` → \\、\b\t\n\f\r 助记式、其余 <0x20 →
/// \uXXXX（小写十六进制，4 位补零）；非 ASCII 原样输出；不转义 / 与 0x7F。
String _pyEscapeJson(String s) {
  final sb = StringBuffer();
  for (final cu in s.codeUnits) {
    if (cu < 0x20) {
      if (cu == 0x08) {
        sb.write(r'\b');
      } else if (cu == 0x09) {
        sb.write(r'\t');
      } else if (cu == 0x0a) {
        sb.write(r'\n');
      } else if (cu == 0x0c) {
        sb.write(r'\f');
      } else if (cu == 0x0d) {
        sb.write(r'\r');
      } else {
        sb.write('\\u');
        sb.write(cu.toRadixString(16).padLeft(4, '0'));
      }
    } else if (cu == 0x22) {
      sb.write(r'\"');
    } else if (cu == 0x5c) {
      sb.write(r'\\');
    } else {
      sb.writeCharCode(cu);
    }
  }
  return sb.toString();
}

String _pyEncodeJson(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) return v.toString();
  if (v is String) return '"${_pyEscapeJson(v)}"';
  throw ArgumentError.value(
    v,
    'value',
    'pyJsonDumps 仅支持 null/bool/int/String（chunks.jsonl 契约内类型；'
    '浮点数 Python repr 与 Dart toString 存在边缘差异，契约字段不含浮点，'
    '遇到即报错而非静默产出错误字节）',
  );
}

/// 等价 `json.dumps(obj, ensure_ascii=False)`（扁平 map 版）：
/// 键值分隔 `": "`、成员分隔 `", "`（Python indent=None 默认 separators），
/// 字段按 map 插入序（Dart LinkedHashMap 字面量保插入序）。
String pyJsonDumps(Map<String, Object?> m) {
  final sb = StringBuffer('{');
  var first = true;
  for (final e in m.entries) {
    if (!first) sb.write(', ');
    first = false;
    sb.write('"${_pyEscapeJson(e.key)}": ${_pyEncodeJson(e.value)}');
  }
  sb.write('}');
  return sb.toString();
}

/// 等价 make_golden.py 的 jsonl 固化：
/// `"\n".join(json.dumps(c) for c in chunks) + "\n"`（UTF-8、LF 行尾）。
/// 注意：manifest 中 golden_md5/golden_bytes 是对这份 LF 规范文本计算的；
/// 盘上金样若经 Python Windows 文本模式写出（CRLF），比对前需归一化。
String serializeChunksJsonl(List<Map<String, Object?>> chunks) =>
    '${chunks.map(pyJsonDumps).join('\n')}\n';
