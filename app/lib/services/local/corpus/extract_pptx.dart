// 恒牙（hengya）· 端上语料抽取 · PPT 抽取（OOXML → chunks）
// ============================================================================
//
// Phase 3a 第一刀：移植自 automation/server-pipeline/extract_pptx.py
// （Python 参考实现，~910 行；对拍金样 app/test/fixtures/golden/
// oms_ch2_pptx_chunks.jsonl）。行为等价基准：同一源 pptx 的 Dart 输出与
// Python 金样逐字段、逐字节一致（见 app/test/extract_pptx_golden_test.dart）。
//
// 移植范围（第一刀）
// ----------------
//   split_subject_source / detect_source_type、OOXML 解析（_join_runs、
//   _page_title、_read_rels/_resolve_part、_file_date_from_pptx）、
//   parse_pptx、build_chunks、chunk_id_of、extract_file。
//
//   第二刀（本文件不做，见交付 handoff）：extract_all 树扫描、manifest
//   增量（size+mtime→md5→删旧插新）、min-pptx 自测（_build_min_pptx/
//   self_test）。
//
// 关键等价性决策（与 Python 逐点对拍）
// ------------------------------------
//   1. Python len() 按码点计数：短页阈值（<50 字）用 text.runes.length，
//      不用 UTF-16 .length（任务红线）。
//   2. 所有 Python .strip() 走 py_compat.pyStrip（空白集≠Dart trim()）。
//   3. XML 解析自写迷你解析器（复刻 xml.etree/expat 语义），不引
//      package:xml——它是传递依赖，直接 import 会触发
//      depend_on_referenced_packages lint（pubspec 已冻结）。语义对齐点：
//      - 行尾归一化：\r\n → \n、孤立 \r → \n（XML 1.0；源 pptx 全部
//        161 页 slide XML 实测带 \r\r\n，不归一化则文本与长度全失真）；
//      - 命名空间解析成 '{uri}local' 再匹配 a:t / a:p / p:sp / p:ph /
//        Relationship（与 ElementTree 同，不依赖前缀拼写）；
//      - .text 语义 = 首个子元素前的文本，空 → null（对应 Python None），
//        子元素后的尾巴文本丢弃（ElementTree 的 .tail，抽取不用）；
//      - 实体：仅预定义 5 种 + 字符引用（expat 同：未定义命名实体 →
//        解析失败 → 该页按空页处理）；字符引用拒绝非法控制符/代理区；
//      - 属性值规范化：字面 \t/\n → 空格（expat 同）；属性值含 < → 非法；
//      - CDATA 原样并入文本；注释/PI 透明；DOCTYPE 仅跳过（内部子集
//        定义的实体不支持，PPTX 部件无 DOCTYPE）。
//   4. zip 读取用 package:archive（direct 依赖）：中央目录顺序、精确名
//      查找等价 zipfile.namelist()/read()；部件内容按需惰性解压。
//   5. chunks.jsonl 序列化走 py_compat.pyJsonDumps/serializeChunksJsonl
//      ——json.dumps(ensure_ascii=False) 的分隔符 (", ", ": ") 与转义集，
//      Dart 自带 jsonEncode 分隔符不同，不可直接用。
//
// 与 Python 的已知行为差异（金样不经过；遇到属边界输入）
// -------------------------------------------------------
//   - slide rels 指向 zip 内缺失部件：Python ET.fromstring(None) 抛
//     TypeError 崩溃；Dart 按 null 处理 → 跳过该部件（更稳）。
//   - XML 部件声明非 UTF-8 编码（如 GBK）：Python expat 按声明解码，
//     Dart 严格按 UTF-8 解码 → 解析失败按空页处理（OOXML 部件事实
//     全为 UTF-8，源 pptx 161 页实测全为 UTF-8 声明）。
//   - core.xml dcterms:created 为周日期（"2025-W38-6"）等罕见形态：
//     pyDateFromIso 不支持 → 走 mtime 兜底；Python fromisoformat(3.12)
//     可解析。实际取值 "2025-09-16T12:11:00Z"（实测）不涉及。
//   - utf8 解码 errors="replace" 的 U+FFFD 聚合粒度（Python 按字节 /
//     Dart 按最大子序列），仅影响 core.xml 正则匹配上下文，被捕获的
//     日期段本身为 ASCII，不影响结果。
//   - FileTooBig 异常消息中 MB 数的取整（%.0f 四舍六入五成双 vs
//     toStringAsFixed）：仅错误文案，不进任何输出。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'ooxml.dart';
import 'py_compat.dart';

// ------------------------------------------------------------- 常量 ----

const shortPageChars = 50; // 短页阈值：<50 字与相邻页合并（Python len 按码点）
const defaultMaxFileMb = 150; // 单文件大小上限（MB），超过抛 FileTooBig

const _aNs = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _pNs = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _relNs = 'http://schemas.openxmlformats.org/package/2006/relationships';
final _aT = '{$_aNs}t'; // <a:t> 文本 run
final _aP = '{$_aNs}p'; // <a:p> 段落
final _pSp = '{$_pNs}sp'; // <p:sp> 形状
final _pPh = '{$_pNs}ph'; // <p:ph> 占位符
const _titlePhTypes = ['title', 'ctrTitle'];

final _slideRe = RegExp(r'^ppt/slides/slide(\d+)\.xml$');
final _coreCreatedRe = RegExp(
  r'<dcterms:created[^>]*>([^<]+)<',
  caseSensitive: false,
);

// ------------------------------------------------------------- 模型 ----

class FileTooBig implements Exception {
  final String message;
  FileTooBig(this.message);

  @override
  String toString() => 'FileTooBig: $message';
}

class PptxPage {
  final int no;
  final String title;
  final String text;
  const PptxPage(this.no, this.title, this.text);
}

class PptxChunk {
  final String chunkId;
  final String subjectId;
  final String pptId;
  final String deck;
  final int pageStart;
  final int pageEnd;
  final String title;
  final String text;
  final String sourceType;
  final String fileDate;

  const PptxChunk({
    required this.chunkId,
    required this.subjectId,
    required this.pptId,
    required this.deck,
    required this.pageStart,
    required this.pageEnd,
    required this.title,
    required this.text,
    required this.sourceType,
    required this.fileDate,
  });

  /// chunks.jsonl 契约字段序（make_golden.py 金样字段序，序列化依赖插入序）。
  Map<String, Object?> toOrderedMap() => <String, Object?>{
    'chunk_id': chunkId,
    'subject_id': subjectId,
    'ppt_id': pptId,
    'deck': deck,
    'page_start': pageStart,
    'page_end': pageEnd,
    'title': title,
    'text': text,
    'source_type': sourceType,
    'file_date': fileDate,
  };
}

class DeckInfo {
  final String subjectId;
  final String pptId;
  final String deck;
  final String sourceType;
  final String fileDate;
  final String filePath;
  final String fileMd5;
  final int fileSize;
  final int fileMtime;

  const DeckInfo({
    required this.subjectId,
    required this.pptId,
    required this.deck,
    required this.sourceType,
    required this.fileDate,
    required this.filePath,
    required this.fileMd5,
    required this.fileSize,
    required this.fileMtime,
  });
}

// ------------------------------------------------- 目录名 → 科目/来源 ----

/// 等价 split_subject_source（节点④扩展 -outline）：第一层目录名 →
/// (subject_id, source_type)。
///   xxx-textbook → (xxx, textbook)；xxx-exam → (xxx, exam)；
///   xxx-outline → (xxx, outline)（大纲树：建库路由到 outline 解析器，
///   正文不进常规语料块——数据只入 corpus.db outline_entries）；
///   exam → (exam, exam)（跨科真题库）；其余 → (目录名, ppt)；
///   空目录名 → (unknown, ppt)。
/// 注意 Python 用小写名匹配后缀、但截取原大小写目录名；空结果回 unknown。
({String subject, String sourceType}) splitSubjectSource(String? dirName) {
  final n = pyStrip(dirName ?? '');
  final low = n.toLowerCase();
  if (low.endsWith('-textbook')) {
    final s = n.substring(0, n.length - '-textbook'.length);
    return (subject: s.isEmpty ? 'unknown' : s, sourceType: 'textbook');
  }
  if (low.endsWith('-exam')) {
    final s = n.substring(0, n.length - '-exam'.length);
    return (subject: s.isEmpty ? 'unknown' : s, sourceType: 'exam');
  }
  if (low.endsWith('-outline')) {
    final s = n.substring(0, n.length - '-outline'.length);
    return (subject: s.isEmpty ? 'unknown' : s, sourceType: 'outline');
  }
  if (low == 'exam') {
    return (subject: 'exam', sourceType: 'exam');
  }
  return (subject: n.isEmpty ? 'unknown' : n, sourceType: 'ppt');
}

/// 等价 detect_source_type：委托 split_subject_source 取第二值。
String detectSourceType(String? dirName) =>
    splitSubjectSource(dirName).sourceType;

// ------------------------------------------------------------ OOXML 抽取 ----

/// 等价 _join_runs：整树按段落收集 `<a:t>`（表格/组合自动覆盖）。
/// 返回 (lines, firstText)：lines=非空段落；firstText=文档序首个非空 a:t。
(List<String>, String) _joinRuns(XElem root) {
  final lines = <String>[];
  var firstText = '';
  for (final pElem in iterTag(root, _aP)) {
    final buf = <String>[];
    for (final t in iterTag(pElem, _aT)) {
      final txt = pyStrip(t.text ?? '');
      if (txt.isNotEmpty) buf.add(txt);
    }
    final line = pyStrip(buf.join());
    if (line.isNotEmpty) lines.add(line);
  }
  for (final t in iterTag(root, _aT)) {
    final txt = pyStrip(t.text ?? '');
    if (txt.isNotEmpty) {
      firstText = txt;
      break;
    }
  }
  return (lines, firstText);
}

/// 等价 _page_title：`<p:ph type="title"/"ctrTitle">` 占位符文本，
/// 否则首个非空 `<a:t>`。注意：占位符命中但为空 → 换下一个 sp（break 语义）。
String _pageTitle(XElem root, String firstText) {
  for (final sp in iterTag(root, _pSp)) {
    for (final ph in iterTag(sp, _pPh)) {
      final t = ph.attrs['type'];
      if (t != null && _titlePhTypes.contains(t)) {
        // 占位符标题：该 sp 全部 a:t 原文（不逐 run strip）拼接后整体 strip
        final title = pyStrip(
          [for (final x in iterTag(sp, _aT)) x.text ?? ''].join(),
        );
        if (title.isNotEmpty) return title;
        break;
      }
    }
  }
  return firstText;
}

/// 等价 _read_rels：读某部件的 .rels → [(rel_type, target_part), …]。
/// 跳过 http:// 与 https:// 绝对 Target；其余按 _resolve_part 解析。
List<(String, String)> _readRels(ZipReader zf, String slidePart) {
  final relsPart = posixJoin([
    posixDirname(slidePart),
    '_rels',
    '${posixBasename(slidePart)}.rels',
  ]);
  final data = zf.read(relsPart);
  if (data == null || data.isEmpty) return [];
  final root = parseXml(data);
  if (root == null) return [];
  final out = <(String, String)>[];
  for (final rel in iterTag(root, '{$_relNs}Relationship')) {
    final rtype = rel.attrs['Type'] ?? '';
    final target = rel.attrs['Target'] ?? '';
    if (target.isEmpty ||
        target.startsWith('http://') ||
        target.startsWith('https://')) {
      continue;
    }
    out.add((rtype, resolveZipPart(slidePart, target)));
  }
  return out;
}

/// 等价 _file_date_from_pptx：docProps/core.xml 的 dcterms:created →
/// YYYY-MM-DD；缺/解析失败 → 文件 mtime（本地时区日期）；再失败 → ""。
String _fileDateFromPptx(ZipReader zf, String fallbackPath) {
  final data = zf.read('docProps/core.xml');
  if (data != null && data.isNotEmpty) {
    final decoded = utf8.decode(
      data,
      allowMalformed: true,
    ); // ~ errors="replace"
    final m = _coreCreatedRe.firstMatch(decoded);
    if (m != null) {
      final d = pyDateFromIso(pyStrip(m.group(1)!).replaceAll('Z', '+00:00'));
      if (d != null) return d;
    }
  }
  return fileMtimeIsoDate(fallbackPath);
}

/// 等价 parse_pptx：单个 .pptx → (pages, file_date)。
/// 页序按文件名 slide{N}.xml 的 N 近似排序（同 Python；sldIdLst 精确页序
/// 见 Python 文件头说明，同为近似）。text=幻灯片+diagrams+备注。
/// 解析失败的页记 {"no", "", ""}（同 Python ParseError → None → 空页）。
(List<PptxPage>, String) parsePptx(String path) {
  final zf = ZipReader.open(path);
  final slideNums = <(int, String)>[];
  for (final name in zf.names()) {
    final m = _slideRe.firstMatch(name);
    if (m != null) {
      slideNums.add((int.parse(m.group(1)!), name));
    }
  }
  slideNums.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  final fileDate = _fileDateFromPptx(zf, path);
  final pages = <PptxPage>[];
  for (final (no, part) in slideNums) {
    final root = parseXml(zf.read(part));
    if (root == null) {
      pages.add(PptxPage(no, '', ''));
      continue;
    }
    final (lines, firstText) = _joinRuns(root);
    final title = _pageTitle(root, firstText);
    final extra = <String>[];
    for (final (rtype, target) in _readRels(zf, part)) {
      final low = rtype.toLowerCase();
      // diagrams 文字并入对应页（diagramData/diagramDrawing 等）
      if (low.contains('diagram')) {
        final dRoot = parseXml(zf.read(target));
        if (dRoot != null) {
          final (dLines, _) = _joinRuns(dRoot);
          extra.addAll(dLines);
        }
      } else if (low.endsWith('/notesslide') || rtype.contains('notesSlide')) {
        // 备注按 rels 对应页（"/notesSlide".lower() == "/notesslide"）
        final nRoot = parseXml(zf.read(target));
        if (nRoot != null) {
          final (nLines, _) = _joinRuns(nRoot);
          extra.addAll(nLines);
        }
      }
    }
    final text = pyStrip([...lines, ...extra].join('\n'));
    pages.add(PptxPage(no, pyStrip(title), text));
  }
  // no 互异（slide{N}.xml 名唯一）→ 排序结果确定
  pages.sort((a, b) => a.no.compareTo(b.no));
  return (pages, fileDate);
}

// ----------------------------------------------------------------- 分块 ----

class _RawChunk {
  int pageStart;
  int pageEnd;
  String title;
  String text;
  _RawChunk(this.pageStart, this.pageEnd, this.title, this.text);
}

_RawChunk _makeChunk(List<PptxPage> pages) {
  var start = pages.first.no;
  var end = pages.first.no;
  for (final p in pages) {
    start = math.min(start, p.no);
    end = math.max(end, p.no);
  }
  final text = pyStrip(
    [
      for (final p in pages)
        if (p.text.isNotEmpty) p.text,
    ].join('\n'),
  );
  final sorted = [...pages]..sort((a, b) => a.no.compareTo(b.no));
  var title = '';
  for (final p in sorted) {
    if (p.title.isNotEmpty) {
      title = p.title; // 区间首页标题（首个有标题的页）
      break;
    }
  }
  return _RawChunk(start, end, title, text);
}

/// 等价 build_chunks：短页（<50 字，按码点）与相邻页合并、记页码区间。
/// 连续短页缓冲成段；长页吸收缓冲；结尾残余短页并入前一条 chunk
/// （每页都推 page_end，仅有文本的页追加 "\n"+text）；全部为空/短时合成
/// 一条；最后丢弃无文字 chunk（图片页）。
List<_RawChunk> _buildChunks(List<PptxPage> pages) {
  final chunks = <_RawChunk>[];
  var buf = <PptxPage>[];
  for (final page in pages) {
    if (page.text.runes.length < shortPageChars) {
      buf.add(page);
      continue;
    }
    final merged = [...buf, page];
    buf = [];
    chunks.add(_makeChunk(merged));
  }
  if (buf.isNotEmpty) {
    if (chunks.isNotEmpty) {
      final last = chunks.last;
      for (final page in buf) {
        last.pageEnd = page.no;
        if (page.text.isNotEmpty) {
          last.text = pyStrip('${last.text}\n${page.text}');
        }
      }
    } else {
      chunks.add(_makeChunk(buf));
    }
  }
  return [
    for (final c in chunks)
      if (c.text.isNotEmpty) c,
  ];
}

/// 等价 chunk_id_of："{subject}:{ppt}:p{页起}" 或 "…p{页起}-{页止}"。
String chunkIdOf(String subjectId, String pptId, int pageStart, int pageEnd) {
  final pages = pageEnd > pageStart ? 'p$pageStart-$pageEnd' : 'p$pageStart';
  return '$subjectId:$pptId:$pages';
}

// --------------------------------------------------------------- 入口 ----

/// 等价 extract_file：单文件抽取 → (deck_info, chunks)。
/// 超限/IO 错误抛异常；subject_id 空串/null → "unknown"；
/// source_type 为 null 时按父目录名推导（单文件口径），传串则原样使用。
(DeckInfo, List<PptxChunk>) extractFile(
  String path, {
  String? subjectId,
  String? sourceType,
  int maxFileMb = defaultMaxFileMb,
}) {
  final file = File(path);
  final size = file.lengthSync();
  if (maxFileMb > 0 && size > maxFileMb * 1024 * 1024) {
    throw FileTooBig(
      '${pyPathName(path)}（${(size / 1048576.0).toStringAsFixed(0)} MB'
      ' > 上限 $maxFileMb MB）',
    );
  }
  final subj = (subjectId == null || subjectId.isEmpty) ? 'unknown' : subjectId;
  final stype = sourceType ?? detectSourceType(pyPathParentName(path));
  final deck = pyPathStem(path);
  final (pages, fileDate) = parsePptx(path);
  final rawChunks = _buildChunks(pages);
  final chunks = <PptxChunk>[
    for (final c in rawChunks)
      PptxChunk(
        chunkId: chunkIdOf(subj, deck, c.pageStart, c.pageEnd),
        subjectId: subj,
        pptId: deck,
        deck: deck,
        pageStart: c.pageStart,
        pageEnd: c.pageEnd,
        title: c.title,
        text: c.text,
        sourceType: stype,
        fileDate: fileDate,
      ),
  ];
  final deckInfo = DeckInfo(
    subjectId: subj,
    pptId: deck,
    deck: deck,
    sourceType: stype,
    fileDate: fileDate,
    filePath: path,
    fileMd5: md5File(path),
    fileSize: size,
    fileMtime: file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000,
  );
  return (deckInfo, chunks);
}

/// 便捷：chunks → chunks.jsonl 文本（LF 行尾、末行带 \n，同 make_golden.py）。
String chunksToJsonl(List<PptxChunk> chunks) =>
    serializeChunksJsonl([for (final c in chunks) c.toOrderedMap()]);
