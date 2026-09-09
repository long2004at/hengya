// 恒牙（hengya）· 端上语料抽取 · Word .docx 抽取（OOXML → chunks）
// ============================================================================
//
// Phase 3b 第一刀：移植自 automation/server-pipeline/extract_docx.py
// （Python 参考实现，848 行，纯标准库 zipfile + ElementTree；对拍金样
// app/test/fixtures/golden/assistant_syllabus_docx_chunks.jsonl）。
// 行为等价基准：同一源 docx 的 Dart 输出与 Python 金样逐字段、逐字节
// 一致（见 app/test/extract_docx_golden_test.dart）。
//
// 移植范围（端上单文件抽取面）
// ----------------
//   标题样式切块（word/styles.xml → headingLevels；H1=章、H2=节）、
//   短节并前块（<150）、表格行序列化（" | " 连接/嵌套表展平/单元格内
//   多段「；」连接）、伪标题 H1（「第X部分」短行兜底）、超限拆分
//   -sN（教材 4000 / 其余 2500）、无标题打包 part N、extractDocxFile
//   入口。树扫描/manifest 增量/CLI/toc sidecar 落盘属建库侧，端上
//   不做；chapters/sections（教材章节锚点）照常计算并随返回值带出，
//   供 Phase 4 进度锚点消费。
//
// 关键等价性决策（与 Python 逐点对拍）
// ------------------------------------
//   1. Python len() 按码点计数：短节阈值（<150）、块上限判定（>4000/
//      >2500）、伪标题长度（≤40）、超长单行硬切全部 text.runes.length，
//      不用 UTF-16 .length（任务红线）。
//   2. 所有 Python .strip() 走 py_compat.pyStrip（空白集≠Dart trim()）。
//   3. XML 解析/zip 读取用 ooxml.dart 共享层（Phase 3a 金样验证）；
//      ElementTree 的 find/findall 只查**直接**子元素（findChild/
//      findChildren）、.iter() 含自身全后代（iterAll）。
//   4. 块模型复用 extract_pptx 的 PptxChunk/DeckInfo/chunkIdOf/
//      detectSourceType/FileTooBig（chunks.jsonl 契约同构，字段序见
//      PptxChunk.toOrderedMap）。
//   5. w:delText（修订删除）与 w:instrText（域代码）不收——只匹配
//      w:t/w:tab/w:br/w:cr；w:sdt 内容控件 v1 不支持（同 Python：
//      body 直接子级只认 w:p / w:tbl，其余自然丢弃）。
//   6. word/document.xml 缺失 → FormatException（对应 Python ValueError
//      "坏 docx：缺 word/document.xml"）；解析失败 → FormatException
//      （Python 侧 ET.ParseError 向上传播中断，CLI exit 2——等价）。
//   7. FileTooBig 消息文案与 pptx 版对齐（%.0f 与 toStringAsFixed(0)
//      的取整差异仅错误文案，不进任何输出，已认可）。
//   8. chunk_id 撞号兜底与超限拆分后缀（-sN）逻辑同源复制自
//      extract_pdf.py 的 _unique_chunk_id/_split_paragraphs（Python 侧
//      两处实现逐字一致；Dart 侧唯一实现在本文件）。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'extract_pptx.dart'
    show DeckInfo, FileTooBig, PptxChunk, chunkIdOf, detectSourceType;
import 'ooxml.dart';
import 'py_compat.dart';

// ---------------------------------------------------------------- 常量 ----

const shortSectionChars = 150; // 短节阈值：<150 并入前块（Python len 按码点）
const maxSectionChars = 4000; // 教材块上限：超过按段落拆分
const examPackChars = 2500; // 非教材块上限/无标题降级打包粒度

const _wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
final _wStyle = '{$_wNs}style';
final _wStyleId = '{$_wNs}styleId';
final _wName = '{$_wNs}name';
final _wVal = '{$_wNs}val';
final _wPPr = '{$_wNs}pPr';
final _wOutlineLvl = '{$_wNs}outlineLvl';
final _wPStyle = '{$_wNs}pStyle';
final _wP = '{$_wNs}p';
final _wT = '{$_wNs}t';
final _wTab = '{$_wNs}tab';
final _wBr = '{$_wNs}br';
final _wCr = '{$_wNs}cr';
final _wTbl = '{$_wNs}tbl';
final _wTr = '{$_wNs}tr';
final _wTc = '{$_wNs}tc';
final _wBody = '{$_wNs}body';

final _coreCreatedRe =
    RegExp(r'<dcterms:created[^>]*>([^<]+)<', caseSensitive: false);
final _idSufRe = RegExp(r'-s(\d+)$');
final _headingNameRe =
    RegExp(r'^(?:heading|标题)\s*([1-9])$', caseSensitive: false);
// 伪标题 H1 兜底：无样式「第X部分」起头的短分层行（公文/大纲常见；
// 带制表符的目录条目、超长行不触发）
final _pseudoH1Re = RegExp(r'^第[一二三四五六七八九十百]+部分');
const _pseudoMaxLen = 40;

// ---------------------------------------------------- 教材章节锚点模型 ----

/// 章锚点（块序号作 page；docx 无页码）。结构与 Python toc sidecar 的
/// chapters 条目一致（no/title/page_start），供 Phase 4 进度锚点消费。
class TocChapter {
  final int no;
  final String title;
  final int pageStart;
  const TocChapter(this.no, this.title, this.pageStart);
}

/// 节锚点（挂章；page_start=块序号）。同上，结构对齐 toc sidecar。
class TocSection {
  final int chapterNo;
  final String title;
  final int pageStart;
  const TocSection(this.chapterNo, this.title, this.pageStart);
}

// ---------------------------------------------------------- 基础工具 ----

/// 等价 _split_paragraphs：超限文本按段落（行）拆分 → 每段 ≤ limit 字符
/// （按码点）；不丢内容。贪心装行；单行自身超限时按**码点**硬切（保证
/// 「不超限 + 不丢内容」双满足；正常路径无硬切时 "\n".join(parts) ==
/// text 可逐字还原）。BMP 快路径直接 substring；含代理对走 runes 切。
List<String> splitParagraphs(String text, int limit) {
  if (text.isEmpty) return [];
  limit = math.max(limit, 1);
  final parts = <String>[];
  var cur = <String>[];
  var curLen = 0;
  for (final para in text.split('\n')) {
    if (para.runes.length > limit) {
      // 超长单行硬切
      if (cur.isNotEmpty) {
        parts.add(cur.join('\n'));
        cur = [];
        curLen = 0;
      }
      if (!_hasSurrogate(para)) {
        // BMP 快路径：UTF-16 长度 == 码点数
        for (var i = 0; i < para.length; i += limit) {
          final end = math.min(i + limit, para.length);
          parts.add(para.substring(i, end));
        }
      } else {
        // 含代理对（emoji/扩展区）：按码点切，不拆半个字符
        final cps = para.runes.toList();
        for (var i = 0; i < cps.length; i += limit) {
          final end = math.min(i + limit, cps.length);
          parts.add(String.fromCharCodes(cps, i, end));
        }
      }
      continue;
    }
    final grow = para.runes.length + (cur.isNotEmpty ? 1 : 0); // 含与前段的换行
    if (cur.isNotEmpty && curLen + grow > limit) {
      parts.add(cur.join('\n'));
      cur = [para];
      curLen = para.runes.length;
    } else {
      cur.add(para);
      curLen += grow;
    }
  }
  if (cur.isNotEmpty) {
    parts.add(cur.join('\n'));
  }
  return parts;
}

bool _hasSurrogate(String s) {
  for (final cu in s.codeUnits) {
    if (cu >= 0xd800 && cu <= 0xdfff) return true;
  }
  return false;
}

/// 等价 _unique_chunk_id：chunk_id 撞号兜底（同块多拆分、后缀二次冲突）
/// → 追加最小可用 -sN。`-s(\d+)$` 命中则续号，否则从 -s2 起新号。
/// （extract_pdf.dart 复用本函数——Python 侧两处实现逐字一致，Dart 侧
/// 唯一实现在此，勿另写副本。）
String uniqueChunkId(String base, Set<String> taken) {
  if (!taken.contains(base)) return base;
  final m = _idSufRe.firstMatch(base);
  String stem;
  int n;
  if (m != null) {
    stem = base.substring(0, m.start);
    n = int.parse(m.group(1)!);
  } else {
    stem = base;
    n = 1;
  }
  while (true) {
    n++;
    final cand = '$stem-s$n';
    if (!taken.contains(cand)) return cand;
  }
}

/// 等价 _join_title：节标题 = 「章名·节名」；无章名（书签缺级）时仅节名。
String joinTitle(String chapter, String section) {
  if (chapter.isNotEmpty && section.isNotEmpty) {
    return '$chapter·$section';
  }
  return section.isNotEmpty ? section : chapter;
}

/// 等价 _file_date_from_docx：docProps/core.xml dcterms:created →
/// YYYY-MM-DD；缺/坏则文件 mtime（本地时区日期）；再失败 → ""。
String _fileDateFromDocx(ZipReader zf, String fallbackPath) {
  final data = zf.read('docProps/core.xml');
  if (data != null && data.isNotEmpty) {
    final decoded = utf8.decode(data, allowMalformed: true); // ~ errors="replace"
    final m = _coreCreatedRe.firstMatch(decoded);
    if (m != null) {
      final d = pyDateFromIso(pyStrip(m.group(1)!).replaceAll('Z', '+00:00'));
      if (d != null) return d;
    }
  }
  return fileMtimeIsoDate(fallbackPath);
}

// ------------------------------------------------------------- OOXML 解析 ----

/// 等价 _heading_levels：word/styles.xml → styleId → 标题级别 int（1..9）。
/// w:name 匹配 heading N / 标题 N（Word 内建样式 XML 里通常存英文名，
/// zh 文档亦见「标题 N」），或 w:pPr/w:outlineLvl（val=N → 级别 N+1）。
/// styles.xml 缺失/解析失败返回 {}（文档按无标题降级打包）。
/// Python `if lvl:` 语义（None 与 0 均弃）→ `lvl != null && lvl != 0`。
Map<String, int> headingLevels(ZipReader zf) {
  final data = zf.read('word/styles.xml');
  if (data == null) return {};
  final root = parseXml(data);
  if (root == null) return {};
  final out = <String, int>{};
  for (final st in iterTag(root, _wStyle)) {
    final sid = st.attrs[_wStyleId];
    if (sid == null || sid.isEmpty) continue;
    int? lvl;
    final name = findChild(st, _wName);
    final nm = pyStrip(name?.attrs[_wVal] ?? '');
    final m = _headingNameRe.firstMatch(nm);
    if (m != null) {
      lvl = int.parse(m.group(1)!);
    } else {
      final ppr = findChild(st, _wPPr);
      final ol = ppr == null ? null : findChild(ppr, _wOutlineLvl);
      if (ol != null) {
        final v = int.tryParse(pyStrip(ol.attrs[_wVal] ?? ''));
        if (v != null) lvl = v + 1;
      }
    }
    if (lvl != null && lvl != 0) {
      out[sid] = lvl;
    }
  }
  return out;
}

/// 等价 _para_text：段落文本——w:t 收集（w:tab→\t、w:br/w:cr→\n）；
/// w:delText（修订删除）与 w:instrText（域代码）不收（只匹配白名单
/// tag）。iterAll 含 p 自身（同 Python `p.iter()`）。
String _paraText(XElem p) {
  final buf = <String>[];
  for (final node in iterAll(p)) {
    final tag = node.tag;
    if (tag == _wT) {
      buf.add(node.text ?? '');
    } else if (tag == _wTab) {
      buf.add('\t');
    } else if (tag == _wBr || tag == _wCr) {
      buf.add('\n');
    }
  }
  return buf.join();
}

/// 等价 _para_level：段落标题级别（1..9）——w:pPr/w:outlineLvl 直标
/// 优先（int 失败落到 pStyle，同 Python except 后 pass），否则
/// pStyle 查表（表无该 styleId → null）。
int? _paraLevel(XElem p, Map<String, int> styleLevels) {
  final ppr = findChild(p, _wPPr);
  if (ppr == null) return null;
  final ol = findChild(ppr, _wOutlineLvl);
  if (ol != null) {
    final v = int.tryParse(pyStrip(ol.attrs[_wVal] ?? ''));
    if (v != null) return v + 1;
  }
  final ps = findChild(ppr, _wPStyle);
  if (ps != null) {
    return styleLevels[ps.attrs[_wVal] ?? ''];
  }
  return null;
}

/// 等价 _table_lines：表格 → 行文本列表——单元格文本 " | " 连接（空单元
/// 格剔除：strip 后空则不入 row）；单元格内多段以「；」连接；嵌套表递归
/// 展平为该单元格文本的一部分（其非空行并入 parts）。
List<String> _tableLines(XElem tbl) {
  final lines = <String>[];
  for (final tr in findChildren(tbl, _wTr)) {
    final cells = <String>[];
    for (final tc in findChildren(tr, _wTc)) {
      final parts = <String>[];
      for (final el in tc.children) {
        // 只看 tc 的**直接**子元素（文档序；同 Python `for el in tc`）
        if (el.tag == _wP) {
          final txt = pyStrip(_paraText(el));
          if (txt.isNotEmpty) parts.add(txt);
        } else if (el.tag == _wTbl) {
          parts.addAll(_tableLines(el).where((x) => x.isNotEmpty));
        }
      }
      cells.add(parts.join('；'));
    }
    final row = [
      for (final c in cells)
        if (pyStrip(c).isNotEmpty) c,
    ].join(' | ');
    if (pyStrip(row).isNotEmpty) lines.add(row);
  }
  return lines;
}

/// 等价 _pseudo_h1：无样式「第X部分」起头的短分层行判定（≤40 字**按
/// 码点**、不含制表符；目录条目带 \t页码、超长行不触发）。段落与表格
/// 行通用。
bool _pseudoH1(String txt) =>
    txt.runes.length <= _pseudoMaxLen &&
    !txt.contains('\t') &&
    _pseudoH1Re.hasMatch(txt);

class _BodyItem {
  final bool isHeading;
  final int level;
  final String text;
  const _BodyItem.heading(this.level, this.text) : isHeading = true;
  const _BodyItem.line(this.text)
      : isHeading = false,
        level = 0;
}

/// 等价 _walk_body（签名调整：document.xml 的读取/解析上提到入口，见
/// extractDocxFile 决策 6）：body 直接子级按文档序产出——w:p：空段跳
/// 过，样式/直标级别 ∈ {1,2} → heading，伪标题 → heading(1)，否则
/// line；w:tbl：每行展平后伪标题判定 → heading(1)/line；**w:sdt（内
/// 容控件）等其余元素丢弃**（同 Python v1 不支持）。
List<_BodyItem> _walkBody(XElem docRoot, Map<String, int> styleLevels) {
  final body = findChild(docRoot, _wBody);
  if (body == null) return [];
  final items = <_BodyItem>[];
  for (final el in body.children) {
    if (el.tag == _wP) {
      final txt = pyStrip(_paraText(el));
      if (txt.isEmpty) continue;
      final lvl = _paraLevel(el, styleLevels);
      if (lvl != null && (lvl == 1 || lvl == 2)) {
        items.add(_BodyItem.heading(lvl, txt));
      } else if (_pseudoH1(txt)) {
        items.add(_BodyItem.heading(1, txt)); // 伪标题 H1（无样式分层行）
      } else {
        items.add(_BodyItem.line(txt));
      }
    } else if (el.tag == _wTbl) {
      for (final ln in _tableLines(el)) {
        if (_pseudoH1(ln)) {
          items.add(_BodyItem.heading(1, ln)); // 表格行伪标题（考纲分层行）
        } else {
          items.add(_BodyItem.line(ln));
        }
      }
    }
    // 其余（w:sdt 等）：丢弃（同 Python v1）
  }
  return items;
}

// ------------------------------------------------------------- 分块 ----

class _Block {
  final int seq;
  final String title;
  final String text;
  const _Block(this.seq, this.title, this.text);
}

/// 等价 _blocks_from_headings：标题驱动切块 → (blocks, chapters,
/// sections)。H1/H2 设界（更深层标题视作正文行）；块 seq=单位开张序号
/// （1 基，仅标题计）。首标题前的行丢弃（封面/文头，同 extract_pdf
/// 书签前页口径）；标题行入块文本（lines[0]=raw）。
({List<_Block> blocks, List<TocChapter> chapters, List<TocSection> sections})
    _blocksFromHeadings(List<_BodyItem> items) {
  final blocks = <_Block>[];
  final chapters = <TocChapter>[];
  final sections = <TocSection>[];
  var seq = 0;
  var chNo = 0;
  var curCh = '';
  int? curSeq;
  var curTitle = '';
  var curLines = <String>[];

  for (final item in items) {
    if (item.isHeading) {
      if (curSeq != null && curLines.isNotEmpty) {
        blocks.add(_Block(curSeq, curTitle, curLines.join('\n')));
      }
      seq++;
      final raw = item.text;
      String title;
      if (item.level == 1) {
        chNo++;
        curCh = raw;
        title = raw;
        chapters.add(TocChapter(chNo, raw, seq));
      } else {
        title = joinTitle(curCh, raw);
        if (chNo > 0) {
          sections.add(TocSection(chNo, raw, seq));
        }
      }
      curSeq = seq;
      curTitle = title;
      curLines = [raw];
    } else {
      if (curSeq == null) continue; // 首标题前内容丢弃
      curLines.add(item.text);
    }
  }
  if (curSeq != null && curLines.isNotEmpty) {
    blocks.add(_Block(curSeq, curTitle, curLines.join('\n')));
  }
  return (blocks: blocks, chapters: chapters, sections: sections);
}

class _Section {
  int pageStart;
  int pageEnd;
  final String title;
  String text;
  _Section(this.pageStart, this.pageEnd, this.title, this.text);
}

/// 等价 _finalize_blocks：<shortSectionChars 并前块（page_end 扩展、
/// title 不变）→ [{page_start, page_end, title, text}]（docx 块序号
/// 即 page）。空文本块丢弃（防御；标题行恒在，实际不触发）。
List<_Section> _finalizeBlocks(List<_Block> blocks) {
  final out = <_Section>[];
  for (final b in blocks) {
    if (b.text.isEmpty) continue;
    if (out.isNotEmpty && b.text.runes.length < shortSectionChars) {
      final prev = out.last; // 短节并入前块
      prev.pageEnd = math.max(prev.pageEnd, b.seq);
      prev.text = '${prev.text}\n${b.text}';
    } else {
      out.add(_Section(b.seq, b.seq, b.title, b.text));
    }
  }
  return out;
}

/// 等价 _blocks_by_pack：无标题降级——整文档按段落打包 ≤examPackChars，
/// title=「{deck} part {N}」（N=枚举序 1 基=块序号；空 part 跳过但
/// 不占 N 之外的新号，同 Python `for i, p in enumerate(parts) if p`）。
List<_Section> _blocksByPack(List<String> lines, String deck) {
  final parts = splitParagraphs(lines.join('\n'), examPackChars);
  final out = <_Section>[];
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    if (p.isNotEmpty) {
      out.add(_Section(i + 1, i + 1, '$deck part ${i + 1}', p));
    }
  }
  return out;
}

// --------------------------------------------------------------- 入口 ----

/// 等价 extract_file（端上版）：单文件抽取 →
/// (deckInfo, chunks, chapters, sections)（与 extract_pptx 同构；toc
/// sidecar 落盘属建库侧不做，chapters/sections 随返回值带出）。
///
/// 超限抛 FileTooBig；word/document.xml 缺失/解析失败抛 FormatException
///（等价中断，见文件头决策 6）。subjectId 空串/null → "unknown"；
/// sourceType 为 null 时按父目录名推导（单文件口径）；maxFileMb 为
/// null/0 表示不校验大小（Python `if max_file_mb and …` 同）。
({DeckInfo deckInfo, List<PptxChunk> chunks, List<TocChapter> chapters,
    List<TocSection> sections})
extractDocxFile(
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
  final zf = ZipReader.open(path);
  final fileDate = _fileDateFromDocx(zf, path);
  final docData = zf.read('word/document.xml');
  if (docData == null) {
    throw const FormatException('坏 docx：缺 word/document.xml');
  }
  final docRoot = parseXml(docData);
  if (docRoot == null) {
    throw const FormatException('坏 docx：word/document.xml 解析失败');
  }
  final items = _walkBody(docRoot, headingLevels(zf));

  List<_Section> blocks;
  var chapters = <TocChapter>[];
  var sections = <TocSection>[];
  if (items.any((i) => i.isHeading)) {
    final r = _blocksFromHeadings(items);
    chapters = r.chapters;
    sections = r.sections;
    blocks = _finalizeBlocks(r.blocks);
  } else {
    blocks = _blocksByPack([for (final i in items) i.text], deck);
  }

  final splitLimit = stype == 'textbook' ? maxSectionChars : examPackChars;
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
