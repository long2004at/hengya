// 恒牙（hengya）· 端上语料抽取 · OOXML 共享层（zip 读取 + 迷你 XML 解析）
// ============================================================================
//
// Phase 3a 随 extract_pptx.dart 落地并经金样验证（oms_ch2_pptx 92 chunks
// 与 Python 金样逐字节一致）；Phase 3b 起抽为共享层，由 extract_pptx /
// extract_docx（后续 extract_pdf 不涉及 OOXML）共用。
// **任何改动必须重跑金样回归**（cwd=app）：
//   flutter test test/extract_pptx_golden_test.dart
//   flutter test test/extract_docx_golden_test.dart
//
// 语义对齐点（复刻 xml.etree/expat，与 ElementTree 逐点对拍）：
//   - 行尾归一化：\r\n → \n、孤立 \r → \n（XML 1.0；源部件实测带
//     \r\r\n，不归一化则文本与长度全失真）；
//   - 命名空间解析成 '{uri}local' 再匹配（与 ElementTree 同，不依赖
//     前缀拼写）；无前缀属性不在默认命名空间（XML 规范）；
//   - .text 语义 = 首个子元素前的文本，空 → null（对应 Python None），
//     子元素后的尾巴文本丢弃（ElementTree 的 .tail，抽取不用）；
//   - 实体：仅预定义 5 种 + 字符引用（expat 同：未定义命名实体 →
//     解析失败 → 调用方按空页/空 rels/中断处理）；字符引用拒绝非法
//     控制符/代理区；
//   - 属性值规范化：字面 \t/\n → 空格（expat 同）；属性值含 < → 非法；
//   - CDATA 原样并入文本；注释/PI 透明；DOCTYPE 仅跳过（内部子集
//     定义的实体不支持，OOXML 部件无 DOCTYPE）。
//   - zip 读取用 package:archive（direct 依赖）：中央目录顺序、精确名
//     查找等价 zipfile.namelist()/read()；部件内容按需惰性解压。
//
// ElementTree 语义辅助（Phase 3b 新增，extract_docx 依赖）：
//   - findChild / findChildren：等价 elem.find / elem.findall——只查
//     **直接**子元素（Python `st.find(W+"name")`、`st.find("{ns}pPr/
//     {ns}outlineLvl")` 均按直接子路径匹配）；
//   - iterAll：等价 elem.iter()（无 tag 参数）——含自身的前序全后代
//     （Python `p.iter()` 收集 w:t/w:tab/w:br/w:cr 依赖此语义）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

// ------------------------------------------------------------- zip 读取 ----

/// zipfile.ZipFile 的最小等价面：namelist() + read(name)（缺失 → null）。
class ZipReader {
  final Archive _archive;
  ZipReader(this._archive);

  static ZipReader open(String path) =>
      ZipReader(ZipDecoder().decodeBytes(File(path).readAsBytesSync()));

  List<String> names() => [for (final f in _archive.files) f.name];

  Uint8List? read(String name) {
    final f = _archive.find(name);
    if (f == null || !f.isFile) return null;
    return f.content;
  }
}

// --------------------------------------------------------- 迷你 XML 解析 ----

class XElem {
  final String tag; // '{uri}local'（同 ElementTree）或 'local'（无命名空间）
  final Map<String, String> attrs; // 无前缀属性按字面名；带前缀解析 '{uri}local'
  final List<XElem> children;
  String? text; // 首个子元素前文本（同 ElementTree .text；无 → null）
  XElem(this.tag, this.attrs) : children = [];
}

class _Ns {
  final _Ns? parent;
  final Map<String, String> declared; // '' = 默认命名空间
  _Ns(this.parent, this.declared);

  String? lookup(String prefix) {
    _Ns? scope = this;
    while (scope != null) {
      final v = scope.declared[prefix];
      if (v != null) return v;
      scope = scope.parent;
    }
    return null;
  }
}


/// 等价 Python 侧 _parse_xml(data)：bytes → 元素树；解析失败（对应
/// ET.ParseError）返回 null，由调用方决定（extract_pptx 按空页/空 rels
/// 跳过；extract_docx 对 word/document.xml 抛 FormatException 中断）。
/// data 为 null 亦返回 null（见 extract_pptx.dart 文件头差异说明：
/// Python 对 None 会抛 TypeError，Dart 从稳跳过）。
XElem? parseXml(Uint8List? data) {
  if (data == null || data.isEmpty) return null;
  String src;
  try {
    src = utf8.decode(data);
  } on FormatException {
    return null; // 非 UTF-8 → 同 ParseError
  }
  if (src.isNotEmpty && src.codeUnitAt(0) == 0xfeff) {
    src = src.substring(1); // UTF-8 BOM（expat 接受）
  }
  if (src.contains('\r')) {
    // XML 1.0 行尾归一化（expat 同）
    src = src.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }
  try {
    return XmlParser(src).parse();
  } on FormatException {
    return null;
  }
}

class XmlParser {
  static const _xmlNsUri = 'http://www.w3.org/XML/1998/namespace';

  final String s;
  int i = 0;
  XmlParser(this.s);

  XElem parse() {
    _skipProlog();
    final root = _element(null);
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n') {
        i++;
      } else if (c == '<' && (s.startsWith('<!--', i) || s.startsWith('<?', i))) {
        if (s.startsWith('<!--', i)) {
          _skipComment();
        } else {
          _skipPi();
        }
      } else {
        throw const FormatException('XML 根元素后存在多余内容');
      }
    }
    return root;
  }

  void _skipProlog() {
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n') {
        i++;
      } else if (c == '<' && s.startsWith('<!--', i)) {
        _skipComment();
      } else if (c == '<' && s.startsWith('<?', i)) {
        _skipPi();
      } else if (c == '<' && s.startsWith('<!DOCTYPE', i)) {
        _skipDoctype();
      } else {
        return; // 根元素（或错误，由调用方捕获）
      }
    }
  }

  void _skipComment() {
    final end = s.indexOf('-->', i + 4);
    if (end < 0 || s.substring(i + 4, end).contains('--')) {
      throw const FormatException('注释非法或未闭合'); // 注释内禁 "--"（expat 同）
    }
    i = end + 3;
  }

  void _skipPi() {
    final end = s.indexOf('?>', i + 2);
    if (end < 0) {
      throw const FormatException('PI 未闭合');
    }
    i = end + 2;
  }

  void _skipDoctype() {
    // 仅跳过（含内部子集 [...]）；子集内声明的实体不支持（见文件头说明）
    i += 9;
    var depth = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == '[') {
        depth++;
      } else if (c == ']' && depth > 0) {
        depth--;
      } else if (c == '>' && depth == 0) {
        i++;
        return;
      }
      i++;
    }
    throw const FormatException('DOCTYPE 未闭合');
  }

  void _ws() {
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n') {
        i++;
      } else {
        return;
      }
    }
  }

  /// XML 名字（近似：分隔符/引号/等号/斜杠即停；OOXML 名全部合法，足够）。
  String _name() {
    if (i >= s.length) {
      throw const FormatException('意外的文档结尾');
    }
    final start = i;
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' || c == '\t' || c == '\n' ||
          c == '/' || c == '>' || c == '=' ||
          c == '"' || c == "'" || c == '<') {
        break;
      }
      i++;
    }
    if (i == start) {
      throw const FormatException('非法名字');
    }
    return s.substring(start, i);
  }

  String _attrValue() {
    if (i >= s.length) {
      throw const FormatException('属性值未闭合');
    }
    final q = s[i];
    if (q != '"' && q != "'") {
      throw const FormatException('属性值须带引号');
    }
    i++;
    final buf = StringBuffer();
    while (true) {
      if (i >= s.length) {
        throw const FormatException('属性值未闭合');
      }
      final c = s[i];
      if (c == q) {
        i++;
        break;
      }
      if (c == '<') {
        throw const FormatException('属性值含 <'); // XML 非法（expat 同）
      }
      if (c == '&') {
        buf.write(_entity());
      } else {
        buf.write(c);
        i++;
      }
    }
    // XML 属性值规范化（expat 同）：字面 \t/\n → 空格（\r 已随行尾归一）
    return buf.toString().replaceAll('\t', ' ').replaceAll('\n', ' ');
  }

  /// 实体解码：预定义 5 种 + 字符引用；其余（未定义命名实体）→ 非法
  /// （expat 无 DTD 时同：引用即错 → 整文档解析失败 → 空页）。
  String _entity() {
    var j = i + 1;
    while (j < s.length && j - i <= 10 && s[j] != ';') {
      j++;
    }
    if (j >= s.length || s[j] != ';' || j == i + 1) {
      throw const FormatException('实体未闭合');
    }
    final name = s.substring(i + 1, j);
    i = j + 1;
    if (name.startsWith('#')) {
      int cp = -1;
      if (name.length > 1 && (name[1] == 'x' || name[1] == 'X')) {
        cp = int.tryParse(name.substring(2), radix: 16) ?? -1;
      } else {
        cp = int.tryParse(name.substring(1)) ?? -1;
      }
      if (cp < 0x20 && cp != 0x09 && cp != 0x0a && cp != 0x0d) {
        throw const FormatException('非法字符引用');
      }
      if (cp == 0 || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff) {
        throw const FormatException('非法字符引用');
      }
      return String.fromCharCode(cp);
    }
    switch (name) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      default:
        throw FormatException('未定义实体: $name');
    }
  }

  String _cdata() {
    final end = s.indexOf(']]>', i + 9);
    if (end < 0) {
      throw const FormatException('CDATA 未闭合');
    }
    final raw = s.substring(i + 9, end);
    i = end + 3;
    return raw;
  }

  String _resolveName(String raw, _Ns? ns) {
    final c = raw.indexOf(':');
    if (c < 0) {
      final uri = ns?.lookup('');
      return uri == null ? raw : '{$uri}$raw'; // 默认命名空间作用于元素
    }
    final prefix = raw.substring(0, c);
    final local = raw.substring(c + 1);
    if (prefix == 'xml') return '{$_xmlNsUri}$local'; // 保留前缀隐式绑定
    final uri = ns?.lookup(prefix);
    if (uri == null) {
      throw const FormatException('未绑定命名空间前缀'); // expat 同
    }
    return '{$uri}$local';
  }

  String _resolveAttrName(String raw, _Ns? ns) {
    final c = raw.indexOf(':');
    if (c < 0) return raw; // 无前缀属性不在默认命名空间（XML 规范）
    final prefix = raw.substring(0, c);
    final local = raw.substring(c + 1);
    if (prefix == 'xml') return '{$_xmlNsUri}$local';
    final uri = ns?.lookup(prefix);
    if (uri == null) {
      throw const FormatException('未绑定命名空间前缀');
    }
    return '{$uri}$local';
  }

  XElem _element(_Ns? parentNs) {
    i++; // 消费 '<'
    final rawName = _name();
    final rawAttrs = <(String, String)>[];
    var selfClosing = false;
    while (true) {
      _ws();
      if (i >= s.length) {
        throw const FormatException('标签未闭合');
      }
      final c = s[i];
      if (c == '>') {
        i++;
        break;
      }
      if (c == '/' && s.startsWith('/>', i)) {
        i += 2;
        selfClosing = true;
        break;
      }
      final aname = _name();
      _ws();
      if (i >= s.length || s[i] != '=') {
        throw const FormatException('属性缺少 =');
      }
      i++;
      _ws();
      rawAttrs.add((aname, _attrValue()));
    }

    // 命名空间作用域
    final decls = <String, String>{};
    for (final (n, v) in rawAttrs) {
      if (n == 'xmlns') {
        decls[''] = v;
      } else if (n.startsWith('xmlns:')) {
        decls[n.substring(6)] = v;
      }
    }
    final ns = decls.isEmpty ? parentNs : _Ns(parentNs, decls);

    final attrs = <String, String>{};
    for (final (n, v) in rawAttrs) {
      if (n == 'xmlns' || n.startsWith('xmlns:')) continue;
      final resolved = _resolveAttrName(n, ns);
      if (attrs.containsKey(resolved)) {
        throw const FormatException('重复属性'); // expat 同
      }
      attrs[resolved] = v;
    }

    final elem = XElem(_resolveName(rawName, ns), attrs);
    if (selfClosing) {
      return elem;
    }

    var textBuf = StringBuffer();
    var firstChild = false;
    while (true) {
      if (i >= s.length) {
        throw const FormatException('元素未闭合');
      }
      final c = s[i];
      if (c == '<') {
        if (s.startsWith('<!--', i)) {
          _skipComment(); // 注释透明（不产生文本）
        } else if (s.startsWith('<![CDATA[', i)) {
          final raw = _cdata();
          if (!firstChild) textBuf.write(raw);
        } else if (s.startsWith('<?', i)) {
          _skipPi(); // PI 透明
        } else if (s.startsWith('</', i)) {
          i += 2;
          final closeName = _name();
          _ws();
          if (i >= s.length || s[i] != '>') {
            throw const FormatException('闭合标签非法');
          }
          i++;
          if (closeName != rawName) {
            throw const FormatException('闭合标签不匹配');
          }
          break;
        } else {
          if (!firstChild) {
            elem.text = textBuf.isEmpty ? null : textBuf.toString();
            firstChild = true;
          }
          elem.children.add(_element(ns));
        }
      } else if (c == '&') {
        final decoded = _entity(); // 尾巴文本也须校验实体合法性
        if (!firstChild) textBuf.write(decoded);
      } else {
        final start = i;
        while (i < s.length && s[i] != '<' && s[i] != '&') {
          i++;
        }
        final chunk = s.substring(start, i);
        if (chunk.contains(']]>')) {
          throw const FormatException('文本含 ]]>'); // expat 同
        }
        if (!firstChild) textBuf.write(chunk);
      }
    }
    if (!firstChild) {
      elem.text = textBuf.isEmpty ? null : textBuf.toString();
    }
    return elem;
  }
}

/// 等价 ElementTree 的 elem.iter(tag)：前序文档序（含自身与全部后代）。
Iterable<XElem> iterTag(XElem e, String tag) sync* {
  if (e.tag == tag) yield e;
  for (final c in e.children) {
    yield* iterTag(c, tag);
  }
}

// ------------------------------------ ElementTree 语义辅助（3b 新增）----

/// 等价 ElementTree 的 elem.find(tag)：首个**直接**子元素（无 → null）。
/// Python `st.find("{ns}pPr/{ns}outlineLvl")` 的两级路径在调用方拆成
/// 两次 findChild（直接子 → 直接子），语义一致。
XElem? findChild(XElem e, String tag) {
  for (final c in e.children) {
    if (c.tag == tag) return c;
  }
  return null;
}

/// 等价 ElementTree 的 elem.findall(tag)：全部**直接**子元素（文档序）。
List<XElem> findChildren(XElem e, String tag) {
  final out = <XElem>[];
  for (final c in e.children) {
    if (c.tag == tag) out.add(c);
  }
  return out;
}

/// 等价 ElementTree 的 elem.iter()（无 tag 参数）：前序文档序，含自身与
/// 全部后代。extract_docx 的段落文本收集（w:t/w:tab/w:br/w:cr）依赖
/// 此语义（`p.iter()` 含 p 自身，顺序与 Python 一致）。
Iterable<XElem> iterAll(XElem e) sync* {
  yield e;
  for (final c in e.children) {
    yield* iterAll(c);
  }
}
