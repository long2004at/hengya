// 恒牙（hengya）· 大纲 DOCX 结构化解析 + 细目打标（节点④）
// ============================================================================
//
// 输入：口腔执业/助理医师资格考试大纲 .docx（上会话纯 Python 已验证结构）：
//   - 正文 = 一张三列（执业）或四列（助理，第 4 列=「要求」掌握/熟悉/了解，
//     解析忽略）表格：列 = 单元 | 细目 | 要点；
//   - 部分行与学科行 = 单格 gridSpan 大标题（执业 5 部分 / 助理 4 部分；
//     「口腔医学综合」为口腔部分，其余人文/基础/临床/预防四部分归 med）；
//   - 学科下有「单 元|细 目|要 点」表头行（助理为 …|要 求）；
//   - 数据行单元/细目列 vMerge restart/cont 纵向合并（跨行继承），要点列
//     每行一条（（1）（2）…）；部分（执业第三/四部分=临床/预防）无学科级，
//     部分标题后直接是表头+单元数据行。
//   重建五级条目树：部分 → 学科 → 单元 → 细目 → 要点。
//
// 产物：corpus.db 新表 outline_entries（level 区分执业 zhiye / 助理 zhuli，
// 两版都入库）；入库幂等（按 level 整体替换 + meta md5 跳过未变文件）。
//
// 学科→短码映射（用户拍板 C 项清单）：口腔组织病理学→patho、口腔解剖
// 生理学→anatomy、牙体牙髓病学→endo、牙周病学→peri、口腔黏膜病学→
// mucosa、口腔颌面外科学→oms、口腔修复学→prostho、口腔颌面医学影像
// （诊断）学→imaging、儿童口腔医学→pedo、口腔预防医学→prevent；正畸/
// 种植等无映射学科 → 跳过入库并在解析报告（skippedSubjects）列出。
// 注：真实 2024 执业大纲该学科全名为「口腔颌面医学影像诊断学」，映射表
// 两种拼写都收（规格名 + 实测名）。
//
// med 占位（A5 拍板）：非「口腔医学综合」部分（人文/基础/临床/预防）条目
// subject 一律归 'med'（占位科目「医学综合」，无罗盘不参与复习提示；
// subjects 行 + progress.json 占位由 corpus_build_job.ensureMedSubject-
// Placeholder 在大纲落库后自动确保——本文件只管 outline_entries）。
// 本批绝不为 med 建语料树/拆卡。
//
// 证据隔离（F 项）：-outline 源文件不进常规语料块（extractAllCorpus 直接
// 跳过、不进 chunks.jsonl/manifest），数据只入 outline_entries；出卡证据
// 侧由 run_engine.examDeckOk 的 source_type=='outline' 加固兜底。
//
// 细目打标（E 项）：拆卡流水线出卡后，对关键词及其子考点文本（节点②的
// plan 结构）在执业树细目级做词面强命中——命中 → 该关键词本批全部卡
// tags 追加「大纲：{单元}＞{细目}」（序号前缀剥除，每卡此类标签
// ≤kMaxOutlineTagsPerCard，未命中不强推）。归一复用 run_engine
// normChapterTitle（去空白）既有设施。
//
// 纯 Dart（dart:io + package:sqlite3/crypto/archive），不 import Flutter。
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/sqlite3.dart';

import 'ooxml.dart';
import 'py_compat.dart' show pyPathName, pyStrip;
import 'run_engine.dart' show normChapterTitle;

// ------------------------------------------------------------- 常量 ----

/// 执业版 level 值（outline_entries.level）。
const String kOutlineLevelZhiye = 'zhiye';

/// 助理版 level 值。
const String kOutlineLevelZhuli = 'zhuli';

/// 口腔部分名（该部分下的学科走短码映射；其余部分归 med）。
const String kOutlineOralPartName = '口腔医学综合';

/// med 占位科目（A5 拍板）：短码与显示名。
const String kMedSubjectCode = 'med';
const String kMedSubjectName = '医学综合';

/// 大纲上传固定短码（上传链路落盘 incoming/dagang-outline/）。
const String kOutlineUploadCode = 'dagang';

/// 每卡「大纲：」类标签上限（E 项拍板 ≤3）。
const int kMaxOutlineTagsPerCard = 3;

/// 大纲标签前缀（完整形态「大纲：{单元}＞{细目}」，全角＞）。
const String kOutlineTagPrefix = '大纲：';

/// 学科 → 短码映射（口腔医学综合部分；两种影像拼写都收，见文件头注）。
const Map<String, String> kOutlineSubjectCodes = {
  '口腔组织病理学': 'patho',
  '口腔解剖生理学': 'anatomy',
  '牙体牙髓病学': 'endo',
  '牙周病学': 'peri',
  '口腔黏膜病学': 'mucosa',
  '口腔颌面外科学': 'oms',
  '口腔修复学': 'prostho',
  '口腔颌面医学影像学': 'imaging',
  '口腔颌面医学影像诊断学': 'imaging',
  '儿童口腔医学': 'pedo',
  '口腔预防医学': 'prevent',
};

/// outline_entries 契约 DDL（照 corpus.db 既有 CREATE TABLE IF NOT EXISTS
/// 风格；ensureCorpusSchema 一并建表，旧库由 ingestOutlineFiles 兜底建）。
const String schemaOutlineEntries = '''
CREATE TABLE IF NOT EXISTS outline_entries (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  level        TEXT NOT NULL,
  part         TEXT NOT NULL,
  subject      TEXT NOT NULL,
  subject_name TEXT NOT NULL DEFAULT '',
  unit         TEXT NOT NULL,
  subtopic     TEXT NOT NULL,
  point        TEXT NOT NULL,
  path         TEXT NOT NULL,
  seq          INTEGER NOT NULL
)''';
const String schemaOutlineIndex =
    'CREATE INDEX IF NOT EXISTS idx_outline_level_subject '
    'ON outline_entries(level, subject)';

// ------------------------------------------------------------- 模型 ----

/// 一条大纲条目（要点级；五级树的叶子）。
class OutlineEntry {
  const OutlineEntry({
    required this.part,
    required this.subject,
    required this.subjectName,
    required this.unit,
    required this.subtopic,
    required this.point,
    required this.path,
    required this.seq,
  });

  /// 部分名（如「第五部分 口腔医学综合」）。
  final String part;

  /// 学科短码（口腔部分 = kOutlineSubjectCodes 值；非口腔部分恒 'med'）。
  final String subject;

  /// 学科原文（如「牙体牙髓病学」；无学科级的部分（临床/预防）为空串）。
  final String subjectName;

  /// 单元（原文含序号，如「一、龋病」）。
  final String unit;

  /// 细目（原文含序号，如「1．概述」）。
  final String subtopic;

  /// 要点（如「（1）定义、病因和发病机制」）。
  final String point;

  /// 全路径（部分＞学科＞单元＞细目＞要点，全角＞连接）。
  final String path;

  /// 文档行序（1 基，同 level 内按解析顺序递增）。
  final int seq;
}

/// 解析统计（一次性脚本/报告对照基准用；列非空计数含表头行，单元列含
/// 单格标题行——与上会话 Python dump 的 col0/col1/col2 口径一致）。
class OutlineParseStats {
  int totalRows = 0;
  int partRows = 0;
  int subjectRows = 0;
  int descRows = 0; // 单格但非部分/学科（部分说明行等）
  int headerRows = 0; // 「单元|细目|要点(要求)」表头行
  int dataRows = 0; // 三列及以上数据行（含表头外的全部）
  int unitNonempty = 0; // 第 0 列文本非空行数（含单格标题行）
  int subtopicNonempty = 0; // 第 1 列文本非空行数
  int pointNonempty = 0; // 第 2 列文本非空行数
  int entries = 0; // 实际入库条目（要点非空且学科可归属）
  int medEntries = 0; // 归 med 的条目

  Map<String, Object?> toJson() => {
    'total_rows': totalRows,
    'part_rows': partRows,
    'subject_rows': subjectRows,
    'desc_rows': descRows,
    'header_rows': headerRows,
    'data_rows': dataRows,
    'unit_nonempty': unitNonempty,
    'subtopic_nonempty': subtopicNonempty,
    'point_nonempty': pointNonempty,
    'entries': entries,
    'med_entries': medEntries,
  };
}

/// 解析结果：条目 + 统计 + 无映射学科清单（解析报告）。
class OutlineParseResult {
  const OutlineParseResult({
    required this.level,
    required this.entries,
    required this.stats,
    required this.skippedSubjects,
  });

  final String level;
  final List<OutlineEntry> entries;
  final OutlineParseStats stats;
  final List<String> skippedSubjects;
}

// ------------------------------------------------------- OOXML 工具 ----

const _wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
final _wBody = '{$_wNs}body';
final _wTbl = '{$_wNs}tbl';
final _wTr = '{$_wNs}tr';
final _wTc = '{$_wNs}tc';
final _wTcPr = '{$_wNs}tcPr';
final _wVMerge = '{$_wNs}vMerge';
final _wVal = '{$_wNs}val';
final _wP = '{$_wNs}p';
final _wT = '{$_wNs}t';
final _wTab = '{$_wNs}tab';
final _wBr = '{$_wNs}br';
final _wCr = '{$_wNs}cr';

final _partRe = RegExp(r'^第[一二三四五六七八九十百]+部分');
final _subjectRe = RegExp(r'^[一二三四五六七八九十百]+、');
// 序号前缀剥除（打标显示名用）：「一、龋病」→「龋病」；「1．概述」→「概述」。
final _ordinalPrefixRe = RegExp(r'^\s*(?:[一二三四五六七八九十百零]+\s*、|\d+\s*[．.、])\s*');

/// 段落文本（w:t 收集；w:tab→\t、w:br/w:cr→\n；同 extract_docx 白名单）。
String _paraText(XElem p) {
  final buf = <String>[];
  for (final node in iterAll(p)) {
    if (node.tag == _wT) {
      buf.add(node.text ?? '');
    } else if (node.tag == _wTab) {
      buf.add('\t');
    } else if (node.tag == _wBr || node.tag == _wCr) {
      buf.add('\n');
    }
  }
  return buf.join();
}

/// 单元格文本：非空段落以空格连接（多段单元格罕见；口径同上会话探针）。
String _cellText(XElem tc) {
  final parts = <String>[];
  for (final el in tc.children) {
    if (el.tag != _wP) continue;
    final t = pyStrip(_paraText(el));
    if (t.isNotEmpty) parts.add(t);
  }
  return parts.join(' ');
}

/// vMerge 续行判定：tcPr/vMerge 存在且 val != 'restart'（无 val = cont）。
bool _vmergeCont(XElem tc) {
  final tcpr = findChild(tc, _wTcPr);
  if (tcpr == null) return false;
  final v = findChild(tcpr, _wVMerge);
  if (v == null) return false;
  return (v.attrs[_wVal] ?? 'cont') != 'restart';
}

/// 去全部空白（表头/部分/学科判定用）。
String _nospace(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// 剥序号前缀（打标显示名）：单元「一、龋病」→「龋病」、细目「1．概述」→「概述」。
String stripOutlineOrdinal(String s) =>
    s.replaceFirst(_ordinalPrefixRe, '').trim();

// ------------------------------------------------------------- 解析 ----

/// 解析大纲 DOCX → 五级条目树（部分→学科→单元→细目→要点）。
///
/// [level] 由调用方按文件名判定（[outlineLevelOfFilename]）；坏 docx
/// （缺 word/document.xml / 解析失败）抛 FormatException（同 extract_docx
/// 口径）。vMerge 续行继承上一 restart 的单元/细目（cont 单元格文本忽略
/// ——Word 展示语义）；非 cont 且文本非空 → 新值；表头行（单元|细目|要点
/// [要求]）跳过。
OutlineParseResult parseOutlineDocx(String path, {required String level}) {
  final zf = ZipReader.open(path);
  final docData = zf.read('word/document.xml');
  if (docData == null) {
    throw const FormatException('坏大纲 docx：缺 word/document.xml');
  }
  final docRoot = parseXml(docData);
  if (docRoot == null) {
    throw const FormatException('坏大纲 docx：word/document.xml 解析失败');
  }
  final body = findChild(docRoot, _wBody);
  if (body == null) {
    throw const FormatException('坏大纲 docx：缺 w:body');
  }

  final stats = OutlineParseStats();
  final entries = <OutlineEntry>[];
  final skippedSubjects = <String>[];
  var seq = 0;

  // 跨表/跨行继承态（多张表按文档序共享状态）
  var curPart = '';
  var curPartOral = false;
  var curSubjectName = '';
  var curUnit = '';
  var curSubtopic = '';

  for (final tbl in findChildren(body, _wTbl)) {
    for (final tr in findChildren(tbl, _wTr)) {
      final tcs = findChildren(tr, _wTc);
      stats.totalRows++;
      if (tcs.length == 1) {
        // 单格行：部分标题 / 学科标题 / 说明行
        final raw = _cellText(tcs[0]);
        final t = _nospace(raw);
        if (t.isNotEmpty) stats.unitNonempty++;
        if (t.isEmpty) {
          continue; // 空单格行
        }
        final pm = _partRe.firstMatch(t);
        if (pm != null) {
          stats.partRows++;
          curPart = '${pm.group(0)} ${t.substring(pm.end)}';
          curPartOral = t.substring(pm.end) == kOutlineOralPartName;
          curSubjectName = '';
          curUnit = '';
          curSubtopic = '';
        } else if (_subjectRe.hasMatch(t)) {
          stats.subjectRows++;
          final name = t.replaceFirst(_subjectRe, '');
          curSubjectName = name;
          curUnit = '';
          curSubtopic = '';
          // 口腔部分的无映射学科在此只记名（数据行逐条跳过并计数）
          if (curPartOral &&
              !kOutlineSubjectCodes.containsKey(name) &&
              !skippedSubjects.contains(name)) {
            skippedSubjects.add(name);
          }
        } else {
          stats.descRows++; // 部分说明行（「主要包括…」）
        }
        continue;
      }
      if (tcs.length < 3) {
        continue; // 异常行（既非单格标题也非三列数据）——如实计数后跳过
      }
      // 数据行（≥3 列；助理第 4 列「要求」忽略）
      final u0 = _cellText(tcs[0]);
      final s0 = _cellText(tcs[1]);
      final p0 = _cellText(tcs[2]);
      if (u0.isNotEmpty) stats.unitNonempty++;
      if (s0.isNotEmpty) stats.subtopicNonempty++;
      if (p0.isNotEmpty) stats.pointNonempty++;
      // 表头行：单元|细目|要点（|要求）
      if (_nospace(u0) == '单元' &&
          _nospace(s0) == '细目' &&
          _nospace(p0) == '要点') {
        stats.headerRows++;
        continue;
      }
      stats.dataRows++;
      // vMerge 继承：cont 单元格忽略文本沿用上一值；非 cont 且非空 → 新值
      if (!_vmergeCont(tcs[0]) && u0.isNotEmpty) curUnit = u0;
      if (!_vmergeCont(tcs[1]) && s0.isNotEmpty) curSubtopic = s0;
      if (p0.isEmpty) continue; // 无要点不产条目
      if (curPart.isEmpty) continue; // 首个部分标题前不产条目（防御）
      final subject = curPartOral
          ? (kOutlineSubjectCodes[curSubjectName] ?? '')
          : kMedSubjectCode;
      if (subject.isEmpty) continue; // 口腔部分无映射学科（已记 skippedSubjects）
      seq++;
      final pathSegs = [
        curPart,
        if (curSubjectName.isNotEmpty) curSubjectName,
        curUnit,
        curSubtopic,
        p0,
      ];
      entries.add(
        OutlineEntry(
          part: curPart,
          subject: subject,
          subjectName: curSubjectName,
          unit: curUnit,
          subtopic: curSubtopic,
          point: p0,
          path: pathSegs.join('＞'),
          seq: seq,
        ),
      );
      stats.entries++;
      if (subject == kMedSubjectCode) stats.medEntries++;
    }
  }
  return OutlineParseResult(
    level: level,
    entries: entries,
    stats: stats,
    skippedSubjects: skippedSubjects,
  );
}

/// 按上传文件名识别版本：文件名含「助理」→ zhuli，否则 zhiye（G 项拍板，
/// 两份真实文件名「2-口腔执业医师资格考试大纲.docx」/
/// 「6-口腔执业助理医师资格考试大纲.docx」实测可分）。
String outlineLevelOfFilename(String filename) {
  final name = pyPathName(filename);
  return name.contains('助理') ? kOutlineLevelZhuli : kOutlineLevelZhiye;
}

// ------------------------------------------------------------- 入库 ----

/// 建 outline_entries 表 + 索引（幂等；ensureCorpusSchema 与
/// ingestOutlineFiles 都会调用）。meta 表一并兜底建（仅大纲入库的
/// 全新库——0 chunks 不走 ingestCorpus/ensureCorpusSchema——否则 md5
/// 记录无处落；DDL 与 extract_all.schemaMeta 逐字一致）。
void ensureOutlineSchema(Database db) {
  db.execute('CREATE TABLE IF NOT EXISTS meta '
      '(key TEXT PRIMARY KEY, value TEXT)');
  db.execute(schemaOutlineEntries);
  db.execute(schemaOutlineIndex);
}

String? _getMeta(Database db, String key) {
  try {
    final r = db.select('SELECT value FROM meta WHERE key=?', [key]);
    return r.isEmpty || r.first.columnAt(0) == null
        ? null
        : '${r.first.columnAt(0)}';
  } catch (_) {
    return null; // meta 表不存在（旧库未跑 ensureCorpusSchema）
  }
}

/// 单文件入库结果。
class OutlineFileOutcome {
  const OutlineFileOutcome({
    required this.path,
    required this.level,
    required this.status,
    this.entries = 0,
    this.error,
  });

  final String path;

  /// 'parsed' | 'unchanged' | 'error'。
  final String status;
  final String level;
  final int entries;
  final String? error;
}

/// 大纲入库统计（进度事件/报告消费）。
class OutlineIngestStats {
  final List<OutlineFileOutcome> files = [];

  int get entries =>
      files.fold(0, (n, f) => n + (f.status == 'parsed' ? f.entries : 0));

  Map<String, int> get entriesByLevel {
    final out = <String, int>{};
    for (final f in files) {
      if (f.status == 'parsed') {
        out[f.level] = (out[f.level] ?? 0) + f.entries;
      }
    }
    return out;
  }

  Map<String, Object?> toJson() => {
    'files': [
      for (final f in files)
        {
          'file': pyPathName(f.path),
          'level': f.level,
          'status': f.status,
          'entries': f.entries,
          if (f.error != null) 'error': f.error,
        },
    ],
    'entries': entries,
    'entries_by_level': entriesByLevel,
  };
}

/// 大纲文件批量入库（幂等）：ensureOutlineSchema → 逐文件（.docx）按
/// meta.outline_md5_{level}_{basename} 跳过未变 → parseOutlineDocx →
/// 按 level 整体替换条目 + meta md5。同 level 多文件时按入参顺序后写
/// 覆盖先写（真实树每 level 恰一份）。
OutlineIngestStats ingestOutlineFiles(
  Database db,
  Iterable<String> paths, {
  void Function(String message)? progress,
}) {
  progress ??= (_) {};
  ensureOutlineSchema(db);
  final stats = OutlineIngestStats();
  for (final path in paths) {
    final name = pyPathName(path);
    final level = outlineLevelOfFilename(name);
    if (!name.toLowerCase().endsWith('.docx')) {
      stats.files.add(
        OutlineFileOutcome(
          path: path,
          level: level,
          status: 'error',
          error: '仅支持 .docx 大纲',
        ),
      );
      progress('大纲入库失败：$name（仅支持 .docx）');
      continue;
    }
    final md5 = crypto.md5.convert(File(path).readAsBytesSync()).toString();
    final metaKey = 'outline_md5_${level}_$name';
    if (_getMeta(db, metaKey) == md5) {
      stats.files.add(
        OutlineFileOutcome(path: path, level: level, status: 'unchanged'),
      );
      progress('大纲未变化（跳过解析）：$name');
      continue;
    }
    try {
      final r = parseOutlineDocx(path, level: level);
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('DELETE FROM outline_entries WHERE level=?', [level]);
        final st = db.prepare(
          'INSERT INTO outline_entries (level, part, subject, subject_name, '
          'unit, subtopic, point, path, seq) VALUES (?,?,?,?,?,?,?,?,?)',
        );
        try {
          for (final e in r.entries) {
            st.execute([
              level,
              e.part,
              e.subject,
              e.subjectName,
              e.unit,
              e.subtopic,
              e.point,
              e.path,
              e.seq,
            ]);
          }
        } finally {
          st.dispose();
        }
        db.execute(
          "INSERT INTO meta (key, value) VALUES (?, ?) "
          "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [metaKey, md5],
        );
        db.execute('COMMIT');
      } catch (e) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
        rethrow;
      }
      stats.files.add(
        OutlineFileOutcome(
          path: path,
          level: level,
          status: 'parsed',
          entries: r.entries.length,
        ),
      );
      progress(
        '大纲入库：$name（level=$level，${r.entries.length} 条'
        '${r.skippedSubjects.isEmpty ? '' : '，跳过无映射学科 ${r.skippedSubjects.join('、')}'}）',
      );
    } catch (e) {
      stats.files.add(
        OutlineFileOutcome(
          path: path,
          level: level,
          status: 'error',
          error: '$e',
        ),
      );
      progress('大纲入库失败：$name（$e）');
    }
  }
  return stats;
}

/// outline_entries 条目数（level 可空 = 全部）。
int outlineEntryCount(Database db, [String? level]) {
  try {
    final r = level == null
        ? db.select('SELECT COUNT(*) FROM outline_entries')
        : db.select('SELECT COUNT(*) FROM outline_entries WHERE level=?', [
            level,
          ]);
    return r.isEmpty ? 0 : (r.first.columnAt(0) as num).toInt();
  } catch (_) {
    return 0;
  }
}

// ------------------------------------------------------------- 打标 ----

/// 载入执业树（level='zhiye'）细目索引：学科短码 → [(单元原文, 细目原文)]
/// （按文档序去重）。med 条目也进索引（未知科目回退全树匹配时可见）。
Map<String, List<(String, String)>> loadZhiyeSubtopicIndex(Database db) {
  final out = <String, List<(String, String)>>{};
  final rows = db.select(
    "SELECT subject, unit, subtopic FROM outline_entries "
    "WHERE level='zhiye' GROUP BY subject, unit, subtopic ORDER BY MIN(seq)",
  );
  for (final r in rows) {
    final subject = '${r.columnAt(0)}';
    final unit = '${r.columnAt(1) ?? ''}';
    final subtopic = '${r.columnAt(2) ?? ''}';
    if (unit.isEmpty || subtopic.isEmpty) continue;
    out.putIfAbsent(subject, () => []).add((unit, subtopic));
  }
  return out;
}

/// 关键词 + 子考点文本 → 大纲标签（细目级词面强命中，宁缺勿滥）。
///
/// 匹配规则（归一 = normChapterTitle 去空白；显示名剥序号前缀）：
/// 候选文本（关键词 + plan 子考点）包含细目名，且细目名归一后 ≥4 字、
/// 或（短细目名时）同时包含单元名（「概述/治疗」类泛名须单元佐证）。
/// 匹配范围：关键词所属科目在大纲树内 → 仅该学科（强命中）；否则回退
/// 全树。命中按细目名长度降序取 ≤[kMaxOutlineTagsPerCard] 个，未命中
/// 返回空（不强推）。
List<String> outlineTagsFor({
  required String subjectId,
  required String keyword,
  required List<Object?> subtopics,
  required Map<String, List<(String, String)>> index,
}) {
  final candidates = <String>[
    if (keyword.trim().isNotEmpty) keyword.trim(),
    for (final s0 in subtopics)
      if (s0 != null && s0.toString().trim().isNotEmpty) s0.toString().trim(),
  ].map(normChapterTitle).where((c) => c.isNotEmpty).toList();
  if (candidates.isEmpty) return const [];
  final scope =
      index[subjectId] ?? [for (final v in index.values) ...v]; // 未知科目 → 全树回退
  final hits = <(String, String)>[];
  for (final (unit, subtopic) in scope) {
    final un = normChapterTitle(stripOutlineOrdinal(unit));
    final sn = normChapterTitle(stripOutlineOrdinal(subtopic));
    if (sn.length < 2) continue;
    for (final c in candidates) {
      final strong = c.contains(sn) && (sn.length >= 4 || c.contains(un));
      if (strong) {
        if (!hits.contains((unit, subtopic))) hits.add((unit, subtopic));
        break;
      }
    }
  }
  if (hits.isEmpty) return const [];
  hits.sort(
    (a, b) => normChapterTitle(
      stripOutlineOrdinal(a.$2),
    ).length.compareTo(normChapterTitle(stripOutlineOrdinal(b.$2)).length),
  );
  final longerFirst = hits.reversed.toList(growable: false);
  return [
    for (final (unit, subtopic) in longerFirst.take(kMaxOutlineTagsPerCard))
      '$kOutlineTagPrefix${stripOutlineOrdinal(unit)}＞${stripOutlineOrdinal(subtopic)}',
  ];
}
