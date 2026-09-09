// 恒牙（hengya）· 端上语料抽取 · PDF 抽取（pdfium → chunks）
// ============================================================================
//
// Phase 3b 第二刀：移植自 automation/server-pipeline/extract_pdf.py
// （Python 参考实现，861 行，引擎 = PyMuPDF；对拍金样
// app/test/fixtures/golden/{endo_textbook_pdf, exam_assistant2023_pdf}
// _chunks.jsonl）。
//
// 引擎差异与验收口径（与 docx/pptx 的 byte-equal 硬门**不同**）：
//   Python 用 PyMuPDF（MuPDF 系结构化文本），Dart 用 pdfium（FPDFText
//   分段矩形行结构三件套，见 pdfium_ffi.dart 文件头）。行边界/空格注入/
//   分段粒度跨引擎必然不同 → manifest「逐字节一致」对 PDF 不可达成。
//   验收 = ①元数据硬对拍（页数/书签/creationDate 跨引擎一致）；
//   ②分块算法纯函数 1:1（textbookUnits/blocksFromUnits 等与 Python
//   self_test 同夹具同断言）；③真实 PDF 冒烟（exam 按页 19 chunks）+
//   Dart 自金样回归；④与 Python 金样的差异度实测报告（数字交付）。
//
// 移植范围（端上单文件抽取面）
// ----------------
//   教材书签单元切块（level-2 ∪ 孤儿 level-1 过滤非正文）、行内四级
//   标题递归切分（L1 第X节/L2 一、/L3 （一）/L4 1. 带防参考文献防小数
//   守卫）、裸节名吸收（仅标题路径）、标题路径去重折叠、短块双归并
//   （<150 向后并前 + 首短并后）、无书签降级按页、真题按页、超限拆分
//   -sN（教材 1600 / 其余 2500）、extractPdfFile 入口。树扫描/manifest
//   增量/CLI/toc sidecar 落盘属建库侧；chapters/sections 照常计算随
//   返回值带出（Phase 4 进度锚点）。
//
// 关键等价性决策（与 Python 逐点对拍）
// ------------------------------------
//   1. Python len() 按码点计数：短块阈值（<150）、语义分块块长
//      （SEMANTIC_SOFT_MAX=1600）、L4 守卫行长（≤45）、裸节名（≤6）与
//      吸收行（≤40）全部 runes.length（任务红线）。
//   2. 所有 .strip() 走 py_compat.pyStrip；正则语义逐字迁移
//      （re.match → 带 ^ 的 hasMatch；re.search → hasMatch）。
//   3. _split_paragraphs/_unique_chunk_id 复用 extract_docx.dart 唯一
//      实现（Python 侧两处同源复制，Dart 侧不复制）。
//   4. 块模型复用 extract_pptx 的 PptxChunk/DeckInfo/chunk_id_of/
//      detect_source_type/FileTooBig（chunks.jsonl 契约同构）。
//   5. 行级页源：块 page_start/page_end = 块首/末行所在页（教材语义
//      分块）；按页切块 = 页号。chunk_id 撞号兜底走 uniqueChunkId。
//   6. 加密 PDF（needs_pass）→ FormatException 中断（同 Python 抛错）。

import 'dart:io';
import 'dart:math' as math;

import 'extract_docx.dart'
    show TocChapter, TocSection, joinTitle, splitParagraphs, uniqueChunkId;
import 'extract_pptx.dart'
    show DeckInfo, FileTooBig, PptxChunk, chunkIdOf, detectSourceType;
import 'pdfium_ffi.dart';
import 'py_compat.dart';

// ---------------------------------------------------------------- 常量 ----

const defaultMaxFileMb = 250; // 单文件上限（教材最大 197MB，超 pptx 的 150）
const shortSectionChars = 150; // 教材短块阈值：<150 并入前块（首短块并入后块）
const semanticSoftMax = 1600; // 语义分块块长阈值；四级用尽仍超 → 段落兜底
const examPageSplitChars = 2500; // 非教材按页块上限：超过按段落拆分

// 孤儿 level-1 章（无 level-2 子女）的非正文过滤关键词：命中即维持丢弃。
final _noncontentL1Re = RegExp(
    r'目录|目录尾|索引|前言|参考文献|版权页|书名|封面|封页|附表|对照表');

// 行内标题层级模式（L1→L4）；L4 带防参考文献/防小数守卫（见 headingLevel）。
final _h1Re = RegExp(r'^第[一二三四五六七八九十百零]+节');
final _bareH1Re = RegExp(r'^第[一二三四五六七八九十百零]+节$');
final _h2Re = RegExp(r'^[一二三四五六七八九十]+、');
final _h3Re = RegExp(r'^[（(][一二三四五六七八九十]+[）)]');
final _h4Re = RegExp(r'^\d{1,2}[、.．]');
final _h4NumRe = RegExp(r'^\d{1,2}[、.．]\d'); // 小数/编号数字（28.9% 类）
final _h4BadRe = RegExp(r'[，,；;：]'); // 参考文献行句读特征
final _titleAbsorbBadRe = RegExp(r'[。！？；，,：:]'); // 裸节名吸收守卫

final _pdfDateRe = RegExp(r'D:(\d{4})(\d{2})(\d{2})');

// ---------------------------------------------------- 行内标题层级 ----

/// 等价 _heading_level：行内标题层级（1..4；非标题返回 0）。
/// L4 守卫：行长 ≤45（码点）且不含「，,；;：」，且非 `\d[.、．]\d`
/// 小数形态（实测 endo 610 条参考文献行全被滤除；28.9% 不算标题）。
int headingLevel(String ln) {
  if (_h1Re.hasMatch(ln)) return 1;
  if (_h2Re.hasMatch(ln)) return 2;
  if (_h3Re.hasMatch(ln)) return 3;
  if (_h4Re.hasMatch(ln) &&
      !_h4NumRe.hasMatch(ln) &&
      ln.runes.length <= 45 &&
      !_h4BadRe.hasMatch(ln)) {
    return 4;
  }
  return 0;
}

/// 等价 _heading_path_elem：标题路径元素。裸「第X节」（码点 ≤6）且下一
/// 行 ≤40 字、无句读、非标题行时吸收下一行（教材排版常将节号与节名拆
/// 两行）——**仅用于块标题路径，正文文本严禁改动**。
String headingPathElem(List<(int, String)> lines, int i) {
  final ln = lines[i].$2;
  if (_bareH1Re.hasMatch(ln) && ln.runes.length <= 6 && i + 1 < lines.length) {
    final nxt = lines[i + 1].$2;
    if (nxt.runes.length <= 40 &&
        !_titleAbsorbBadRe.hasMatch(nxt) &&
        headingLevel(nxt) == 0) {
      return '$ln $nxt';
    }
  }
  return ln;
}

/// 等价 _compose_title：块标题 = 单元题 + '·' + 标题路径。路径首部与
/// 单元题已有段重复的元素折叠（书签节名与行内节名同文的场景——
/// 避免「…第一节 X·第一节 X·一、Y」）。
String composeTitle(String unitTitle, List<String> path) {
  final segs = unitTitle.split('·').toSet();
  var i = 0;
  while (i < path.length && segs.contains(path[i])) {
    i++;
  }
  final rest = path.sublist(i);
  return rest.isEmpty ? unitTitle : '$unitTitle·${rest.join('·')}';
}

// ------------------------------------------------------------- 教材书签 ----

/// 等价 _clamp_page：书签页码 clamp 到 [1, pageCount]（PyMuPDF 页码恒
/// int，防御口径同 Python `int(pg or 1)`——无效 0/负按 1）。
int clampPage(int pg, int pageCount) =>
    math.min(math.max(pg, 1), math.max(pageCount, 1));

class TextbookUnit {
  final String title;
  final int pageStart;
  final int idx;
  int pageEnd = 0;
  TextbookUnit(this.title, this.pageStart, this.idx);
}

/// 等价 _textbook_units：书签 → 教材切块单位 [{title, page_start,
/// page_end}]；无书签返回 []。
///
/// 单元 = level-2 节/章（title=「章名·节名」，章名=其前最近 level-1）
/// ∪ **无 level-2 子女的 level-1 孤儿章**（此前整章静默丢弃——oms 教材
/// 第一章 绪论即因此缺失）。孤儿章经 _noncontentL1Re 过滤（目录/索引/
/// 前言/参考文献等非正文维持丢弃）。仅 level-1 无 level-2 时降级以章
/// 为单位。边界=其后下一条 level ≤ 2 书签的起始页-1（倒扫预计算，孤儿
/// 章同样覆盖）；同页多节 page_end 取 max(start, 边界)（页粒度共享，
/// chunk_id 撞号由 uniqueChunkId 兜底）。
List<TextbookUnit> textbookUnits(List<TocEntry> toc, int pageCount) {
  final sections = <TextbookUnit>[];
  // (title, pageStart, idx, orphan)
  final chaptersAsUnits = <(String, int, int, bool)>[];
  var curChapter = '';
  for (var idx = 0; idx < toc.length; idx++) {
    final e = toc[idx];
    final title = pyStrip(e.title);
    final pg = clampPage(e.page, pageCount);
    final nxtLvl = idx + 1 < toc.length ? toc[idx + 1].level : 0; // 尾条目无下一条
    if (e.level == 1) {
      curChapter = title;
      final orphan = idx + 1 < toc.length ? nxtLvl != 2 : true;
      chaptersAsUnits.add((title, pg, idx, orphan));
    } else if (e.level == 2) {
      sections.add(TextbookUnit(joinTitle(curChapter, title), pg, idx));
    }
  }
  List<TextbookUnit> units;
  if (sections.isNotEmpty) {
    units = [...sections];
    for (final (title, pg, idx, orphan) in chaptersAsUnits) {
      if (orphan && !_noncontentL1Re.hasMatch(title)) {
        units.add(TextbookUnit(title, pg, idx));
      }
    }
    units.sort((a, b) => a.idx.compareTo(b.idx)); // 书签原序（页序）
  } else {
    units = [
      for (final (title, pg, idx, _) in chaptersAsUnits)
        if (!_noncontentL1Re.hasMatch(title)) TextbookUnit(title, pg, idx),
    ];
  }
  if (units.isEmpty) return [];
  final cap = sections.isNotEmpty ? 2 : 1;
  // 倒扫一次预计算每个书签之后下一条 level≤cap 条目的起始页
  final bounds = List<int?>.filled(toc.length, null);
  int? nxt;
  for (var idx = toc.length - 1; idx >= 0; idx--) {
    bounds[idx] = nxt;
    if (toc[idx].level <= cap) {
      nxt = clampPage(toc[idx].page, pageCount);
    }
  }
  for (final u in units) {
    final nxtPg = bounds[u.idx];
    final end = nxtPg == null ? pageCount : nxtPg - 1;
    u.pageEnd = math.max(u.pageStart, end);
  }
  return units;
}

/// 等价 _sidecar_outline：书签 → sidecar 大纲（chapters=[{no,title,
/// page_start}]、sections=[{chapter_no,title,page_start}]，挂最近前一
/// 章；章前孤儿节丢弃）。结构与 extract_docx 的 TocChapter/TocSection
/// 一致，随返回值带出（toc sidecar 落盘属建库侧）。
({List<TocChapter> chapters, List<TocSection> sections})
    sidecarOutline(List<TocEntry> toc, int pageCount) {
  final chapters = <TocChapter>[];
  final sections = <TocSection>[];
  var chNo = 0;
  for (final e in toc) {
    final title = pyStrip(e.title);
    if (e.level == 1) {
      chNo++;
      chapters.add(TocChapter(chNo, title, clampPage(e.page, pageCount)));
    } else if (e.level == 2 && chNo > 0) {
      sections.add(TocSection(chNo, title, clampPage(e.page, pageCount)));
    }
  }
  return (chapters: chapters, sections: sections);
}

// ------------------------------------------------------------- 分块 ----

/// 等价 _rec_split：按标题层级递归切分（语义分块核心）→ out 收集
/// (path, lines)。块长（行字符和，码点）≤ SEMANTIC_SOFT_MAX 整块输出；
/// 更长则在 lvl 级标题行处切组递归；该级无边界（groups ≤ 1）→ 整体试
/// 下一级；四级用尽整块输出（>SOFT 由调用方走 splitParagraphs 兜底）。
/// 标题行本身入组（不丢内容）。
void _recSplit(
  List<(int, String)> lines,
  int lvl,
  List<String> path,
  List<(List<String>, List<(int, String)>)> out,
) {
  if (lines.isEmpty) return;
  var total = 0;
  for (final (_, ln) in lines) {
    total += ln.runes.length + 1;
  }
  if (lvl > 4 || total <= semanticSoftMax) {
    out.add((List<String>.of(path), lines));
    return;
  }
  final groups = <(List<String>, List<(int, String)>)>[];
  var cur = <(int, String)>[];
  var curPath = List<String>.of(path);
  for (var i = 0; i < lines.length; i++) {
    final item = lines[i];
    if (headingLevel(item.$2) == lvl && cur.isNotEmpty) {
      groups.add((curPath, cur));
      cur = [item];
      curPath = [...path, headingPathElem(lines, i)];
    } else {
      cur.add(item);
    }
  }
  if (cur.isNotEmpty) {
    groups.add((curPath, cur));
  }
  if (groups.length <= 1) {
    _recSplit(lines, lvl + 1, path, out); // 该级无边界 → 试下一级
    return;
  }
  for (final (gpath, glines) in groups) {
    _recSplit(glines, lvl + 1, gpath, out);
  }
}

class PdfBlock {
  int pageStart;
  int pageEnd;
  final String title;
  String text;
  PdfBlock(this.pageStart, this.pageEnd, this.title, this.text);
}

/// 等价 _blocks_from_units：书签单位 → 语义块。每块 title = 单元题 +
/// '·' + 行内标题路径（composeTitle 折叠）；page_start/page_end = 块首/
/// 末行所在页。短块（<150 字）并入前块（page_end 扩展、title 不变）；
/// 随后若首块仍短则并入后块（章节扉页/学习要点随首块走）。全流程确定
/// 性、重跑幂等；块序拼接可逐字还原单元文本（内容零丢失，>SOFT 的段落
/// 拆分件同样 \n 连接可还原）。
List<PdfBlock> blocksFromUnits(List<List<String>> pageLines, List<TextbookUnit> units) {
  final raw = <PdfBlock>[];
  for (final u in units) {
    final ulines = <(int, String)>[];
    for (var pg = u.pageStart; pg <= u.pageEnd; pg++) {
      for (final ln in pageLines[pg - 1]) {
        ulines.add((pg, ln));
      }
    }
    if (ulines.isEmpty) continue; // 空文本单元丢弃
    final parts = <(List<String>, List<(int, String)>)>[];
    _recSplit(ulines, 1, const [], parts);
    for (final (path, plines) in parts) {
      final text = [for (final (_, ln) in plines) ln].join('\n');
      if (text.isEmpty) continue;
      final title = composeTitle(u.title, path);
      raw.add(PdfBlock(plines.first.$1, plines.last.$1, title, text));
    }
  }
  // 短块归并：向后并入前块；随后若首块仍短则并入后块
  final blocks = <PdfBlock>[];
  for (final b in raw) {
    if (blocks.isNotEmpty && b.text.runes.length < shortSectionChars) {
      final prev = blocks.last;
      prev.pageEnd = math.max(prev.pageEnd, b.pageEnd);
      prev.text = '${prev.text}\n${b.text}';
    } else {
      blocks.add(b);
    }
  }
  if (blocks.length > 1 && blocks.first.text.runes.length < shortSectionChars) {
    final first = blocks.removeAt(0);
    final nxt = blocks.first;
    nxt.text = '${first.text}\n${nxt.text}';
    nxt.pageStart = first.pageStart;
  }
  return blocks;
}

/// 等价 _blocks_by_page：按页切块（真题库/无书签教材/ppt 源 PDF）：
/// 1 块/页，title=「{titlePrefix} p{N}」；空页跳过。
List<PdfBlock> blocksByPage(List<String> pageTexts, String titlePrefix) {
  final blocks = <PdfBlock>[];
  for (var i = 0; i < pageTexts.length; i++) {
    final text = pageTexts[i];
    if (text.isEmpty) continue;
    blocks.add(PdfBlock(i + 1, i + 1, '$titlePrefix p${i + 1}', text));
  }
  return blocks;
}

// ------------------------------------------------------------- 抽取 ----

/// 等价 _page_lines：页原始行 → 非空 pyStrip 行（语义分块的页源单元；
/// Python 侧 `page.get_text().splitlines()` + strip 过滤）。
List<String> _pyPageLines(List<String> rawLines) {
  final out = <String>[];
  for (final ln in rawLines) {
    final t = pyStrip(ln);
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

/// 等价 _file_date_from_pdf：PDF metadata creationDate（D:YYYYMMDD…）
/// → YYYY-MM-DD；缺/读取失败则文件 mtime；再失败 → ""（Python
/// `except Exception: pass` 同——metaText 读失败返回 '' 即不命中）。
String _fileDateFromPdf(PdfDocument doc, String fallbackPath) {
  final m = _pdfDateRe.firstMatch(doc.metaText('CreationDate'));
  if (m != null) {
    return '${m.group(1)}-${m.group(2)}-${m.group(3)}';
  }
  return fileMtimeIsoDate(fallbackPath);
}

/// 等价 extract_file（端上版）：单文件抽取 →
/// (deckInfo, chunks, chapters, sections)（与 extract_pptx/extract_docx
/// 同构）。超限抛 FileTooBig；加密 PDF 抛 FormatException；引擎打开
/// 失败抛 FormatException。subjectId 空串/null → "unknown"；sourceType
/// 为 null 时按父目录名推导（单文件口径）；maxFileMb 为 null/0 表示
/// 不校验大小（Python `if max_file_mb and …` 同）。
({DeckInfo deckInfo, List<PptxChunk> chunks, List<TocChapter> chapters,
    List<TocSection> sections})
extractPdfFile(
  String path, {
  String? subjectId,
  String? sourceType,
  int? maxFileMb,
}) {
  final file = File(path);
  final size = file.lengthSync();
  if (maxFileMb != null && maxFileMb != 0 && size > maxFileMb * 1024 * 1024) {
    throw FileTooBig(
      '${pyPathName(path)}（${(size / 1048576.0).toStringAsFixed(0)} MB'
      ' > 上限 $maxFileMb MB）',
    );
  }
  final subj = (subjectId == null || subjectId.isEmpty) ? 'unknown' : subjectId;
  final stype = sourceType ?? detectSourceType(pyPathParentName(path));
  final deck = pyPathStem(path);
  final doc = PdfDocument.open(path);
  List<PdfBlock> blocks;
  var chapters = <TocChapter>[];
  var sections = <TocSection>[];
  String fileDate;
  try {
    final pageCount = doc.pageCount;
    fileDate = _fileDateFromPdf(doc, path);
    final pageLines = <List<String>>[
      for (var i = 0; i < pageCount; i++) _pyPageLines(doc.rawPageLines(i)),
    ];
    final pageTexts = [for (final ls in pageLines) ls.join('\n')];
    if (stype == 'textbook') {
      final toc = doc.getToc();
      if (toc.isNotEmpty) {
        blocks = blocksFromUnits(pageLines, textbookUnits(toc, pageCount));
      } else {
        blocks = blocksByPage(pageTexts, deck); // 无书签降级按页
      }
      final outline = sidecarOutline(toc, pageCount);
      chapters = outline.chapters;
      sections = outline.sections;
    } else {
      // 真题库按页切块（答案与【解析】原样保留）；ppt/unknown 源的
      // PDF 同样按页（页≈幻灯片）
      blocks = blocksByPage(pageTexts, deck);
    }
  } finally {
    doc.close();
  }

  // 教材：语义分块后 >SEMANTIC_SOFT_MAX 的无更深边界块走段落兜底（1600）；
  // 非教材：按页块 >EXAM_PAGE_SPLIT_CHARS 按段落拆分（现状不变）
  final splitLimit = stype == 'textbook' ? semanticSoftMax : examPageSplitChars;
  final chunks = <PptxChunk>[];
  final taken = <String>{};
  for (final b in blocks) {
    final parts = b.text.runes.length > splitLimit
        ? splitParagraphs(b.text, splitLimit)
        : [b.text];
    final base = chunkIdOf(subj, deck, b.pageStart, b.pageEnd);
    for (var pi = 0; pi < parts.length; pi++) {
      final cid = uniqueChunkId(pi == 0 ? base : '$base-s${pi + 1}', taken);
      taken.add(cid);
      chunks.add(PptxChunk(
        chunkId: cid,
        subjectId: subj,
        pptId: deck,
        deck: deck,
        pageStart: b.pageStart,
        pageEnd: b.pageEnd,
        title: b.title,
        text: parts[pi],
        sourceType: stype,
        fileDate: fileDate,
      ));
    }
  }
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
  return (
    deckInfo: deckInfo,
    chunks: chunks,
    chapters: chapters,
    sections: sections,
  );
}
