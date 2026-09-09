// 恒牙（hengya）· 端上语料混合检索引擎（Phase 4 · 第 1 刀）
// ============================================================================
//
// Python 参考实现：automation/server-pipeline/search_corpus.py（1613 行）——
// 本文件与其行为逐字等价移植，每处关键对齐注明 Python 侧行号（2026-09-06
// 读取态）。验收口径：真库 offline 全链跨引擎逐字段对拍（见
// test/search_engine_test.dart 真库组）+ validate A/B/C 线数字复现
// （tool/search_probe.dart validate 模式）。
//
// 架构（docs/sqlite-vec集成与Dart契约-2026-09-06.md §6）：
//   - 词面路：FTS5 trigram 首选（单元 >=3 字），否则 LIKE 降级 + IDF 加权
//     （标题 2.0 / 正文 1.0）；候选上限 3000。
//   - 向量路：**不需要 sqlite-vec 扩展**——vec_chunks 普通表存 int8 量化向量的
//     float32 归一化镜像（BLOB 4096B/行），Dart 读 Float32List 与归一化查询
//     向量做点积（cos = Σ q̂ᵢ·vᵢ clamp [0,1]），与 Python vec_distance_cosine
//     换算结果在 float 舍入内一致；回退链 = int8 流式解码（vectors.vec 整数
//     点积，scale 对余弦可约不参与），表缺失 / meta 无 vec0_dim / 维度不符
//     时自动回退，行为逐字等价（契约 §3/§6）。
//   - 融合：linear（默认 0.40/0.60：w_lex×词面归一 + w_vec×余弦；向量路
//     不可用时重归一为词面单路）；rrf 保留为可选实验路径（Python L158-166
//     定稿结论：RRF 三线全面劣于 linear）。无显式 source_type 时对
//     source_type='ppt' 施以 1.05 轻微优先乘子（PPT 主源契约）。
//   - Reranker：注入式钩子（rerankOn 且窗口 >=2 时融合 top-20 精排输出
//     top-k；顺序按 rerank 分，score/fused/lex/vec 字段仍为融合域）。
//     HTTP 实现与模型降级链（8B→4B→0.6B + 烟测 2s + 429 退避）见
//     search_api.dart。
//   - 嵌入：注入式（embedQuery）；offline 模式用 localEmbed（crc32 特征袋
//     兜底，与 Python zlib.crc32 逐位一致）。
//
// 纯 Dart（dart:io + package:sqlite3），不 import Flutter——可被
// app/ 内任意层使用，也可 `dart run tool/…` 直跑跨引擎对拍。
//
// 低分线（floor 0.30/0.32）不在本引擎内做——与 Python 一致由调用方
// （run_engine / validate）在拿到 results 后自行过滤。
import 'dart:collection';
import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

// ------------------------------------------------------------- 常量 ----
// 对齐 search_corpus.py L136-218（2026-09-06 定稿态）

/// 查询侧 instruct 前缀（Python L141-145；2026-09-06 真库 A/B 定论：保留——
/// 禁用则生造词最高分 0.295→0.332 越过 0.30 低分线，C 线 4/4→1/4 失败）。
const String kQueryInstruct =
    'Instruct: Given a classroom keyword, retrieve relevant lecture slides '
    'that answer the keyword\nQuery: ';

/// 离线兜底嵌入标识（Python LOCAL_EMBED_MODEL L146；与 API 空间不兼容，
/// meta.embedding_model 校验自动互斥）。
const String kLocalEmbedModel = 'local-charhash-1024-v1';

/// 标题命中加权 > 正文（Python L149-150）。
const double kTitleWeight = 2.0;
const double kBodyWeight = 1.0;

/// 余弦 >= 此值记 vector 命中路（Python L151）。
const double kVecHitFloor = 0.30;

/// 默认（未显式 source_type）时 ppt 轻微优先乘子（Python L152）。
const double kPptPriorityBoost = 1.05;

/// 词面候选上限（内存纪律，Python L153）。
const int kMaxLexCandidates = 3000;

/// 打分单元上限（Python L154）。
const int kMaxUnits = 48;

/// 融合模式常量（Python L163-166；默认 linear）。
const String kFusionLinear = 'linear';
const String kFusionRrf = 'rrf';
const int kRrfKDefault = 60;

/// Reranker 融合 top-20 进重排窗口（Python RERANK_TOP_DEFAULT L175）。
const int kRerankTopDefault = 20;

/// 契约常量（sqlite-vec 契约文档 §6-6）。
const String kVec0Table = 'vec_chunks';
const String kVec0MetaDim = 'vec0_dim';

/// 查询分段正则（Python _SEGMENT_RE L225）：非「字母数字/CJK」串切分。
final RegExp _segmentRe = RegExp(r'[^0-9A-Za-z\u4e00-\u9fff]+');

// schema 列名候选（Python SCHEMA_CANDIDATES L207-218，PRAGMA 探测适配）
const Map<String, List<String>> _schemaCandidates = {
  'chunk_id': ['chunk_id', 'id', 'chunkid'],
  'subject_id': ['subject_id', 'subject', 'subjectid'],
  'ppt_id': ['ppt_id', 'ppt', 'pptid', 'deck_id'],
  'deck': ['deck', 'deck_name', 'ppt_name', 'ppt_title', 'file_title'],
  'page_start': ['page_start', 'page_from', 'page_no', 'page', 'page_begin'],
  'page_end': ['page_end', 'page_to', 'page_no_end'],
  'title': ['title', 'section', 'chapter', 'heading', 'section_name'],
  'text': ['text', 'body', 'content', 'chunk_text'],
  'source_type': ['source_type', 'sourcetier', 'source_tier', 'tier', 'source'],
  'file_date': ['file_date', 'filedate', 'ppt_date', 'date'],
};
const Map<String, List<String>> _vecColCandidates = {
  'vec_chunk_id': ['chunk_id', 'id'],
  'vec_vec': ['vec', 'vector', 'embedding', 'emb'],
  'vec_dim': ['dim', 'dims', 'dimensions'],
};

// ------------------------------------------------- 注入函数（网络层） ----

/// 查询嵌入注入：返回查询向量（null = 向量路不可用，如无 API key）。
/// offline 模式下调用方传 null 由引擎内部 localEmbed 兜底。
typedef EmbedQueryFn = Future<List<double>?> Function(String query);

/// Rerank 注入：返回 (ranked, model, reason)——ranked=null 表示本次跳过重排
/// （调用方沿用融合序，行为与 rerank=off 一致）。
/// ranked = [(index, score)] 按 rerank 分降序（index = documents 下标）。
typedef RerankResult = (List<(int, double)>?, String?, String?);
typedef RerankFn = Future<RerankResult> Function(
    String query, List<String> documents);

// --------------------------------------------------------------- schema ----

/// corpus.db 结构探测结果（Python resolve_schema L386-429 同款候选探测）。
class CorpusSchema {
  CorpusSchema({
    required this.tables,
    required this.hasVectors,
    required this.hasMeta,
    required this.col,
    this.vectorsNote,
  });

  final Set<String> tables;
  final bool hasVectors;
  final bool hasMeta;
  final Map<String, String?> col; // 逻辑名 → 实际列名（null = 库缺该列）
  final String? vectorsNote;

  String? operator [](String key) => col[key];
}

List<String> _tableCols(Database db, String table) => db
    .select('PRAGMA table_info("$table")')
    .map((r) => '${r['name']}')
    .toList();

CorpusSchema resolveCorpusSchema(Database db) {
  final tables = db
      .select("SELECT name FROM sqlite_master WHERE type='table'")
      .map((r) => '${r['name']}')
      .toSet();
  if (!tables.contains('chunks')) {
    throw StateError('corpus.db 缺 chunks 表；现有表：'
        '${tables.isEmpty ? '无' : tables.join(', ')}');
  }
  final cols = _tableCols(db, 'chunks');
  final low = {for (final c in cols) c.toLowerCase(): c};
  final picked = <String, String?>{};
  for (final e in _schemaCandidates.entries) {
    String? hit;
    for (final name in e.value) {
      if (cols.contains(name)) {
        hit = name;
        break;
      }
      if (low.containsKey(name)) {
        hit = low[name];
        break;
      }
    }
    picked[e.key] = hit;
  }
  if (picked['chunk_id'] == null) {
    throw StateError('chunks 表缺 chunk_id 列（现有列：${cols.join(', ')}）');
  }
  if (picked['text'] == null) {
    throw StateError('chunks 表缺 text/body 列（现有列：${cols.join(', ')}）');
  }
  if (picked['title'] == null) {
    picked['title'] = picked['text']; // 无标题列 → 标题退化为正文（只降级不阻断）
  }
  var hasVectors = tables.contains('vectors');
  var vectorsNote = <String?>{};
  if (hasVectors) {
    final vcols = _tableCols(db, 'vectors');
    final vlow = {for (final c in vcols) c.toLowerCase(): c};
    for (final e in _vecColCandidates.entries) {
      String? hit;
      for (final name in e.value) {
        if (vcols.contains(name)) {
          hit = name;
          break;
        }
        if (vlow.containsKey(name)) {
          hit = vlow[name];
          break;
        }
      }
      picked[e.key] = hit;
    }
    if (picked['vec_chunk_id'] == null || picked['vec_vec'] == null) {
      hasVectors = false;
      vectorsNote.add('vectors 表列异常（${vcols.join(', ')}），忽略向量路');
    }
  }
  return CorpusSchema(
    tables: tables,
    hasVectors: hasVectors,
    hasMeta: tables.contains('meta'),
    col: picked,
    vectorsNote: vectorsNote.isEmpty ? null : vectorsNote.join('; '),
  );
}

/// meta 表读取（Python read_meta L432-445；真库为 key/value 两列）。
Map<String, String> readCorpusMeta(Database db, CorpusSchema sch) {
  if (!sch.hasMeta) return {};
  try {
    return {
      for (final r in db.select('SELECT key, value FROM meta'))
        '${r['key']}': r['value'] == null ? '' : '${r['value']}',
    };
  } catch (_) {
    return {};
  }
}

bool _chunksHasRowid(Database db) {
  try {
    db.select('SELECT rowid FROM chunks LIMIT 1');
    return true;
  } catch (_) {
    return false;
  }
}

/// FTS5 表探测（Python detect_fts L456-481）：
/// 返回 (table, idCol)——idCol=='chunk_id' 直接回查；=='rowid' 按 rowid 映射；
/// (null, null) = 整体 LIKE 降级。
(String?, String?) detectFts(Database db, {String preferTable = 'chunks_fts'}) {
  final rows = db.select("SELECT name, sql FROM sqlite_master WHERE type='table'");
  final cands = <String>[];
  for (final r in rows) {
    final name = '${r['name']}';
    final sql = (r['sql'] as String?) ?? '';
    if (name == preferTable) {
      cands.insert(0, name);
    } else if (sql.toLowerCase().contains('fts5') || name.endsWith('_fts')) {
      cands.add(name);
    }
  }
  for (final name in cands) {
    final cols = _tableCols(db, name);
    if (cols.contains('chunk_id')) return (name, 'chunk_id');
    if (cols.isEmpty) continue;
    try {
      final safe = name.replaceAll('"', '""');
      db.select('SELECT rowid FROM "$safe" WHERE "$safe" MATCH ? LIMIT 1',
          ['a测试']);
      return (name, 'rowid');
    } catch (_) {
      continue;
    }
  }
  return (null, null);
}

// --------------------------------------------------------- 查询解析 ----

/// 查询 → 打分单元（Python extract_units L486-502）：
/// 分段（原句子串）+ 长分段的三元组 + 去空白整串；按长度降序、去重、封顶 48。
List<String> extractUnits(String? query) {
  final q = (query ?? '').trim();
  if (q.isEmpty) return [];
  final units = <String>{};
  // Dart 的 split(RegExp) 与 Python re.split 语义一致（保留非匹配串）。
  final parts = q.split(_segmentRe).where((s) => s.length >= 2).toList();
  for (final seg in parts) {
    units.add(seg);
    if (seg.length > 3) {
      for (var i = 0; i < seg.length - 2; i++) {
        units.add(seg.substring(i, i + 3));
      }
    }
  }
  final whole = q.replaceAll(_segmentRe, '');
  if (whole.length >= 2) {
    units.add(whole); // 例：查询「龋病 定义」→ 补「龋病定义」整串单元
  }
  final list = units.toList()
    ..sort((a, b) {
      final d = b.length - a.length;
      return d != 0 ? d : a.compareTo(b);
    });
  return list.length > kMaxUnits ? list.sublist(0, kMaxUnits) : list;
}

// --------------------------------------------------- 词面与取行工具 ----

/// LIKE 模式转义（Python _like_pat L701-703）。
String _likePat(String unit) {
  final esc = unit
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
  return '%$esc%';
}

String _selCol(CorpusSchema sch, String key) {
  final c = sch[key];
  return c == null ? "''" : '"$c"';
}

/// 分批取 chunk 行（Python _fetch_chunk_rows L713-751；批 400）。
/// withText=false 只取轻量元数据（text 置空），用于排序前补元信息。
Map<String, Map<String, Object?>> fetchChunkRows(Database db, CorpusSchema sch,
    Iterable<String> ids,
    {String? subject, String? sourceType, bool withText = true}) {
  final rows = <String, Map<String, Object?>>{};
  final uniq = LinkedHashSet<String>.of(ids);
  if (uniq.isEmpty) return rows;
  final cols = [
    _selCol(sch, 'chunk_id'),
    _selCol(sch, 'subject_id'),
    _selCol(sch, 'deck'),
    if (sch['page_start'] != null) '"${sch['page_start']}"' else 'NULL',
    if (sch['page_end'] != null) '"${sch['page_end']}"' else 'NULL',
    _selCol(sch, 'title'),
    _selCol(sch, 'source_type'),
    withText ? _selCol(sch, 'text') : "''",
  ].join(', ');
  final conds = <String>[];
  final condParams = <Object?>[];
  if (subject != null && sch['subject_id'] != null) {
    conds.add('"${sch['subject_id']}" = ?');
    condParams.add(subject);
  }
  if (sourceType != null && sch['source_type'] != null) {
    conds.add('"${sch['source_type']}" = ?');
    condParams.add(sourceType);
  }
  final idList = uniq.toList();
  for (var i = 0; i < idList.length; i += 400) {
    final batch = idList.sublist(
        i, math.min(i + 400, idList.length));
    final qm = List.filled(batch.length, '?').join(',');
    var sql = 'SELECT $cols FROM "chunks" WHERE "${sch['chunk_id']}" IN ($qm)';
    if (conds.isNotEmpty) sql += ' AND ${conds.join(' AND ')}';
    for (final r in db.select(sql, [...batch, ...condParams])) {
      rows['${r.columnAt(0) ?? ''}'] = {
        'chunk_id': '${r.columnAt(0) ?? ''}',
        'subject_id': '${r.columnAt(1) ?? ''}',
        'deck': '${r.columnAt(2) ?? ''}',
        'page_start': r.columnAt(3),
        'page_end': r.columnAt(4),
        'title': '${r.columnAt(5) ?? ''}',
        'source_type': '${r.columnAt(6) ?? ''}'.toLowerCase(),
        'text': '${r.columnAt(7) ?? ''}',
      };
    }
  }
  return rows;
}

/// 词面路（Python lexical_path L754-855）：
/// FTS5 trigram 首选（单元 >=3 字），否则 LIKE 降级；IDF 加权打分。
/// 返回 (rows, lexRaw, info)。
(Map<String, Map<String, Object?>>, Map<String, double>, Map<String, Object?>)
    lexicalPath(
  Database db,
  CorpusSchema sch,
  List<String> units, {
  String? subject,
  String? sourceType,
  bool useFts = true,
  List<String>? notes,
}) {
  final info = {
    'mode': 'like',
    'units': units.length,
    'candidates': 0,
    'fts_units': 0,
    'like_units': 0,
  };
  final rows = <String, Map<String, Object?>>{};
  final lexRaw = <String, double>{};
  if (units.isEmpty) return (rows, lexRaw, info);
  String? ftsTable;
  String? ftsCol;
  if (useFts) {
    final (t, c) = detectFts(db);
    ftsTable = t;
    ftsCol = c;
  }
  if (ftsTable != null && ftsCol == 'rowid' && !_chunksHasRowid(db)) {
    notes?.add('FTS 表仅可按 rowid 回查，而 chunks 无 rowid → 词面路整体 LIKE 降级');
    ftsTable = null;
  }
  final hitIds = <String, Set<String>>{};
  for (final unit in units) {
    Set<String>? ids;
    if (ftsTable != null && unit.length >= 3) {
      try {
        final safe = ftsTable.replaceAll('"', '""');
        final match = '"$unit"';
        if (ftsCol == 'chunk_id') {
          ids = db
              .select('SELECT "chunk_id" FROM "$safe" WHERE "$safe" MATCH ?',
                  [match])
              .map((r) => '${r.columnAt(0)}')
              .toSet();
        } else {
          final rids = db
              .select('SELECT rowid FROM "$safe" WHERE "$safe" MATCH ?',
                  [match])
              .map((r) => r.columnAt(0))
              .toList();
          ids = {};
          for (var i = 0; i < rids.length; i += 500) {
            final batch = rids.sublist(i, math.min(i + 500, rids.length));
            final qm = List.filled(batch.length, '?').join(',');
            ids.addAll(db
                .select('SELECT "${sch['chunk_id']}" FROM "chunks" '
                    'WHERE rowid IN ($qm)', batch)
                .map((r) => '${r.columnAt(0)}'));
          }
        }
        info['fts_units'] = (info['fts_units'] as int) + 1;
      } catch (e) {
        ids = null;
        notes?.add('FTS 查询单元「${unit.length > 12 ? '${unit.substring(0, 12)}…' : unit}」'
            '失败（$e）→ 该单元 LIKE 降级');
      }
    }
    if (ids == null) {
      var sql = 'SELECT "${sch['chunk_id']}" FROM "chunks" '
          'WHERE ("${sch['title']}" LIKE ? ESCAPE \'\\\' '
          'OR "${sch['text']}" LIKE ? ESCAPE \'\\\')';
      final pat = _likePat(unit);
      final params = <Object?>[pat, pat];
      if (subject != null && sch['subject_id'] != null) {
        sql += ' AND "${sch['subject_id']}" = ?';
        params.add(subject);
      }
      if (sourceType != null && sch['source_type'] != null) {
        sql += ' AND "${sch['source_type']}" = ?';
        params.add(sourceType);
      }
      ids = db.select(sql, params).map((r) => '${r.columnAt(0)}').toSet();
      info['like_units'] = (info['like_units'] as int) + 1;
    }
    if (ids.isNotEmpty) hitIds[unit] = ids;
  }
  if (hitIds.isEmpty) {
    info['mode'] = ftsTable != null ? 'fts5-trigram' : 'like';
    return (rows, lexRaw, info);
  }
  // 命中计数（Python L819-822；cnt 保持首次命中插入序，供稳定截断 tie-break）
  final cnt = <String, int>{};
  final firstSeen = <String, int>{};
  for (final s in hitIds.values) {
    for (final cid in s) {
      if (!firstSeen.containsKey(cid)) firstSeen[cid] = firstSeen.length;
      cnt[cid] = (cnt[cid] ?? 0) + 1;
    }
  }
  final cand = cnt.keys.toList()
    ..sort((a, b) {
      final d = cnt[b]! - cnt[a]!;
      return d != 0 ? d : firstSeen[a]! - firstSeen[b]!;
    });
  final kept = cand.length > kMaxLexCandidates
      ? cand.sublist(0, kMaxLexCandidates)
      : cand;
  if (cnt.length > kMaxLexCandidates) {
    notes?.add('词面候选 ${cnt.length} 条超上限，保留命中数最多的 $kMaxLexCandidates 条');
  }
  rows.addAll(fetchChunkRows(db, sch, kept,
      subject: subject, sourceType: sourceType));
  // IDF 权重（Python L829-839）：df=该单元命中的库内 chunk 数（FTS 级、
  // 未过 subject 过滤）；N=chunk 总数；稀有单元权重 > 高频单元。
  var total = 0;
  try {
    total = db.select('SELECT COUNT(*) FROM "chunks"').first.columnAt(0) as int;
  } catch (_) {}
  final unitW = <String, double>{};
  for (final e in hitIds.entries) {
    final df = e.value.length.toDouble();
    final idf = total > 0 ? 1.0 + math.log((total + 1) / (df + 1)) : 1.0;
    unitW[e.key] = e.key.length * idf;
  }
  for (final e in rows.entries) {
    final title = '${e.value['title']}';
    final text = '${e.value['text']}';
    var s = 0.0;
    for (final unit in hitIds.keys) {
      if (title.contains(unit)) {
        s += kTitleWeight * unitW[unit]!;
      } else if (text.contains(unit)) {
        s += kBodyWeight * unitW[unit]!;
      }
    }
    if (s > 0) lexRaw[e.key] = s;
  }
  info['mode'] = ftsTable != null
      ? (info['like_units'] as int) > 0
          ? 'fts5-trigram(+like降级${info['like_units']})'
          : 'fts5-trigram'
      : 'like';
  info['candidates'] = rows.length;
  return (rows, lexRaw, info);
}

// --------------------------------------------------------------- 向量路 ----

/// 向量路（Python vector_scan L1043-1118 + _vector_scan_vec0 L1121-1209）。
///
/// Dart 版实现（契约 §6）：**优先 vec_chunks 镜像点积**（float32 归一化镜像 ×
/// 归一化查询向量，cos = Σ q̂ᵢ·vᵢ clamp [0,1]）——与 Python sqlite-vec
/// `vec_distance_cosine` 全表扫描（cos=1-d）数学恒等（差仅 float32 舍入）；
/// 表缺失 / meta 无 vec0_dim / 查询向量短于库维度 / 全零查询向量 → 回退
/// int8 流式解码（与 Python 流式路径逐字等价，scale 可约不参与）。
///
/// subject/sourceType 过滤口径与 Python 完全一致：镜像路径全表扫后按
/// keep-set 后置过滤（vec0 同款）；流式路径 SQL JOIN WHERE（流式同款）。
Map<String, double> vectorScan(
  Database db,
  CorpusSchema sch,
  List<double> qvec, {
  String? subject,
  String? sourceType,
  List<String>? notes,
  bool? vec0,
}) {
  final cos = <String, double>{};
  if (qvec.isEmpty) return cos;
  if (vec0 == null || vec0) {
    final got = _vectorScanMirror(db, sch, qvec,
        subject: subject, sourceType: sourceType, notes: notes);
    if (got != null) return got;
  }
  // ---- int8 流式回退（Python vector_scan 流式分支 L1062-1117）----
  final vchunk = sch['vec_chunk_id']!;
  final vvec = sch['vec_vec']!;
  final where = <String>[];
  final params = <Object?>[];
  if (subject != null && sch['subject_id'] != null) {
    where.add('c."${sch['subject_id']}" = ?');
    params.add(subject);
  }
  if (sourceType != null && sch['source_type'] != null) {
    where.add('c."${sch['source_type']}" = ?');
    params.add(sourceType);
  }
  var sql = 'SELECT v."$vchunk", v."$vvec" FROM "vectors" v '
      'JOIN "chunks" c ON c."${sch['chunk_id']}" = v."$vchunk"';
  if (where.isNotEmpty) sql += ' WHERE ${where.join(' AND ')}';
  // vectors.dim 与 BLOB 长度不符警告（Python L1074-1082）
  if (sch['vec_dim'] != null) {
    try {
      final r = db.select(
          'SELECT "${sch['vec_dim']}", length("$vvec") FROM "vectors" LIMIT 1');
      if (r.isNotEmpty && r.first.columnAt(0) != null && r.first.columnAt(1) != null) {
        final dim = int.tryParse('${r.first.columnAt(0)}') ?? 0;
        final blen = int.tryParse('${r.first.columnAt(1)}') ?? 0;
        if (dim != 0 && blen != 0 && dim != blen) {
          notes?.add('警告：vectors.dim=$dim 与 BLOB 长度=$blen 不符'
              '（按 BLOB 长度解码 int8）');
        }
      }
    } catch (_) {}
  }
  final norms = <int, (Float64List, double)>{};
  var scanned = 0;
  for (final r in db.select(sql, params)) {
    scanned++;
    final cid = '${r.columnAt(0)}';
    final blob = r.columnAt(1) as List<int>;
    final n = blob.length;
    if (n == 0 || n > qvec.length) continue;
    (Float64List, double)? norm;
    if (!norms.containsKey(n)) {
      final sl = Float64List(n);
      var s2 = 0.0;
      for (var i = 0; i < n; i++) {
        sl[i] = qvec[i];
        s2 += qvec[i] * qvec[i];
      }
      norm = (sl, s2 > 0 ? math.sqrt(s2) : 1.0);
      norms[n] = norm;
    } else {
      norm = norms[n]!;
    }
    final sl = norm.$1;
    final qn = norm.$2;
    final u8 = blob is Uint8List ? blob : Uint8List.fromList(blob);
    final ints = Int8List.view(u8.buffer, u8.offsetInBytes, n);
    var dot = 0.0;
    var d2 = 0.0;
    for (var i = 0; i < n; i++) {
      dot += sl[i] * ints[i];
      d2 += ints[i] * ints[i].toDouble();
    }
    if (d2 <= 0) continue;
    var c = dot / (qn * math.sqrt(d2));
    if (c < 0.0) {
      c = 0.0;
    } else if (c > 1.0) {
      c = 1.0;
    }
    if (c > (cos[cid] ?? -1.0)) cos[cid] = c;
  }
  notes?.add('向量路流式扫描 $scanned 行（int8 解码→余弦，scale 可约未参与）');
  return cos;
}

/// vec_chunks 镜像点积路径（Python _vector_scan_vec0 的 Dart 等价实现，
/// 契约 §6-3：cos = Σ q̂ᵢ·vᵢ；不可用返回 null 回退流式）。
Map<String, double>? _vectorScanMirror(
  Database db,
  CorpusSchema sch,
  List<double> qvec, {
  String? subject,
  String? sourceType,
  List<String>? notes,
}) {
  final sw = Stopwatch()..start();
  final hitRows = db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [kVec0Table]);
  if (hitRows.isEmpty) {
    notes?.add('vec0 表缺失（$kVec0Table），向量路回退流式扫描');
    return null;
  }
  var dim = 0;
  try {
    final r = db.select('SELECT value FROM meta WHERE key=?', [kVec0MetaDim]);
    if (r.isNotEmpty && r.first.columnAt(0) != null) {
      dim = int.tryParse('${r.first.columnAt(0)}') ?? 0;
    }
  } catch (_) {}
  if (dim <= 0 || qvec.length < dim) {
    notes?.add('vec0 维度信息缺失或查询向量短于库维度，回退流式扫描');
    return null;
  }
  final qs = qvec.sublist(0, dim);
  var q2 = 0.0;
  for (final x in qs) {
    q2 += x * x;
  }
  if (q2 <= 0) return null; // 全零查询向量：走流式路径同口径兜底
  final qn = math.sqrt(q2);
  final qhat = Float64List(dim);
  for (var i = 0; i < dim; i++) {
    qhat[i] = qs[i] / qn;
  }
  final cnt =
      db.select('SELECT count(*) FROM $kVec0Table').first.columnAt(0) as int;
  if (cnt == 0) return {};
  final cos = <String, double>{};
  for (final r in db.select('SELECT chunk_id, v FROM $kVec0Table')) {
    final cid = '${r.columnAt(0)}';
    final blob = r.columnAt(1) as List<int>;
    if (blob.length != dim * 4) continue; // 维度不符行跳过（重建拒绝保证不出现）
    final u8 = blob is Uint8List ? blob : Uint8List.fromList(blob);
    final v = Float32List.view(u8.buffer, u8.offsetInBytes, dim);
    var dot = 0.0;
    for (var i = 0; i < dim; i++) {
      dot += qhat[i] * v[i];
    }
    var c = dot;
    if (c < 0.0) {
      c = 0.0;
    } else if (c > 1.0) {
      c = 1.0;
    }
    cos[cid] = c;
  }
  // subject/source_type 过滤（Python L1191-1203 同款后置 keep-set）
  final where = <String>[];
  final params = <Object?>[];
  if (subject != null && sch['subject_id'] != null) {
    where.add('"${sch['subject_id']}" = ?');
    params.add(subject);
  }
  if (sourceType != null && sch['source_type'] != null) {
    where.add('"${sch['source_type']}" = ?');
    params.add(sourceType);
  }
  if (where.isNotEmpty) {
    final keep = db
        .select('SELECT "${sch['chunk_id']}" FROM "chunks" '
            'WHERE ${where.join(' AND ')}', params)
        .map((r) => '${r.columnAt(0)}')
        .toSet();
    cos.removeWhere((cid, _) => !keep.contains(cid));
  }
  notes?.add('向量路 vec0 距离全扫 $cnt 行（Dart Float32List 点积，'
      '过滤后 ${cos.length}，耗时 ${sw.elapsedMilliseconds} ms）');
  return cos;
}

// ------------------------------------------------------- localEmbed ----
// Python local_embed L507-529：CRC-32（IEEE 802.3，zlib 多项式）特征袋。
// Dart 无内置 crc32——表驱动自实现，与 zlib.crc32 逐位一致（测试对拍值固化）。

final Uint32List _crcTable = _buildCrcTable();
Uint32List _buildCrcTable() {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}

/// zlib.crc32(s.utf8)（无初值参数语义，返回无符号 32 位）。
int pyCrc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// 本地确定性兜底嵌入（Python local_embed L507-529 逐字对齐）：
/// CJK unigram(0.5)/bigram(1.0)/ASCII 词(2.0) 二值特征袋（每特征只计一次，
/// 消除词频堆积虚高）→ crc32 桶 + 伪随机符号（(h>>24)&1）→ L2 归一。
/// 跨进程/跨平台确定；仅 offline 演练与自测用，与 API 嵌入空间不兼容。
List<double> localEmbed(String text, {int dim = 1024}) {
  final s = text.toLowerCase();
  final chars = s.replaceAll(RegExp(r'[^0-9a-z\u4e00-\u9fff]'), '');
  final feats = <String>{};
  for (final ch in chars.runes) {
    feats.add('u${String.fromCharCode(ch)}');
  }
  for (var i = 0; i < chars.length - 1; i++) {
    feats.add('b${chars.substring(i, i + 2)}');
  }
  for (final m in RegExp(r'[a-z0-9]{2,}').allMatches(s)) {
    feats.add('w${m[0]}');
  }
  final vec = List<double>.filled(dim, 0.0);
  for (final f in feats) {
    // Python: h = zlib.crc32(f.encode("utf-8")) —— 严格 UTF-8 字节序
    final h = pyCrc32(convert.utf8.encode(f));
    final w = f.startsWith('u') ? 0.5 : (f.startsWith('w') ? 2.0 : 1.0);
    vec[h % dim] += ((h >> 24) & 1) != 0 ? w : -w;
  }
  var n2 = 0.0;
  for (final x in vec) {
    n2 += x * x;
  }
  if (n2 <= 0) return vec;
  final n = math.sqrt(n2);
  return [for (final x in vec) x / n];
}

// --------------------------------------------------------------- 结果 ----

class SearchHit {
  SearchHit({
    required this.rank,
    required this.chunkId,
    required this.subject,
    required this.deck,
    required this.pageStart,
    required this.pageEnd,
    required this.pageRange,
    required this.title,
    required this.sourceType,
    required this.score,
    required this.fused,
    required this.lex,
    required this.vec,
    required this.hitPath,
    required this.preview,
    required this.text,
    this.rerankScore,
  });

  final int rank;
  final String chunkId;
  final String subject;
  final String deck;
  final int? pageStart;
  final int? pageEnd;
  final String pageRange;
  final String title;
  final String sourceType;
  final double score; // rank 域（含 PPT 乘子）
  final double fused; // 融合域
  final double lex; // 词面归一域
  final double vec; // 余弦域
  final String hitPath;
  final String preview;
  final String text;
  final double? rerankScore;

  Map<String, Object?> toJson() => {
        'rank': rank,
        'chunk_id': chunkId,
        'subject': subject,
        'deck': deck,
        'page_start': pageStart,
        'page_end': pageEnd,
        'page_range': pageRange,
        'title': title,
        'source_type': sourceType,
        'score': _pyRound4(score),
        'fused': _pyRound4(fused),
        'lex': _pyRound4(lex),
        'vec': _pyRound4(vec),
        'hit_path': hitPath,
        'preview': preview,
        'text': text,
        if (rerankScore != null) 'rerank': _pyRound4(rerankScore!),
      };
}

/// Python round(x, 4)（十进制正确舍入半偶）。Dart 的 toStringAsFixed/double
/// 舍入与 CPython 的 dtoa 舍入在半数位可能不同——跨引擎对拍以 |Δ|<1e-4
/// 容差比较分数，本函数仅用于 --json 兼容输出。
num _pyRound4(double x) {
  final s = x.toStringAsFixed(4);
  return double.parse(s);
}

String _pageRange(Map<String, Object?> row) {
  final s = row['page_start'];
  final e = row['page_end'];
  if (s == null) return '-';
  final si = int.tryParse('$s');
  final ei = e == null ? null : int.tryParse('$e');
  if (si == null) return '-';
  if (ei == null || ei == si) return '$si';
  return '$si-$ei';
}

String _preview(String text, [int n = 40]) {
  final s = text.replaceAll(RegExp(r'\s+'), ' ');
  return s.length > n ? s.substring(0, n) : s;
}

// --------------------------------------------------------------- 主入口 ----

/// 混合检索主入口（Python search L1232-1470 逐段对齐）。
///
/// [db] 已打开的 corpus.db（package:sqlite3；调用方负责 open/dispose）。
/// [embed] 查询嵌入注入（null 且 offline=true → localEmbed 兜底；
/// null 且 offline=false → 向量路禁用，等价 Python「无 API key」）。
/// [rerankFn] 重排注入（null = rerank 不可用；offline 强制跳过）。
/// [vec0] null=on（镜像点积优先，失败回退流式）；false=强制流式（等价验收）。
Future<Map<String, Object?>> corpusSearch(
  Database db,
  String q, {
  String? subject,
  int k = 10,
  String? sourceType,
  List<double>? weights,
  bool offline = false,
  bool noFts = false,
  List<double>? queryVec,
  String? queryVecModel,
  String fusion = kFusionLinear,
  int? rrfK,
  bool? rerank,
  String? rerankModel,
  bool? vec0,
  EmbedQueryFn? embed,
  String? embedModel, // 查询侧嵌入模型标识（在线模式互斥校验依据；
  // 与库内 meta.embedding_model 不一致时向量路自动跳过）
  RerankFn? rerankFn,
}) async {
  final sw = Stopwatch()..start();
  final notes = <String>[];
  var w = weights ?? const [0.4, 0.6];
  var wLex = w[0];
  var wVec = w[1];
  if (wLex < 0 || wVec < 0 || (wLex + wVec) <= 0) {
    throw ArgumentError('weights 需为两个非负数且不同时为 0');
  }
  final wsum = wLex + wVec;
  wLex = wLex / wsum;
  wVec = wVec / wsum;
  k = math.max(1, k);
  final fusionMode = fusion == kFusionRrf ? kFusionRrf : kFusionLinear;
  final rrfKVal = fusionMode == kFusionRrf ? (rrfK ?? kRrfKDefault) : null;
  final rerankOn = (rerank ?? true) && !offline && rerankFn != null;
  if ((rerank ?? true) && (offline || rerankFn == null)) {
    notes.add(offline
        ? 'RERANK=on 与 offline 互斥：offline 不调外部 API，重排跳过（沿用融合序）'
        : '重排跳过：未注入 reranker（无配置即跳过，沿用融合序）');
  }

  final sch = resolveCorpusSchema(db);
  final meta = readCorpusMeta(db, sch);
  final units = extractUnits(q);
  if (units.isEmpty) {
    return {
      'ok': true,
      'query': q,
      'subject': subject,
      'k': k,
      'weights': [wLex, wVec],
      'fusion': fusionMode,
      'results': <SearchHit>[],
      'notes': ['查询无有效单元（仅标点/单字符），零命中'],
      'elapsed_ms': sw.elapsedMilliseconds,
    };
  }
  if (subject != null && sch['subject_id'] == null) {
    notes.add('库无 subject 列，subject 过滤未生效');
  }
  if (sourceType != null && sch['source_type'] == null) {
    notes.add('库无 source_type 列，sourceType 过滤未生效');
  }

  // ① 词面路
  final (lexRows, lexRaw, lexInfo) = lexicalPath(db, sch, units,
      subject: subject, sourceType: sourceType, useFts: !noFts, notes: notes);

  // ② 向量路（Python embed_query + 模型兼容性互斥校验）
  var vecInfo = {'used': false, 'model': null, 'scanned': 0};
  var cos = <String, double>{};
  List<double>? qvec = queryVec;
  String? vmodel;
  String? vreason;
  if (qvec == null && !offline && embed != null) {
    qvec = await embed(q);
    vmodel = embedModel;
    vreason = '嵌入函数返回空（如无 API key）';
  } else if (qvec == null && offline) {
    qvec = localEmbed(q);
    vmodel = kLocalEmbedModel;
    vreason = 'offline：本地兜底嵌入（演练用）';
  } else if (qvec != null) {
    vmodel = queryVecModel ?? 'precomputed';
  } else {
    vreason = '无嵌入函数（offline=false 且未注入 embed）';
  }
  final vmodelEff = queryVecModel ?? vmodel;
  if (qvec == null) {
    notes.add('向量路跳过：$vreason');
  } else if (!sch.hasVectors) {
    notes.add('向量路跳过：库无可用 vectors 表'
        '${sch.vectorsNote == null ? '' : '：${sch.vectorsNote}'}');
  } else {
    final metaModel = meta['embedding_model'];
    if (metaModel != null && metaModel.isNotEmpty &&
        vmodelEff != null && metaModel.toLowerCase() != vmodelEff.toLowerCase()) {
      notes.add('向量路跳过：库内向量模型「$metaModel」与查询侧「$vmodelEff」'
          '嵌入空间不兼容（offline 请配本地演练库，或在线重试）');
    } else {
      if (metaModel == null || metaModel.isEmpty) {
        notes.add('注意：meta 无 embedding_model，向量兼容性未核'
            '（按查询侧 $vmodelEff 计算）');
      }
      cos = vectorScan(db, sch, qvec,
          subject: subject, sourceType: sourceType, notes: notes, vec0: vec0);
      vecInfo = {'used': true, 'model': vmodelEff, 'scanned': cos.length};
    }
  }

  // ③ 融合与排序（Python L1325-1386）
  final lexMax = lexRaw.isEmpty
      ? 0.0
      : lexRaw.values.reduce((a, b) => a > b ? a : b);
  final allIds = <String>{...lexRaw.keys, ...cos.keys};
  if (allIds.isEmpty) {
    return {
      'ok': true,
      'query': q,
      'subject': subject,
      'k': k,
      'weights': [wLex, wVec],
      'fusion': fusionMode,
      'lex': lexInfo,
      'vec': vecInfo,
      'results': <SearchHit>[],
      'notes': notes,
      'elapsed_ms': sw.elapsedMilliseconds,
    };
  }
  // 向量路独有候选：仅补轻量元数据参与排序
  final cosOnly = cos.keys.toSet().difference(lexRaw.keys.toSet());
  final light = cosOnly.isEmpty
      ? <String, Map<String, Object?>>{}
      : fetchChunkRows(db, sch, cosOnly,
          subject: subject, sourceType: sourceType, withText: false);
  final vecActive = cos.isNotEmpty;
  final boostOn = sourceType == null;
  // RRF 预备（Python L1343-1355）：两路排名表（本路分数降序；并列按
  // chunk_id 升序，跨平台确定性）；排名 1 起；归一基准 2/(k+1)。
  Map<String, int>? rrfRankLex;
  Map<String, int>? rrfRankVec;
  var rrfBase = 1.0;
  if (fusionMode == kFusionRrf) {
    final lexOrder = lexRaw.keys.toList()
      ..sort((a, b) {
        final d = lexRaw[b]! - lexRaw[a]!;
        if (d != 0) return d > 0 ? 1 : -1;
        return a.compareTo(b);
      });
    rrfRankLex = {for (var i = 0; i < lexOrder.length; i++) lexOrder[i]: i + 1};
    final vecOrder = cos.keys.toList()
      ..sort((a, b) {
        final d = cos[b]! - cos[a]!;
        if (d != 0) return d > 0 ? 1 : -1;
        return a.compareTo(b);
      });
    rrfRankVec = {for (var i = 0; i < vecOrder.length; i++) vecOrder[i]: i + 1};
    rrfBase = 2.0 / (rrfKVal! + 1.0);
    notes.add('融合=RRF（k=$rrfKVal）：score=归一化双路名次一致度'
        '（双路皆第一=1.0，单路独占≈0.5；×ppt优先乘子可>1），'
        'weights 不参与融合；分数域与 linear 不同，下游低分线须按模式重校');
  }
  final scored = <(double, double, double, double, double,
      Map<String, Object?>)>[];
  for (final cid in allIds) {
    final row = lexRows[cid] ?? light[cid];
    if (row == null) continue; // 被 subject/source_type 过滤出局
    final ln = lexMax > 0 ? (lexRaw[cid] ?? 0.0) / lexMax : 0.0;
    final cv = cos[cid] ?? 0.0;
    double fused;
    if (fusionMode == kFusionRrf) {
      var s = 0.0;
      final rl = rrfRankLex![cid];
      if (rl != null) s += 1.0 / (rrfKVal! + rl);
      final rv = rrfRankVec![cid];
      if (rv != null) s += 1.0 / (rrfKVal! + rv);
      fused = s / rrfBase;
    } else {
      fused = vecActive ? wLex * ln + wVec * cv : ln;
    }
    final st = '${row['source_type']}';
    final rank = fused *
        (boostOn && st == 'ppt' ? kPptPriorityBoost : 1.0);
    scored.add((rank, fused, ln, cv, lexRaw[cid] ?? 0.0, row));
  }
  if (!vecActive) {
    notes.add('向量路不可用 → '
        '${fusionMode == kFusionRrf
            ? 'RRF 退化为词面单路排名（fused=单路一致度，top-1≈0.5；排序与词面分排序一致）'
            : '融合权重重归一为词面单路（fused=词面归一分）'}');
  }
  scored.sort((a, b) {
    final d = b.$1 - a.$1;
    if (d != 0) return d > 0 ? 1 : -1;
    final pa = '${a.$6['source_type']}' == 'ppt' ? 0 : 1;
    final pb = '${b.$6['source_type']}' == 'ppt' ? 0 : 1;
    if (pa != pb) return pa - pb;
    final sa = int.tryParse('${a.$6['page_start'] ?? 0}') ?? 0;
    final sb = int.tryParse('${b.$6['page_start'] ?? 0}') ?? 0;
    if (sa != sb) return sa - sb;
    return ('${a.$6['chunk_id']}').compareTo('${b.$6['chunk_id']}');
  });
  var top = scored.sublist(0, math.min(k, scored.length));

  // ④ 可选精排（Python L1388-1426）：融合 top-20 窗口，顺序按 rerank 分
  final rerankInfo = {
    'used': false,
    'model': null,
    'window': 0,
    'elapsed_ms': 0,
  };
  Map<String, double>? rerankScores;
  if (rerankOn && scored.length < 2) {
    notes.add('重排跳过：融合候选仅 ${scored.length} 条（<2），重排无意义');
  } else if (rerankOn) {
    final window = scored.sublist(0, math.max(kRerankTopDefault, k));
    final winRows = fetchChunkRows(
        db, sch, window.map((t) => '${t.$6['chunk_id']}'),
        subject: subject, sourceType: sourceType);
    final win = window
        .map((t) => (t.$1, t.$2, t.$3, t.$4, t.$5,
            winRows['${t.$6['chunk_id']}'] ?? t.$6))
        .toList();
    final docs = win
        .map((t) => '${t.$6['title'] ?? ''}\n${t.$6['text'] ?? ''}')
        .toList();
    final tR = Stopwatch()..start();
    final (ranked, usedModel, rreason) = await rerankFn(q, docs);
    rerankInfo['elapsed_ms'] = tR.elapsedMilliseconds;
    rerankInfo['window'] = win.length;
    if (ranked == null) {
      notes.add('重排跳过：$rreason（本查询沿用融合序）');
    } else {
      rerankInfo['used'] = true;
      rerankInfo['model'] = usedModel;
      rerankScores = {
        for (final (i, s) in ranked) '${win[i].$6['chunk_id']}': s,
      };
      top = [for (final (i, _) in ranked.take(k)) win[i]];
      if (top.length < k) {
        // API 少回下标时按融合序垫底补足 k
        final got = top.map((t) => '${t.$6['chunk_id']}').toSet();
        top = [...top, ...win.where((t) => !got.contains('${t.$6['chunk_id']}'))
            .take(k - top.length)];
      }
      notes.add('Reranker=$usedModel：融合 top-${win.length} 精排 → '
          'top-${top.length}（顺序按 rerank 分，score/lex/vec 仍为融合分）');
    }
  }

  // top-k 补全文（Python L1428-1431）
  final need = top
      .where((t) => '${t.$6['text']}'.isEmpty)
      .map((t) => '${t.$6['chunk_id']}')
      .toList();
  final full = need.isEmpty
      ? <String, Map<String, Object?>>{}
      : fetchChunkRows(db, sch, need, subject: subject, sourceType: sourceType);
  final results = <SearchHit>[];
  for (var i = 0; i < top.length; i++) {
    final t = top[i];
    final row = full['${t.$6['chunk_id']}'] ?? t.$6;
    final lraw = t.$5;
    final cv = t.$4;
    final lexHit = lraw > 0;
    final vecHit = vecActive && cv >= kVecHitFloor;
    final path = lexHit && vecHit
        ? 'both'
        : lexHit
            ? 'lexical'
            : vecHit
                ? 'vector'
                : 'none';
    results.add(SearchHit(
      rank: i + 1,
      chunkId: '${row['chunk_id']}',
      subject: '${row['subject_id']}',
      deck: '${row['deck']}',
      pageStart: row['page_start'] == null
          ? null
          : int.tryParse('${row['page_start']}'),
      pageEnd:
          row['page_end'] == null ? null : int.tryParse('${row['page_end']}'),
      pageRange: _pageRange(row),
      title: '${row['title']}',
      sourceType: '${row['source_type']}',
      score: t.$1,
      fused: t.$2,
      lex: t.$3,
      vec: cv,
      hitPath: path,
      preview: _preview('${row['text']}'),
      text: '${row['text']}',
      rerankScore: rerankScores?['${row['chunk_id']}'],
    ));
  }
  final ret = <String, Object?>{
    'ok': true,
    'query': q,
    'subject': subject,
    'k': k,
    'weights': [_pyRound4(wLex), _pyRound4(wVec)],
    'fusion': fusionMode,
    'rerank': rerankInfo,
    'source_type_filter': sourceType,
    'boost_ppt': boostOn,
    'lex': lexInfo,
    'vec': vecInfo,
    'meta': {
      'embedding_model': meta['embedding_model'],
      'embedding_dim': meta['embedding_dim'],
      'fts_mode': meta['fts_mode'],
    },
    'notes': notes,
    'results': results.map((h) => h.toJson()).toList(),
    'elapsed_ms': sw.elapsedMilliseconds,
  };
  if (fusionMode == kFusionRrf) ret['rrf_k'] = rrfKVal;
  return ret;
}
