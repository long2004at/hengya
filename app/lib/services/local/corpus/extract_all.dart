// 恒牙（hengya）· 端上语料建库编排器（extract_all 第二刀）
// ============================================================================
//
// Python 参考实现（语义基准，逐段注明行号，2026-09-06 读取态）：
//   - automation/server-pipeline/extract_pptx.py    树扫描/manifest 增量
//     （_scan_tree L440 / extract_all L455：size+mtime→md5→删旧插新、
//     同名 stem 去重 -2/-3、教材 toc sidecar）
//   - automation/server-pipeline/ingest_embeddings.py 建库+嵌入+幂等
//     （ingest L428：schema/FTS5、deck 幂等剪除、chunk_state 断点续传、
//     每库一 scale int8 量化、模型/维度切换重建、meta 收口）
//   - automation/server-pipeline/refresh_corpus.py    编排（run_default L202：
//     extract → ingest(prune_absent=True)；resolve_ppt_id L163 incoming 避让）
//
// corpus.db 契约（search_corpus.py 文件头 / ingest_embeddings.py 文件头
// 逐列一致；schema 基准见 app/test/fixtures/golden/corpus_schema.sql）：
//   chunks(chunk_id PK, subject_id, ppt_id, deck, page_start, page_end,
//          title, text, source_type, file_date)
//   vectors(chunk_id PK, dim, vec int8 BLOB, scale)   每库共享单一 scale
//   meta(key PK, value)
//   chunk_state(chunk_id PK, content_md5, model, ts) 嵌入断点续传
//   deck_state(subject_id, ppt_id, source, file_path, file_md5,
//              chunk_count, updated_at, PK(subject_id,ppt_id))
//   chunks_fts(fts5: chunk_id UNINDEXED, title, text, trigram)
//   vec_chunks(chunk_id PK, v BLOB NOT NULL) WITHOUT ROWID —— int8 量化向量的
//   float32 归一化镜像（小端 1024×4B/行；检索端 Dart 直接 Float32List 点积，
//   不加载 sqlite-vec 扩展；契约见 docs/sqlite-vec集成与Dart契约-2026-09-06.md
//   §6：KNN k≤4096 不适用全库、虚表物化慢 40x，故存普通表）。
//
// 嵌入双态（+演练态）：
//   offline：无 key → 不写任何向量（vectors 空、镜像表删除）——库可建，
//     检索走词面单路（等价 Python 无 key 语义；后续在线补嵌自动收敛）。
//   online：SiliconFlow /v1/embeddings 批量（input 数组、不带 dimensions、
//     MRL 客户端截断前 dim 维 + 重归一——与 Python api_embed_batch L206/
//     mrl_truncate_renorm L191 一致）；模型默认 Qwen/Qwen3-VL-Embedding-8B
//     （= meta.embedding_model 口径，与检索端同空间互斥校验）；绝不打印 key。
//   drill：确定性伪向量（local-charhash-1024-v1，等价 Python --dry-run，
//     零网络零计费，测试/演练库用；meta 标记 corpus_kind=dryrun-ingest）。
//
// 与 Python 的行为差异（边界输入，金样/生产树不涉及）：
//   - Dart 写出 chunks.jsonl/manifest 统一 LF 行尾（跨平台一致）；
//     Python Windows 文本模式写出为 CRLF。读取双向兼容（splitlines 语义）。
//   - 树扫描扩展名大小写不敏感（对齐 Windows Python rglob + 服务端上传
//     白名单口径；Linux Python 区分大小写）。
//   - vec0_version 记 'dart-native-blob'（Python 记 sqlite-vec 版本——本端
//     不加载扩展，镜像为 Dart 原生 BLOB 写出）。
//   - 若库内遗留 sqlite-vec vec0 虚表（Python 旧库），DROP 需模块在场——
//     Dart 无扩展时 DROP 静默失败 → 检测表仍在即报错并跳过镜像
//     （meta 安全闩已清，检索端自动回退 int8 流式扫描，行为不受影响）。
//   - manifest/chunks.jsonl 由 Dart 重写后与 Python 产物 JSON 语义等价
//     （键/值结构一致，仅缩进/转义风格差异——状态文件非对拍对象）。
//
// 纯 Dart（dart:io + package:sqlite3/crypto），不 import Flutter——可被
// app/ 内任意层使用，也可 `dart run tool/…` 直跑（依赖白名单：extract_*、
// py_compat、search_*、shared、tool）。
import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/sqlite3.dart';

import 'extract_docx.dart' as docx;
import 'extract_pdf.dart' as pdfx;
import 'extract_pptx.dart' as pptx;
import 'outline_docx.dart' as outline;
import 'py_compat.dart'
    show pyPathName, pyPathParentName, pyStrip, serializeChunksJsonl;
import 'search_api.dart'
    show HttpApiException, kEmbedApiUrl, kEmbedDim, kEmbedModel;
import 'search_engine.dart'
    show kLocalEmbedModel, kVec0MetaDim, kVec0Table, localEmbed;

// ------------------------------------------------------------- 常量 ----

/// 嵌入 API 批量上限（Python DEFAULT_BATCH L110 原值 32）。
///
/// 2026-09-10 改 20（向量免费档对齐）：模力方舟（Gitee AI）/v1/embeddings
/// 按 input **条数**分档计费——小批量（约 ≤25 条）免费、大批量按 token 收费
/// （Qwen3-VL-Embedding-8B ¥0.35/M）。账单实证（2026-09-08）：24 条尾批判
/// 小批量 0 元、32 条整批判大批量计费；且同尺寸内容（~103 tokens/条）24 条
/// 免费 / 32 条收费——分界只看条数、不看 token。取 20 留安全余量；429/超时
/// 降批链 20→10→5 全程不越线。查询侧单条、重排窗口 20（search_engine
/// kRerankTopDefault）天然在免费档。
const int kDefaultBatch = 20;

/// 单次嵌入 API 超时秒（Python API_TIMEOUT L111；检索侧 kApiTimeoutS=20
/// 是查询单条口径，建库批量沿用 Python ingest 侧 30s）。
const int kEmbedApiTimeoutS = 30;

/// 退避上限秒（Python MAX_BACKOFF L112）。
const double kMaxBackoffS = 60.0;

/// 连续失败上限（Python MAX_CONSECUTIVE_FAILURES L113；超过中止，重跑断点续传）。
const int kMaxConsecutiveFailures = 6;

/// toc sidecar 子目录名（extract_docx.py TOC_SUBDIR L93 / extract_pdf 同款）。
const String kTocSubdir = 'toc';

/// 离线兜底嵌入维度（Python LOCAL_EMBED_DIM L147）。
const int kLocalEmbedDim = 1024;

/// chunks.jsonl 契约字段序（Python ingest FIELDS L157-158）。
const List<String> kChunkFields = [
  'chunk_id',
  'subject_id',
  'ppt_id',
  'deck',
  'page_start',
  'page_end',
  'title',
  'text',
  'source_type',
  'file_date',
];

/// corpus.db 契约 DDL（Python SCHEMA_* L115-155 逐字一致）。
const String schemaChunks = '''
CREATE TABLE IF NOT EXISTS chunks (
  chunk_id    TEXT PRIMARY KEY,
  subject_id  TEXT NOT NULL,
  ppt_id      TEXT NOT NULL,
  deck        TEXT,
  page_start  INTEGER,
  page_end    INTEGER,
  title       TEXT,
  text        TEXT NOT NULL,
  source_type TEXT NOT NULL DEFAULT 'ppt',
  file_date   TEXT
)''';
const String schemaVectors = '''
CREATE TABLE IF NOT EXISTS vectors (
  chunk_id TEXT PRIMARY KEY REFERENCES chunks(chunk_id),
  dim      INTEGER NOT NULL,
  vec      BLOB NOT NULL,
  scale    REAL NOT NULL
)''';
const String schemaMeta =
    'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);';
const String schemaState = '''
CREATE TABLE IF NOT EXISTS chunk_state (
  chunk_id    TEXT PRIMARY KEY,
  content_md5 TEXT,
  model       TEXT,
  ts          REAL
)''';
const String schemaDecks = '''
CREATE TABLE IF NOT EXISTS deck_state (
  subject_id TEXT NOT NULL,
  ppt_id     TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT 'tree',
  file_path  TEXT,
  file_md5   TEXT,
  chunk_count INTEGER NOT NULL DEFAULT 0,
  updated_at  TEXT,
  PRIMARY KEY (subject_id, ppt_id)
)''';
const String ftsDdl =
    "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5("
    "chunk_id UNINDEXED, title, text, tokenize='trigram')";

// ------------------------------------------------------- 嵌入配置 ----

/// 建库嵌入模式。
enum CorpusEmbedMode {
  /// 无 key：不写向量（库可建，检索词面单路）。
  offline,

  /// 确定性伪向量（local-charhash-1024-v1；等价 Python --dry-run）。
  drill,

  /// SiliconFlow API 真实嵌入（等价 Python 真实模式；需 apiKey）。
  online,
}

/// 建库嵌入配置（模型名与 Python meta 口径一致）。
class CorpusEmbedConfig {
  const CorpusEmbedConfig({
    required this.mode,
    this.apiKey,
    this.model = kEmbedModel,
    this.baseUrl = kEmbedApiUrl,
    this.dim = kEmbedDim,
  });

  const CorpusEmbedConfig.offline() : this(mode: CorpusEmbedMode.offline);

  const CorpusEmbedConfig.drill() : this(mode: CorpusEmbedMode.drill);

  const CorpusEmbedConfig.online(
    this.apiKey, {
    this.model = kEmbedModel,
    this.baseUrl = kEmbedApiUrl,
    this.dim = kEmbedDim,
  }) : mode = CorpusEmbedMode.online;

  final CorpusEmbedMode mode;

  /// 在线模式 API key（绝不打印；offline/drill 忽略）。
  final String? apiKey;

  /// 目标嵌入模型（offline/online 写入 meta.embedding_model；drill 固定
  /// local-charhash-1024-v1）。
  final String model;

  /// /v1/embeddings 完整端点（.env EMBEDDING_BASE_URL 可覆盖）。
  final String baseUrl;

  /// MRL 截断维度（.env EMBED_DIM 可覆盖）。
  final int dim;

  /// 实际写入 meta.embedding_model 的模型标识（drill 强制本地款）。
  String get effectiveModel =>
      mode == CorpusEmbedMode.drill ? kLocalEmbedModel : model;

  /// 实际嵌入维度（drill 固定 kLocalEmbedDim）。
  int get effectiveDim => mode == CorpusEmbedMode.drill ? kLocalEmbedDim : dim;
}

// ------------------------------------------------------------- 统计 ----

/// extract_all 抽取统计（Python extract_all 返回 stats 同构）。
class ExtractAllStats {
  int decksTotal = 0;
  int changed = 0;
  int unchanged = 0;
  int removed = 0;
  int chunks = 0;
  final List<String> skippedBig = [];
  final List<String> errors = [];
  final Map<String, int> bySubject = {};

  /// 节点④：-outline 大纲树文件（跳过常规抽取、不进 chunks/manifest，
  /// 由 ingestOutlineFiles 路由到 outline_entries）。
  final List<String> outlineFiles = [];

  Map<String, Object?> toJson() => {
    'decks_total': decksTotal,
    'changed': changed,
    'unchanged': unchanged,
    'removed': removed,
    'chunks': chunks,
    'skipped_big': skippedBig,
    'errors': errors,
    'by_subject': bySubject,
    'outline_files': outlineFiles,
  };
}

/// ingest 建库统计（Python ingest 返回 stats 同构；dry_run → mode=drill）。
class IngestStats {
  IngestStats({
    required this.input,
    required this.rows,
    required this.badLines,
    required this.mode,
    required this.model,
    required this.dim,
  });

  final String input;
  final int rows;
  final int badLines;
  final String mode; // CorpusEmbedMode.name
  final String model;
  final int dim;
  int prunedStale = 0;
  int prunedAbsent = 0;
  int embedded = 0;
  int resumed = 0;
  int pending = 0;
  int batches = 0;
  int apiBatches = 0;
  int requantized = 0;
  double scale = 1.0;
  double elapsedS = 0;
  Map<String, Object?> vec0 = const {};

  Map<String, Object?> toJson() => {
    'input': input,
    'rows': rows,
    'bad_lines': badLines,
    'mode': mode,
    'model': model,
    'dim': dim,
    'pruned_stale': prunedStale,
    'pruned_absent': prunedAbsent,
    'embedded': embedded,
    'resumed': resumed,
    'pending': pending,
    'batches': batches,
    'api_batches': apiBatches,
    'requantized': requantized,
    'scale': scale,
    'elapsed_s': elapsedS,
    'vec0': vec0,
  };
}

// --------------------------------------------------------- 基础工具 ----

/// datetime.now().isoformat(timespec='seconds')（本地时区，秒精度）。
String nowIso() {
  final s = DateTime.now().toIso8601String(); // …T15:46:29.123456
  return s.length > 19 ? s.substring(0, 19) : s;
}

/// 原子落盘（Python atomic_write_text L119：同目录 tmp 写完 os.replace）。
/// Dart 写出统一 LF、UTF-8 无 BOM（见文件头行为差异节）。
void atomicWriteText(String path, String text) {
  final f = File(path);
  Directory(f.parent.path).createSync(recursive: true);
  final tmp = File('${f.path}.tmp-$pid');
  tmp.writeAsStringSync(text, encoding: convert.utf8, flush: true);
  tmp.renameSync(f.path);
}

/// chunk 侧嵌入编码 = title + "\n" + text（Python content_of L172；契约）。
String contentOf(Map<String, Object?> row) =>
    '${row['title'] ?? ''}\n${row['text'] ?? ''}';

/// 内容指纹（Python content_md5 L177：md5("v1|{model}|{content}")）。
/// 文本或模型变化 → 视为未完成需重嵌（防陈旧向量）。
String contentMd5(String model, String content) =>
    crypto.md5.convert(convert.utf8.encode('v1|$model|$content')).toString();

/// Python round()：十进制半偶舍入（banker's rounding）。
/// Dart .round() 是远离零舍入——量化/重整必须按 Python 口径，否则跨引擎
/// int8 逐分量可能出现 ±1 偏差（余弦影响 ≤1e-4，但为对拍严格性仍对齐）。
int pyRound(double x) {
  final floor = x.floorToDouble();
  final diff = x - floor;
  if (diff > 0.5) return floor.toInt() + 1;
  if (diff < 0.5) return floor.toInt();
  return floor.toInt() % 2 == 0 ? floor.toInt() : floor.toInt() + 1;
}

int _clamp127(int q) => q > 127 ? 127 : (q < -127 ? -127 : q);

/// 按给定 scale 量化：q = clamp(round(v/scale), -127, 127)，小端 int8 BLOB
/// （Python quantize_with_scale L185）。
Uint8List quantizeWithScale(List<double> vec, double scale) {
  final bd = ByteData(vec.length);
  for (var i = 0; i < vec.length; i++) {
    bd.setInt8(i, _clamp127(pyRound(vec[i] / scale)));
  }
  return bd.buffer.asUint8List();
}

/// MRL 客户端截断到 dim 维 + L2 重归一（Python mrl_truncate_renorm L191）。
/// 维度不足报错（模型/配置问题）。
List<double> mrlTruncateRenorm(List<double> vec, int dim) {
  if (vec.length < dim) {
    throw StateError(
      'embeddings API 返回维度 ${vec.length} 小于目标 '
      'EMBED_DIM=$dim（检查 EMBEDDING_MODEL/EMBED_DIM 配置）',
    );
  }
  final v = [for (var i = 0; i < dim; i++) vec[i]];
  var n2 = 0.0;
  for (final x in v) {
    n2 += x * x;
  }
  final n = math.sqrt(n2);
  if (n > 0) {
    for (var i = 0; i < v.length; i++) {
      v[i] /= n;
    }
  }
  return v;
}

/// int8 值序列 → 归一化 float 列表（零向量返回 null——与流式扫描 skip 同口径；
/// Python vec0_normalize L905）。
List<double>? vec0Normalize(Int8List ints) {
  var d2 = 0.0;
  for (final b in ints) {
    d2 += (b * b).toDouble();
  }
  if (d2 <= 0) return null;
  final n = math.sqrt(d2);
  return [for (final b in ints) b / n];
}

/// Uint8List 字节 → 有符号 int8（package:sqlite3 BLOB 返回无符号字节）。
Int8List signedInt8(Uint8List bytes) =>
    Int8List.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

/// 显式事务（Python Tx L311：BEGIN IMMEDIATE → COMMIT/ROLLBACK）。
void tx(Database db, void Function() body) {
  db.execute('BEGIN IMMEDIATE');
  try {
    body();
    db.execute('COMMIT');
  } catch (e) {
    try {
      db.execute('ROLLBACK');
    } catch (_) {}
    rethrow;
  }
}

// --------------------------------------------------------- 树扫描 ----

/// 扫描输入树 → [(文件, 第一层目录名)]（Python _scan_tree L440）。
/// .pptx/.pdf/.docx 统一收集后按路径排序（同名 stem 的 -2/-3 去重依赖
/// 确定序；Windows Python 排序大小写不敏感——本实现小写比较+原串决胜）。
/// 扩展名大小写不敏感（Windows rglob 口径；见文件头行为差异节）。
List<(File, String)> scanCorpusTree(String inputDir) {
  final root = Directory(inputDir);
  final files = <File>[];
  for (final e in root.listSync(recursive: true)) {
    if (e is! File) continue;
    final low = pyPathName(e.path).toLowerCase();
    if (!low.endsWith('.pptx') &&
        !low.endsWith('.pdf') &&
        !low.endsWith('.docx')) {
      continue;
    }
    files.add(e);
  }
  files.sort((a, b) {
    final la = a.path.toLowerCase();
    final lb = b.path.toLowerCase();
    final c = la.compareTo(lb);
    return c != 0 ? c : a.path.compareTo(b.path);
  });
  var rootPath = root.path;
  if (rootPath.endsWith('/') || rootPath.endsWith('\\')) {
    rootPath = rootPath.substring(0, rootPath.length - 1);
  }
  return [for (final f in files) (f, _firstDirOf(_relPosix(f.path, rootPath)))];
}

/// 相对根目录的 posix 路径（Python p.relative_to(root).as_posix()）。
String _relPosix(String path, String rootPath) {
  var p = path;
  if (p.length > rootPath.length + 1 &&
      (p.startsWith('$rootPath\\') || p.startsWith('$rootPath/'))) {
    p = p.substring(rootPath.length + 1);
  }
  return p.replaceAll('\\', '/');
}

/// 第一层目录名（无子目录 → ''，即 subject 回 unknown；Python rel.parts[0]）。
String _firstDirOf(String relPosix) {
  final i = relPosix.indexOf('/');
  return i <= 0 ? '' : relPosix.substring(0, i);
}

// --------------------------------------------------- toc sidecar ----

/// 教材章节锚点 sidecar：`<tocDir>/<subject>.json`（progress_db --init 输入）。
/// 结构与 Python _write_toc_sidecar（extract_pdf L377 / extract_docx L393）
/// 完全一致：{version, subject, textbook, updated_at, chapters:[{no,title,
/// page_start}], sections:[{chapter_no,title,page_start}]}。原子落盘。
String? writeTocSidecar(
  String? tocDir,
  String subjectId,
  String deck,
  List<docx.TocChapter> chapters,
  List<docx.TocSection> sections,
) {
  if (tocDir == null || tocDir.isEmpty) return null;
  final data = <String, Object?>{
    'version': 1,
    'subject': subjectId,
    'textbook': deck,
    'updated_at': nowIso(),
    'chapters': [
      for (final c in chapters)
        {'no': c.no, 'title': c.title, 'page_start': c.pageStart},
    ],
    'sections': [
      for (final s in sections)
        {
          'chapter_no': s.chapterNo,
          'title': s.title,
          'page_start': s.pageStart,
        },
    ],
  };
  final out = '$tocDir/$subjectId.json';
  atomicWriteText(out, const convert.JsonEncoder.withIndent(' ').convert(data));
  return out;
}

// ---------------------------------------------------- 单文件分派 ----

typedef ExtractOneResult = ({
  pptx.DeckInfo deckInfo,
  List<pptx.PptxChunk> chunks,
  List<docx.TocChapter> chapters,
  List<docx.TocSection> sections,
});

/// 按扩展名分派三抽取器（Python extract_all L540-568 分支）：
/// .pdf → extractPdfFile / .docx → extractDocxFile / 其余 → pptx extractFile。
/// subjectId/sourceType 由树扫描按第一层目录名规则显式传入（exam/ 深层
/// 子目录的科目归属由此根治）；大小上限由外层 extractAllCorpus 统一校验，
/// 此处关闭抽取器内置校验（pptx 传 0、pdf/docx 传 null——Python
/// max_file_mb=None 同）。教材源（textbook）写 toc sidecar。
ExtractOneResult extractOneCorpusFile(
  String path,
  String subject,
  String source, {
  String? tocDir,
}) {
  final ext = pyPathName(path).toLowerCase();
  if (ext.endsWith('.pdf')) {
    final r = pdfx.extractPdfFile(
      path,
      subjectId: subject,
      sourceType: source,
      maxFileMb: null,
    );
    if (source == 'textbook' && tocDir != null) {
      // Python extract_pdf：textbook 分支内 toc_dir 给定即写（书签可为空）
      writeTocSidecar(tocDir, subject, r.deckInfo.deck, r.chapters, r.sections);
    }
    return (
      deckInfo: r.deckInfo,
      chunks: r.chunks,
      chapters: r.chapters,
      sections: r.sections,
    );
  }
  if (ext.endsWith('.docx')) {
    final r = docx.extractDocxFile(
      path,
      subjectId: subject,
      sourceType: source,
      maxFileMb: null,
    );
    if (source == 'textbook' && tocDir != null && r.chapters.isNotEmpty) {
      // Python extract_docx：仅标题驱动分支且有 toc_dir 才写（L439）
      writeTocSidecar(tocDir, subject, r.deckInfo.deck, r.chapters, r.sections);
    }
    return (
      deckInfo: r.deckInfo,
      chunks: r.chunks,
      chapters: r.chapters,
      sections: r.sections,
    );
  }
  final (deckInfo, chunks) = pptx.extractFile(
    path,
    subjectId: subject,
    sourceType: source,
    maxFileMb: 0,
  );
  return (
    deckInfo: deckInfo,
    chunks: chunks,
    chapters: const [],
    sections: const [],
  );
}

// ------------------------------------------------------------- manifest ----

/// 读 extract manifest（Python load_manifest L425：坏文件/缺文件 → 空表）。
Map<String, Object?> loadManifest(String path) {
  final f = File(path);
  if (!f.existsSync()) return {'version': 1, 'files': <String, Object?>{}};
  try {
    final d = convert.jsonDecode(f.readAsStringSync(encoding: convert.utf8));
    if (d is Map<String, dynamic> && d['files'] is Map) {
      return {'version': d['version'] ?? 1, 'files': d['files']};
    }
  } catch (_) {}
  return {'version': 1, 'files': <String, Object?>{}};
}

Map<String, Object?> _manifestEntry(Map entry) => {
  'size': entry['size'],
  'mtime': entry['mtime'],
  'md5': entry['md5'],
  'subject': entry['subject'],
  'ppt_id': entry['ppt_id'],
  'chunk_ids': entry['chunk_ids'],
  'updated_at': entry['updated_at'],
};

// ---------------------------------------------------------- 抽取主入口 ----

/// 增量抽取主入口（Python extract_all L455 逐段对齐）。
///
/// [inputPath] 树目录或单文件；[outputPath] chunks.jsonl 全量清单；
/// [manifestPath] 缺省 = outputPath + '.manifest.json'。幂等：manifest
/// 按文件记 size+mtime→md5→chunk_ids——快速路径不读文件；md5 相同仅
/// mtime 变不重抽；同名 stem 同科目（同轮抽取内）→ -2/-3 去重；文件消失
/// → 记脏 deck，jsonl 删旧插新；原子落盘 jsonl + manifest。
ExtractAllStats extractAllCorpus(
  String inputPath,
  String outputPath, {
  String? manifestPath,
  int maxFileMb = pptx.defaultMaxFileMb,
  int? pdfMaxFileMb,
  int? docxMaxFileMb,
  bool forceFull = false,
  void Function(String message)? progress,
}) {
  progress ??= (_) {};
  final singleFileMode =
      FileSystemEntity.typeSync(inputPath) == FileSystemEntityType.file;
  final outp = File(outputPath);
  manifestPath ??= '$outputPath.manifest.json';
  if (!singleFileMode && !Directory(inputPath).existsSync()) {
    throw StateError(
      '输入不存在：$inputPath（先把导出的 PPT 放进去，'
      '第一层子目录=科目短码）',
    );
  }

  // 现有 jsonl 全部读入（Python L479-489；坏行丢弃，下次全量重写即自愈）
  final oldRows = <Map<String, Object?>>{};
  if (outp.existsSync()) {
    for (final line
        in outp.readAsStringSync(encoding: convert.utf8).split(_lineBreakRe)) {
      final t = pyStrip(line);
      if (t.isEmpty) continue;
      try {
        final r = convert.jsonDecode(t);
        if (r is Map<String, dynamic>) oldRows.add(r);
      } catch (_) {}
    }
  }

  final manifest = loadManifest(manifestPath);
  final oldFiles = forceFull
      ? <String, Object?>{}
      : (manifest['files'] as Map).cast<String, Object?>();
  final newFiles = <String, Object?>{};

  // ① 盘上现状（Python L495-502）
  final List<(File, String)> scan;
  String Function(String path) relOf;
  if (singleFileMode) {
    final f = File(inputPath);
    scan = [(f, pyPathParentName(f.path))];
    relOf = (p) => File(p).resolveSymbolicLinksSync(); // str(resolve())
  } else {
    scan = scanCorpusTree(inputPath);
    final rootPath = Directory(inputPath).path;
    relOf = (p) => _relPosix(
      p,
      rootPath.endsWith('/') || rootPath.endsWith('\\')
          ? rootPath.substring(0, rootPath.length - 1)
          : rootPath,
    );
  }

  final stats = ExtractAllStats()..decksTotal = scan.length;
  // toc sidecar 目录：<output 上级>/toc（Python L508）
  final parentDir = outp.parent.path.isEmpty ? '.' : outp.parent.path;
  final tocDir = '$parentDir/$kTocSubdir';
  final dirtyDecks = <(String, String)>{};
  final freshChunks = <pptx.PptxChunk>[];
  final seenPptIds = <(String, String), int>{};

  final onDiskKeys = {for (final (f, _) in scan) relOf(f.path)};

  // ② 已从盘上消失的文件 → 删旧（记脏 deck；Python L514-519）
  for (final e in oldFiles.entries) {
    final entry = _manifestEntry(e.value as Map);
    if (!onDiskKeys.contains(e.key)) {
      stats.removed++;
      dirtyDecks.add(('${entry['subject']}', '${entry['ppt_id']}'));
    }
  }

  for (final (file, firstDir) in scan) {
    final subjSource = pptx.splitSubjectSource(firstDir);
    final subject = subjSource.subject;
    final source = subjSource.sourceType;
    // 节点④（F 证据隔离）：-outline 大纲树文件不进常规语料块——不抽取、
    // 不进 chunks.jsonl/manifest/chunks 表；正文只经 ingestOutlineFiles
    // 入 outline_entries（dagang-outline → 大纲解析器）。
    if (source == 'outline') {
      stats.outlineFiles.add(file.path);
      progress('大纲文件（不入常规语料块，转大纲解析）：${pyPathName(file.path)}');
      continue;
    }
    final key = relOf(file.path);
    final prev0 = oldFiles[key];
    final prev = prev0 is Map ? _manifestEntry(prev0) : null;
    final int size;
    final int mtime;
    try {
      size = file.lengthSync();
      mtime = file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    } catch (e) {
      stats.errors.add('${pyPathName(file.path)}: $e');
      continue;
    }
    // 快速路径：size+mtime 未变 → 跳过（不读文件、不算 md5；Python L531-536）
    final prevIds = prev?['chunk_ids'];
    if (prev != null &&
        prev['size'] == size &&
        prev['mtime'] == mtime &&
        prevIds is List &&
        prevIds.isNotEmpty) {
      stats.unchanged++;
      newFiles[key] = prev;
      continue;
    }
    // 大小上限：按类型取（Python L537-557；extract_docx 无导出常量，
    // Python 侧 DEFAULT_MAX_FILE_MB=250 与 extract_pdf 同值 → 引 pdfx 款）
    final ext = pyPathName(file.path).toLowerCase();
    final int fileMb;
    if (ext.endsWith('.pdf')) {
      fileMb = pdfMaxFileMb ?? pdfx.defaultMaxFileMb;
    } else if (ext.endsWith('.docx')) {
      fileMb = docxMaxFileMb ?? pdfx.defaultMaxFileMb;
    } else {
      fileMb = maxFileMb;
    }
    if (fileMb > 0 && size > fileMb * 1024 * 1024) {
      stats.skippedBig.add(
        '${pyPathName(file.path)}（${(size / 1048576.0).toStringAsFixed(0)} MB）',
      );
      progress('跳过超限文件：${pyPathName(file.path)}');
      continue;
    }
    // 分派抽取（失败/超限统计跳过；Python L558-575）
    pptx.DeckInfo deckInfo;
    List<pptx.PptxChunk> chunks;
    try {
      final r = extractOneCorpusFile(
        file.path,
        subject,
        source,
        tocDir: tocDir,
      );
      deckInfo = r.deckInfo;
      chunks = r.chunks;
    } on pptx.FileTooBig {
      stats.skippedBig.add(pyPathName(file.path));
      continue;
    } catch (e) {
      stats.errors.add('${pyPathName(file.path)}: $e');
      progress('抽取失败：${pyPathName(file.path)}（$e）');
      continue;
    }
    // md5 相同 → 内容没变（仅 mtime 变），不重抽（Python L576-583）
    if (prev != null &&
        prev['md5'] == deckInfo.fileMd5 &&
        prevIds is List &&
        prevIds.isNotEmpty) {
      stats.unchanged++;
      final entry = Map.of(prev)..['mtime'] = mtime;
      newFiles[key] = entry;
      continue;
    }
    // ppt_id 去重：同科目下不同子目录同名文件（同轮抽取内；Python L584-600）
    final stem = deckInfo.pptId;
    final n = (seenPptIds[(subject, stem)] ?? 0) + 1;
    seenPptIds[(subject, stem)] = n;
    if (n > 1) {
      final newPptId = '$stem-$n';
      final oldPrefix = '$subject:$stem:';
      final newPrefix = '$subject:$newPptId:';
      final rewritten = <pptx.PptxChunk>[];
      for (final c in chunks) {
        final cid = c.chunkId;
        String newCid;
        if (cid.startsWith(oldPrefix)) {
          // 前缀替换保留 pdf/docx 拆分后缀（-s2/-s3…）
          newCid = newPrefix + cid.substring(oldPrefix.length);
        } else {
          newCid = pptx.chunkIdOf(subject, newPptId, c.pageStart, c.pageEnd);
        }
        rewritten.add(
          pptx.PptxChunk(
            chunkId: newCid,
            subjectId: c.subjectId,
            pptId: newPptId,
            deck: c.deck,
            pageStart: c.pageStart,
            pageEnd: c.pageEnd,
            title: c.title,
            text: c.text,
            sourceType: c.sourceType,
            fileDate: c.fileDate,
          ),
        );
      }
      deckInfo = pptx.DeckInfo(
        subjectId: deckInfo.subjectId,
        pptId: newPptId,
        deck: deckInfo.deck,
        sourceType: deckInfo.sourceType,
        fileDate: deckInfo.fileDate,
        filePath: deckInfo.filePath,
        fileMd5: deckInfo.fileMd5,
        fileSize: deckInfo.fileSize,
        fileMtime: deckInfo.fileMtime,
      );
      chunks = rewritten;
    }
    // 换过文件名/移动路径 → 旧位置 entry 已在 removed 分支记脏；
    // 同 deck 重抽 → 记脏（删旧插新；Python L601-605）
    if (prev != null) {
      dirtyDecks.add(('${prev['subject']}', '${prev['ppt_id']}'));
    }
    dirtyDecks.add((subject, deckInfo.pptId));
    stats.changed++;
    stats.bySubject[subject] = (stats.bySubject[subject] ?? 0) + 1;
    freshChunks.addAll(chunks);
    newFiles[key] = {
      'size': size,
      'mtime': mtime,
      'md5': deckInfo.fileMd5,
      'subject': subject,
      'ppt_id': deckInfo.pptId,
      'chunk_ids': [for (final c in chunks) c.chunkId],
      'updated_at': nowIso(),
    };
    progress('已抽取：$subject / ${deckInfo.pptId}（${chunks.length} chunks）');
  }

  // ③ 删旧插新：旧 jsonl 中脏 deck 的行剔除，未变 deck 的行保留（Python L618-625）
  final kept = <Map<String, Object?>>[];
  for (final row in oldRows) {
    final deckKey = ('${row['subject_id']}', '${row['ppt_id']}');
    if (dirtyDecks.contains(deckKey)) continue;
    kept.add(row);
  }
  kept.addAll([for (final c in freshChunks) c.toOrderedMap()]);
  stats.chunks = kept.length;

  // ④ 原子落盘 jsonl + manifest（Python L628-637；字段按契约序重投影）
  atomicWriteText(
    outputPath,
    serializeChunksJsonl([
      for (final row in kept) {for (final f in kChunkFields) f: row[f]},
    ]),
  );
  atomicWriteText(
    manifestPath,
    convert.JsonEncoder.withIndent(
      ' ',
    ).convert({'version': 1, 'files': newFiles}),
  );
  return stats;
}

final RegExp _lineBreakRe = RegExp(r'\r\n|\r|\n');

// ------------------------------------------------------- jsonl 读取 ----

int? _coerceInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt(); // Python int(3.7) → 3
  if (v is String) return int.tryParse(v);
  return null;
}

/// 读 chunks.jsonl → (rows, badLines)（Python load_jsonl L366）。
/// 缺字段按契约补默认值；行分割按 splitlines 语义（CRLF/LF 双兼容）。
(List<Map<String, Object?>>, int) loadChunksJsonl(String inputPath) {
  final f = File(inputPath);
  if (!f.existsSync()) {
    throw StateError('chunks.jsonl 不存在：$inputPath（先跑抽取）');
  }
  final rows = <Map<String, Object?>>[];
  var bad = 0;
  for (final rawLine
      in f.readAsStringSync(encoding: convert.utf8).split(_lineBreakRe)) {
    final line = pyStrip(rawLine);
    if (line.isEmpty) continue;
    Map<String, dynamic> r;
    try {
      final d = convert.jsonDecode(line);
      if (d is! Map<String, dynamic>) {
        bad++;
        continue;
      }
      r = d;
    } catch (_) {
      bad++;
      continue;
    }
    final cid = r['chunk_id'];
    final text = r['text'];
    // Python 真值判定：非 dict / 空 chunk_id / 空 text → 坏行
    if (cid == null || (cid is String && cid.isEmpty)) {
      bad++;
      continue;
    }
    if (text == null || (text is String && text.isEmpty)) {
      bad++;
      continue;
    }
    var ps = _coerceInt(r['page_start']) ?? 0;
    var pe = _coerceInt(r['page_end']) ?? ps;
    if (pe < ps) {
      final t = ps;
      ps = pe;
      pe = t;
    }
    final subj = '${r['subject_id'] ?? ''}'.isEmpty
        ? 'unknown'
        : '${r['subject_id']}';
    final pptId = '${r['ppt_id'] ?? ''}'.isEmpty ? '$cid' : '${r['ppt_id']}';
    rows.add({
      'chunk_id': '$cid',
      'subject_id': subj,
      'ppt_id': pptId,
      'deck': '${r['deck'] ?? ''}'.isEmpty ? pptId : '${r['deck']}',
      'page_start': ps,
      'page_end': pe,
      'title': '${r['title'] ?? ''}',
      'text': '$text',
      'source_type': '${r['source_type'] ?? 'ppt'}'.toLowerCase(),
      'file_date': '${r['file_date'] ?? ''}',
    });
  }
  return (rows, bad);
}

// ----------------------------------------------------------- DB 工具 ----

/// 打开/建库（Python connect L300：建父目录 + synchronous=NORMAL，不开 WAL
/// ——journal 默认模式保证 corpus.db 单文件自洽，可直接拷贝迁移）。
Database openCorpusDb(String dbPath) {
  final f = File(dbPath);
  if (f.parent.path.isNotEmpty) {
    f.parent.createSync(recursive: true);
  }
  final db = sqlite3.open(dbPath);
  db.execute('PRAGMA synchronous=NORMAL');
  return db;
}

/// 建表 + 探测 FTS5 可用性（Python ensure_schema L332）。
/// 返回 fts_mode（'fts5_trigram' | 'like'——FTS5 不可用整体 LIKE 降级，
/// 与检索端契约一致）。节点④：一并建 outline_entries（大纲条目树表）。
String ensureCorpusSchema(Database db) {
  for (final ddl in [
    schemaChunks,
    schemaVectors,
    schemaMeta,
    schemaState,
    schemaDecks,
  ]) {
    db.execute(ddl);
  }
  outline.ensureOutlineSchema(db);
  var ftsMode = 'fts5_trigram';
  try {
    db.execute(ftsDdl);
  } catch (e) {
    ftsMode = 'like';
    // ignore: avoid_print
    print('注意：FTS5 不可用（$e）→ fts_mode=like（检索端自动 LIKE 降级）');
  }
  return ftsMode;
}

String? getMeta(Database db, String key, [String? def]) {
  final r = db.select('SELECT value FROM meta WHERE key=?', [key]);
  return r.isEmpty || r.first.columnAt(0) == null
      ? def
      : '${r.first.columnAt(0)}';
}

/// 事务外调用也安全：单独小事务写入 meta 键值（Python set_meta L357）。
void setMeta(Database db, List<(String, String)> kv) {
  tx(db, () {
    final st = db.prepare(
      'INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET '
      'value=excluded.value',
    );
    try {
      for (final (k, v) in kv) {
        st.execute([k, v]);
      }
    } finally {
      st.dispose();
    }
  });
}

bool _ftsAvailable(Database db) {
  try {
    db.select('SELECT chunk_id FROM chunks_fts LIMIT 1');
    return true;
  } catch (_) {
    return false;
  }
}

/// 按 chunk_id 级联清理 chunks/vectors/chunk_state/FTS 行
/// （Python _delete_chunks L404：400/批，防变量数上限）。
void deleteChunksByIds(Database db, List<String> ids) {
  for (var i = 0; i < ids.length; i += 400) {
    final batch = ids.sublist(i, math.min(i + 400, ids.length));
    final qm = List.filled(batch.length, '?').join(',');
    db.execute('DELETE FROM chunks WHERE chunk_id IN ($qm)', batch);
    db.execute('DELETE FROM vectors WHERE chunk_id IN ($qm)', batch);
    db.execute('DELETE FROM chunk_state WHERE chunk_id IN ($qm)', batch);
    if (_ftsAvailable(db)) {
      db.execute('DELETE FROM chunks_fts WHERE chunk_id IN ($qm)', batch);
    }
  }
}

// -------------------------------------------------------- API 批量 ----

Future<Map<String, Object?>> _apiPostJson(
  String url,
  String apiKey,
  Map<String, Object?> payload,
  int timeoutS,
) async {
  final client = HttpClient();
  try {
    final req = await client
        .postUrl(Uri.parse(url))
        .timeout(Duration(seconds: timeoutS));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    req.headers.contentType = ContentType.json;
    req.add(convert.utf8.encode(convert.jsonEncode(payload)));
    final resp = await req.close().timeout(Duration(seconds: timeoutS));
    final bodyBytes = await resp
        .fold<List<int>>([], (acc, d) => acc..addAll(d))
        .timeout(Duration(seconds: timeoutS));
    final body = convert.utf8.decode(bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpApiException(
        resp.statusCode,
        body.length > 300 ? '${body.substring(0, 300)}…' : body,
      );
    }
    return convert.jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}

/// 批量调 SiliconFlow /v1/embeddings（Python api_embed_batch L206）。
/// payload = {"model", "input": [texts]}——不带 dimensions（MRL 客户端截断）。
/// index 字段不可信（SiliconFlow 批量 >8 条时 index 回绕，2026-09-04 实测）：
/// index 唯一且在界内按 index 对位，否则按位置对应。条数不符抛错（调用方
/// 不重试——配置/服务端问题）。绝不打印 key。
Future<List<List<double>>> apiEmbedBatch(
  List<String> texts,
  String apiKey, {
  required String model,
  required String url,
  int timeoutS = kEmbedApiTimeoutS,
}) async {
  final data = await _apiPostJson(url, apiKey, {
    'model': model,
    'input': texts,
  }, timeoutS);
  final items = (data['data'] as List?) ?? const [];
  if (items.length != texts.length) {
    throw StateError(
      'embeddings 返回条数 ${items.length} 与请求 '
      '${texts.length} 不符',
    );
  }
  List<List<double>?>? out;
  final idxs = <int>[];
  var allInt = true;
  for (final it0 in items) {
    final it = it0 as Map<String, Object?>;
    final i = it['index'];
    if (i is int && i >= 0 && i < texts.length) {
      idxs.add(i);
    } else {
      allInt = false;
      break;
    }
  }
  if (allInt && idxs.toSet().length == texts.length) {
    out = List<List<double>?>.filled(texts.length, null);
    for (var pos = 0; pos < items.length; pos++) {
      final it = items[pos] as Map<String, Object?>;
      out[idxs[pos]] = [
        for (final x in it['embedding'] as List) (x as num).toDouble(),
      ];
    }
    if (out.any((v) => v == null)) {
      throw StateError(
        'embeddings 返回条数 ${items.length} 与请求 '
        '${texts.length} 不符',
      );
    }
    return out.cast<List<double>>();
  }
  // index 不可信 → 按位置对应（OpenAI 兼容语义）
  return [
    for (final it0 in items)
      [
        for (final x in (it0 as Map<String, Object?>)['embedding'] as List)
          (x as num).toDouble(),
      ],
  ];
}

// ------------------------------------------------------ vec0 镜像 ----

/// vectors ⋈ chunks → vec_chunks（float32 归一化镜像）全量重建。
/// Dart 侧不加载 sqlite-vec 扩展——镜像恒为普通表 BLOB（契约 §6）。
/// 幂等（Python vec0_rebuild L919）：入口先删 meta 安全闩再 DROP——任何
/// 中途失败都不会留下「可被检索端使用」的半成品（检索端以 meta.vec0_dim
/// 为使用依据，缺失自动回退 int8 流式扫描）。
({
  bool ok,
  String? reason,
  int rows,
  int? dim,
  String serialize,
  int skipped,
  double elapsedS,
})
vec0Rebuild(
  Database db, {
  void Function(String message)? progress,
  int batch = 500,
}) {
  final sw = Stopwatch()..start();
  // ① meta 安全闩先删（任何失败 → 检索端回退流式，行为不受影响）
  tx(db, () {
    for (final key in [kVec0MetaDim, 'vec0_version', 'vec0_rows']) {
      try {
        db.execute('DELETE FROM meta WHERE key=?', [key]);
      } catch (_) {}
    }
  });
  // ② DROP 旧表（普通表直接可删；若为 Python 遗留 vec0 虚表且扩展不在场，
  //    DROP 静默失败 → 检测表仍在即报错跳过，绝不留半成品）
  try {
    db.execute('DROP TABLE IF EXISTS $kVec0Table');
  } catch (_) {}
  final still = db.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [kVec0Table],
  );
  if (still.isNotEmpty) {
    progress?.call(
      'vec0 重建跳过：旧 $kVec0Table 无法删除'
      '（sqlite-vec 虚表需扩展在场）——meta 闩已清，检索回退流式扫描',
    );
    return (
      ok: false,
      reason: '旧 vec_chunks 为 sqlite-vec 虚表且本端不加载扩展',
      rows: 0,
      dim: null,
      serialize: 'none',
      skipped: 0,
      elapsedS: sw.elapsedMilliseconds / 1000.0,
    );
  }
  // ③ 全量读取（维度不齐 → 保持删除并报因，绝不让陈旧镜像参与检索）
  List<(String, Uint8List)> rows;
  try {
    rows = [
      for (final r in db.select(
        'SELECT v.chunk_id, v.vec FROM vectors v '
        'JOIN chunks c ON c.chunk_id = v.chunk_id',
      ))
        ('${r.columnAt(0)}', r.columnAt(1) as Uint8List),
    ];
  } catch (e) {
    return (
      ok: false,
      reason: 'vectors/chunks 表不可读：$e',
      rows: 0,
      dim: null,
      serialize: 'none',
      skipped: 0,
      elapsedS: sw.elapsedMilliseconds / 1000.0,
    );
  }
  if (rows.isEmpty) {
    progress?.call('vec0 重建跳过：无向量行（表已删，检索回退流式扫描）');
    return (
      ok: false,
      reason: '无向量行',
      rows: 0,
      dim: null,
      serialize: 'none',
      skipped: 0,
      elapsedS: sw.elapsedMilliseconds / 1000.0,
    );
  }
  final dims = <int>{
    for (final (_, b) in rows)
      if (b.isNotEmpty) b.length,
  };
  if (dims.length != 1) {
    progress?.call('vec0 重建跳过：维度不齐（${dims.join(',')}）→ 表保持删除');
    return (
      ok: false,
      reason: '维度不齐（${dims.join(',')}）',
      rows: 0,
      dim: null,
      serialize: 'none',
      skipped: 0,
      elapsedS: sw.elapsedMilliseconds / 1000.0,
    );
  }
  final dim = dims.first;
  db.execute(
    'CREATE TABLE $kVec0Table(chunk_id TEXT PRIMARY KEY, '
    'v BLOB NOT NULL) WITHOUT ROWID',
  );
  // ④ 归一化写镜像（零向量跳过；与流式扫描 skip 同口径）
  String? probeId;
  List<double>? probeVec;
  for (final (cid, blob) in rows) {
    if (blob.length != dim) continue;
    final nv = vec0Normalize(signedInt8(blob));
    if (nv == null) continue;
    probeId = cid;
    probeVec = nv;
    break;
  }
  if (probeId == null || probeVec == null) {
    progress?.call('vec0 重建跳过：全零向量（表已删）');
    return (
      ok: false,
      reason: '全零向量',
      rows: 0,
      dim: null,
      serialize: 'none',
      skipped: 0,
      elapsedS: sw.elapsedMilliseconds / 1000.0,
    );
  }
  Uint8List ser(List<double> nv) {
    final bd = ByteData(dim * 4);
    for (var i = 0; i < dim; i++) {
      bd.setFloat32(i * 4, nv[i], Endian.little);
    }
    return bd.buffer.asUint8List();
  }

  var count = 1;
  var skipped = 0;
  final ins = db.prepare('INSERT INTO $kVec0Table(chunk_id, v) VALUES (?, ?)');
  try {
    // 批量提交（Python executemany + 每批 commit；默认 500/批）
    var insertedBuf = <(String, Uint8List)>[];
    void flush() {
      if (insertedBuf.isEmpty) return;
      tx(db, () {
        for (final (cid, blob) in insertedBuf) {
          ins.execute([cid, blob]);
        }
      });
      insertedBuf = [];
    }

    ins.execute([probeId, ser(probeVec)]); // 探针行（同 Python：先插探针）
    for (final (cid, blob) in rows) {
      if (cid == probeId) continue;
      if (blob.length != dim) {
        skipped++;
        continue;
      }
      final nv = vec0Normalize(signedInt8(blob));
      if (nv == null) {
        skipped++;
        continue;
      }
      insertedBuf.add((cid, ser(nv)));
      count++;
      if (insertedBuf.length >= batch) {
        flush();
        if (count % 2000 < batch) {
          progress?.call('vec0 回填 $count 行…');
        }
      }
    }
    flush();
  } finally {
    ins.dispose();
  }
  setMeta(db, [
    (kVec0MetaDim, '$dim'),
    ('vec0_version', 'dart-native-blob'),
    ('vec0_rows', '$count'),
  ]);
  progress?.call(
    'vec0 重建完成：$count 行 float[$dim]（dart-native-blob，'
    '跳过 $skipped，耗时 ${(sw.elapsedMilliseconds / 1000.0).toStringAsFixed(1)}s）',
  );
  return (
    ok: true,
    reason: null,
    rows: count,
    dim: dim,
    serialize: 'blob',
    skipped: skipped,
    elapsedS: sw.elapsedMilliseconds / 1000.0,
  );
}

// --------------------------------------------------------- 建库主入口 ----

/// incoming 文件 ppt_id 去重（Python refresh_corpus.resolve_ppt_id L163）：
/// 该 (subject, stem) 无 deck 记录 → stem；已有记录且 file_path 或 md5
/// 相同（同名新版/重传同内容）→ 沿用 stem（换版 upsert）；来自另一文件
/// （路径与 md5 都不同）→ 加 -2/-3… 最小可用后缀。
String resolvePptId(
  Database db,
  String subject,
  String stem,
  String thisMd5,
  String thisPath,
) {
  final row = db.select(
    'SELECT file_path, file_md5 FROM deck_state '
    'WHERE subject_id=? AND ppt_id=?',
    [subject, stem],
  );
  if (row.isEmpty) return stem;
  final oldPath = '${row.first.columnAt(0) ?? ''}';
  final oldMd5 = '${row.first.columnAt(1) ?? ''}';
  if (oldPath == thisPath || (oldMd5.isNotEmpty && oldMd5 == thisMd5)) {
    return stem;
  }
  var n = 2;
  while (true) {
    final cand = '$stem-$n';
    final hit = db.select(
      'SELECT 1 FROM deck_state '
      'WHERE subject_id=? AND ppt_id=?',
      [subject, cand],
    );
    if (hit.isEmpty) return cand;
    n++;
  }
}

/// 建库/增量入库主入口（Python ingest L428 逐段对齐；refresh/CLI/测试共用）。
///
/// 幂等链：chunk_state(content_md5) + vectors 双确认 → 续传跳过不重复计费；
/// deck 级删旧插新；树外 deck 剪除（pruneAbsent=true 且 source=tree）；
/// 模型/维度切换 → 向量全量重建（chunks 保留）；每库一 scale 结尾本地重整；
/// FTS 全量重建；vec_chunks 镜像重建；meta 收口。
///
/// [preserveDeckSource] 用于重建/库内自嵌：冲突更新保留既有 deck 的 source
/// （如 package 的树外剪除豁免）；新增 deck 仍使用 [source]，默认 false。
///
/// [embed] 三态：offline（无 key，不写向量）/ drill（确定性伪向量）/
/// online（API 批量，429/超时退避降批、5xx 只退避、4xx 立即报错）。
Future<IngestStats> ingestCorpus(
  String dbPath,
  String inputPath, {
  required CorpusEmbedConfig embed,
  int batchSize = kDefaultBatch,
  String source = 'tree',
  bool pruneAbsent = false,
  bool resetVectors = false,
  bool preserveDeckSource = false,
  Map<(String, String), ({String? filePath, String? fileMd5})> deckFiles =
      const {},
  void Function(String message)? progress,
  int apiTimeoutS = kEmbedApiTimeoutS,
}) async {
  // progress 参数在 tx 闭包内会丢失空安全提升 → 落地非空本地变量
  final onProgress = progress ?? (String _) {};
  final sw = Stopwatch()..start();
  final mode = embed.mode;

  if (mode == CorpusEmbedMode.online && (embed.apiKey ?? '').isEmpty) {
    throw StateError(
      '在线模式需要 SILICONFLOW_API_KEY（.env 或环境变量）；'
      '无 key 建库请用 offline（不写向量）或 drill（确定性伪向量）',
    );
  }
  final model = embed.effectiveModel;
  final dim = embed.effectiveDim;

  final (rows, badLines) = loadChunksJsonl(inputPath);
  // 0 行：仅 resetVectors=true 时允许走库内自嵌（见 ②'）；否则维持
  // 原契约抛错（正常 ingest 必须有 jsonl 源行——两个上游调用点
  // buildCorpus/worker 均有 0-chunks 守卫，此抛错为直接调用方的兜底）。
  if (rows.isEmpty && !resetVectors) {
    throw StateError('chunks.jsonl 无有效行（坏行 $badLines）：$inputPath');
  }
  final stats = IngestStats(
    input: inputPath,
    rows: rows.length,
    badLines: badLines,
    mode: mode.name,
    model: model,
    dim: dim,
  );

  final db = openCorpusDb(dbPath);
  try {
    // ① 建表 + FTS 探测
    final ftsMode = ensureCorpusSchema(db);

    // ② 模型/维度切换检测：与库内不符 → 向量全量重建（chunks 保留）
    final oldModel = getMeta(db, 'embedding_model');
    final oldDim = getMeta(db, 'embedding_dim');
    if (resetVectors) {
      tx(db, () {
        db.execute('DELETE FROM vectors');
        db.execute('DELETE FROM chunk_state');
      });
      onProgress('已按 resetVectors 清空向量与 checkpoint');
    } else if (oldModel != null &&
        oldModel.isNotEmpty &&
        oldModel.toLowerCase() != model.toLowerCase()) {
      tx(db, () {
        db.execute('DELETE FROM vectors');
        db.execute('DELETE FROM chunk_state');
      });
      onProgress('嵌入模型切换（$oldModel → $model）：向量全量重建');
    } else if (oldDim != null && oldDim.isNotEmpty && oldDim != '$dim') {
      tx(db, () {
        db.execute('DELETE FROM vectors');
        db.execute('DELETE FROM chunk_state');
      });
      onProgress('维度切换（$oldDim → $dim）：向量全量重建');
    }

    // ②' 库内自嵌（2026-09-11 强制重建语义 v2「彻底重建」）：resetVectors=true
    // → 恒从库内 chunks 表读出全部行，与 jsonl 行合并作为嵌入源，向量按当前
    // embedding 配置全量重建。v1 缺陷：原条件 `rows.isEmpty && resetVectors`
    // 只有 chunks.jsonl 为空（incoming 无文件）才读库内行——一旦本机手动上传
    // 过课件（chunks.jsonl 非空），语料包导入的 chunks（在库、不在 jsonl）
    // 被排除出重建范围，「重建全部向量」只重算了手动课件。v2 语义：重建 =
    // 库内全量 ∪ jsonl 新行（chunk_id 去重、jsonl 优先——新抽取覆盖旧内容）。
    // rows 由此非空，流过 ③ deck 幂等 / ④ upsert 时 ON CONFLICT 全命中或
    // jsonl 新行使 upsert 生效、text 以合并集为准，⑥ 向量全量重嵌——**chunks
    // 保留、仅向量重建**（与 0-chunks 早退语义区分：库内自嵌 ≠ 新增语料）。
    var rowsEff = rows;
    if (resetVectors) {
      // 无 oldModel（全新空库）也无妨：fromDb 空 → 合并后仍只有 jsonl 行，
      // 行为退化为正常 ingest；库内有 chunks 时必然重建库内全量。
      final fromDb = <String, Map<String, Object?>>{}; // key=chunk_id 去重
      for (final r in db.select(
        'SELECT chunk_id, subject_id, ppt_id, deck, page_start, page_end, '
        'title, text, source_type, file_date FROM chunks',
      )) {
        final cid = '${r['chunk_id']}';
        final text = '${r['text']}';
        if (cid.isEmpty || text.isEmpty) continue;
        fromDb[cid] = {
          'chunk_id': cid,
          'subject_id': '${r['subject_id'] ?? 'unknown'}',
          'ppt_id': '${r['ppt_id'] ?? cid}',
          'deck': '${r['deck'] ?? ''}'.isEmpty
              ? '${r['ppt_id'] ?? cid}'
              : '${r['deck']}',
          'page_start': r['page_start'] as int? ?? 0,
          'page_end': r['page_end'] as int? ?? 0,
          'title': '${r['title'] ?? ''}',
          'text': text,
          'source_type': '${r['source_type'] ?? 'ppt'}',
          'file_date': '${r['file_date'] ?? ''}',
        };
      }
      if (fromDb.isNotEmpty || rows.isNotEmpty) {
        final merged = <Map<String, Object?>>[];
        final seen = <String>{};
        // jsonl 行优先（新抽取的最新内容），库内独有行并入
        for (final r in rows) {
          merged.add(r);
          seen.add('${r['chunk_id']}');
        }
        for (final e in fromDb.entries) {
          if (!seen.contains(e.key)) merged.add(e.value);
        }
        rowsEff = merged;
        // stats.rows 保持 jsonl 行数（final 字段诚实语义——库内合并行数经
        // progress 消息透出）
        if (fromDb.isNotEmpty) {
          onProgress(
            '彻底重建：按库内 ${merged.length} chunks 全量重新嵌入'
            '（合并 jsonl ${rows.length} + 库内 ${fromDb.length}）',
          );
        }
      }
    }

    // ③ deck 幂等：jsonl 内 deck 的陈旧 chunk 删除 + 可选树外 deck 剪除
    final decks = <(String, String), List<Map<String, Object?>>>{};
    for (final r in rowsEff) {
      decks
          .putIfAbsent(('${r['subject_id']}', '${r['ppt_id']}'), () => [])
          .add(r);
    }
    tx(db, () {
      for (final e in decks.entries) {
        final (subj, ppt) = e.key;
        final curIds = {for (final r in e.value) '${r['chunk_id']}'};
        List<String> dbIds;
        if (curIds.isNotEmpty) {
          final qm = List.filled(curIds.length, '?').join(',');
          dbIds = [
            for (final r in db.select(
              'SELECT chunk_id FROM chunks '
              'WHERE subject_id=? AND ppt_id=? AND chunk_id NOT IN ($qm)',
              [subj, ppt, ...curIds],
            ))
              '${r.columnAt(0)}',
          ];
        } else {
          dbIds = [
            for (final r in db.select(
              'SELECT chunk_id FROM chunks '
              'WHERE subject_id=? AND ppt_id=?',
              [subj, ppt],
            ))
              '${r.columnAt(0)}',
          ];
        }
        if (dbIds.isNotEmpty) {
          deleteChunksByIds(db, dbIds);
          stats.prunedStale += dbIds.length;
        }
      }
      if (pruneAbsent && source == 'tree') {
        final inDb = [
          for (final r in db.select(
            "SELECT subject_id, ppt_id FROM deck_state "
            "WHERE source='tree'",
          ))
            ('${r.columnAt(0)}', '${r.columnAt(1)}'),
        ];
        for (final (subj, ppt) in inDb) {
          if (!decks.containsKey((subj, ppt))) {
            final ids = [
              for (final r in db.select(
                'SELECT chunk_id FROM chunks '
                'WHERE subject_id=? AND ppt_id=?',
                [subj, ppt],
              ))
                '${r.columnAt(0)}',
            ];
            deleteChunksByIds(db, ids);
            db.execute(
              'DELETE FROM deck_state WHERE subject_id=? AND ppt_id=?',
              [subj, ppt],
            );
            stats.prunedAbsent += ids.length;
            onProgress('剪除树外 deck：$subj / $ppt（${ids.length} chunks）');
          }
        }
      }
    });

    // ④ chunks upsert + deck_state 登记（Python L524-544）
    tx(db, () {
      final up = db.prepare(
        'INSERT INTO chunks VALUES (?,?,?,?,?,?,?,?,?,?) '
        'ON CONFLICT(chunk_id) DO UPDATE SET '
        'subject_id=excluded.subject_id, ppt_id=excluded.ppt_id, '
        'deck=excluded.deck, page_start=excluded.page_start, '
        'page_end=excluded.page_end, title=excluded.title, '
        'text=excluded.text, source_type=excluded.source_type, '
        'file_date=excluded.file_date',
      );
      try {
        for (final r in rowsEff) {
          up.execute([for (final f in kChunkFields) r[f]]);
        }
      } finally {
        up.dispose();
      }
      // 重建/库内自嵌不覆盖既有来源章；INSERT 仍按 source 登记新 deck。
      final ds = db.prepare(
        'INSERT INTO deck_state VALUES (?,?,?,?,?,?,?) '
        'ON CONFLICT(subject_id, ppt_id) DO UPDATE SET '
        '${preserveDeckSource ? '' : 'source=excluded.source, '}'
        'file_path=excluded.file_path, '
        'file_md5=excluded.file_md5, chunk_count=excluded.chunk_count, '
        'updated_at=excluded.updated_at',
      );
      try {
        for (final e in decks.entries) {
          final (subj, ppt) = e.key;
          final finfo = deckFiles[e.key];
          ds.execute([
            subj,
            ppt,
            source,
            finfo?.filePath,
            finfo?.fileMd5,
            e.value.length,
            nowIso(),
          ]);
        }
      } finally {
        ds.dispose();
      }
    });

    // ⑤ 计算待嵌列表（checkpoint：chunk_state + vectors 双确认）
    final done = <String, String>{};
    for (final r in db.select(
      'SELECT chunk_id, content_md5 FROM chunk_state',
    )) {
      done['${r.columnAt(0)}'] = '${r.columnAt(1) ?? ''}';
    }
    final haveVec = {
      for (final r in db.select('SELECT chunk_id FROM vectors'))
        '${r.columnAt(0)}',
    };
    final pending = <(Map<String, Object?>, String)>[];
    for (final r in rowsEff) {
      final cid = '${r['chunk_id']}';
      final cMd5 = contentMd5(model, contentOf(r));
      if (done[cid] == cMd5 && haveVec.contains(cid)) {
        stats.resumed++;
        continue;
      }
      pending.add((r, contentOf(r)));
    }
    stats.pending = pending.length;

    // ⑥ 批量嵌入（事务级 checkpoint；<db>.ckpt 侧车逐批追加）
    var curMax = 0.0;
    // 存量行的有效分量极值（scale 统一时 = 127×scale；混合历史逐行算）
    for (final r in db.select('SELECT vec, scale FROM vectors')) {
      final blob = r.columnAt(0) as Uint8List;
      if (blob.isEmpty) continue;
      final vscale = ((r.columnAt(1) as num?)?.toDouble() ?? 0) != 0
          ? (r.columnAt(1) as num).toDouble()
          : 1.0; // float(vscale) or 1.0
      var m = 0;
      for (final b in blob) {
        final a = b < 128 ? b : 256 - b; // 有符号 int8 绝对值
        if (a > m) m = a;
      }
      final eff = m * vscale;
      if (eff > curMax) curMax = eff;
    }
    if (pending.isNotEmpty && mode != CorpusEmbedMode.offline) {
      final ckptPath = '$dbPath.ckpt';
      final ckpt = File(ckptPath).openSync(mode: FileMode.append);
      try {
        var i = 0;
        var fails = 0;
        var batch = math.max(1, batchSize);
        while (i < pending.length) {
          final take = pending.sublist(i, math.min(i + batch, pending.length));
          try {
            final List<List<double>> vecs;
            if (mode == CorpusEmbedMode.drill) {
              vecs = [for (final (_, c) in take) localEmbed(c, dim: dim)];
            } else {
              final raw = await apiEmbedBatch(
                [for (final (_, c) in take) c],
                embed.apiKey!,
                model: model,
                url: embed.baseUrl,
                timeoutS: apiTimeoutS,
              );
              vecs = [for (final v in raw) mrlTruncateRenorm(v, dim)];
            }
            fails = 0;
            i += take.length;
            for (final v in vecs) {
              for (final x in v) {
                final a = x.abs();
                if (a > curMax) curMax = a;
              }
            }
            final scale = curMax > 0 ? curMax / 127.0 : 1.0;
            final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
            tx(db, () {
              final pv = db.prepare(
                'INSERT INTO vectors VALUES (?,?,?,?) '
                'ON CONFLICT(chunk_id) DO UPDATE SET dim=excluded.dim, '
                'vec=excluded.vec, scale=excluded.scale',
              );
              final pc = db.prepare(
                'INSERT INTO chunk_state VALUES (?,?,?,?) '
                'ON CONFLICT(chunk_id) DO UPDATE SET '
                'content_md5=excluded.content_md5, model=excluded.model, '
                'ts=excluded.ts',
              );
              try {
                for (var j = 0; j < take.length; j++) {
                  final (r, c) = take[j];
                  final cid = '${r['chunk_id']}';
                  pv.execute([
                    cid,
                    vecs[j].length,
                    quantizeWithScale(vecs[j], scale),
                    scale,
                  ]);
                  pc.execute([cid, contentMd5(model, c), model, now]);
                }
              } finally {
                pv.dispose();
                pc.dispose();
              }
            });
            stats.embedded += take.length;
            stats.batches++;
            if (mode == CorpusEmbedMode.online) stats.apiBatches++;
            for (final (r, _) in take) {
              ckpt.writeStringSync('${r['chunk_id']}\n');
            }
            onProgress(
              '嵌入 ${stats.embedded}/${pending.length}'
              '（scale=${scale.toStringAsFixed(6)}）',
            );
          } on HttpApiException catch (e) {
            if (e.statusCode == 429) {
              // 限流 → 退避 + 降批
              if (batch > 1) {
                batch = math.max(1, batch ~/ 2);
                onProgress('429 限流：批量降至 $batch');
              }
              fails++;
            } else if (e.statusCode >= 500) {
              fails++; // 服务端 → 只退避
            } else {
              // 400/401/403 配置类 → 立即报错（重试无意义）
              throw StateError('embeddings API HTTP ${e.statusCode}：${e.body}');
            }
            if (fails > kMaxConsecutiveFailures) {
              throw StateError(
                'embeddings API 连续失败 $fails 次（最后 HTTP '
                '${e.statusCode}），中止——重跑将断点续传',
              );
            }
            await Future<void>.delayed(
              Duration(
                milliseconds:
                    (math.min(kMaxBackoffS, 2.0 * math.pow(2, fails)) * 1000)
                        .toInt(),
              ),
            );
          } on SocketException catch (e) {
            // 超时/网络 → 退避 + 降批（大响应在小带宽下超时更常见）
            if (batch > 1) {
              batch = math.max(1, batch ~/ 2);
              onProgress('网络异常（$e）：批量降至 $batch');
            }
            fails++;
            if (fails > kMaxConsecutiveFailures) {
              throw StateError(
                'embeddings API 连续失败 $fails 次（最后 $e），'
                '中止——重跑将断点续传',
              );
            }
            await Future<void>.delayed(
              Duration(
                milliseconds:
                    (math.min(kMaxBackoffS, 2.0 * math.pow(2, fails)) * 1000)
                        .toInt(),
              ),
            );
          } on TimeoutException catch (e) {
            if (batch > 1) {
              batch = math.max(1, batch ~/ 2);
              onProgress('网络超时（$e）：批量降至 $batch');
            }
            fails++;
            if (fails > kMaxConsecutiveFailures) {
              throw StateError(
                'embeddings API 连续失败 $fails 次（超时），'
                '中止——重跑将断点续传',
              );
            }
            await Future<void>.delayed(
              Duration(
                milliseconds:
                    (math.min(kMaxBackoffS, 2.0 * math.pow(2, fails)) * 1000)
                        .toInt(),
              ),
            );
          }
        }
      } finally {
        ckpt.closeSync();
      }
    } else if (pending.isNotEmpty && mode == CorpusEmbedMode.offline) {
      onProgress(
        'offline 模式：${pending.length} chunks 跳过嵌入'
        '（无 key → 向量路禁用；后续在线建库自动断点补嵌）',
      );
    }

    // ⑦ 每库一 scale 收敛：结尾对 scale 不一致的存量行本地重整（不调 API）
    final finalScale = curMax > 0 ? curMax / 127.0 : 1.0;
    var nRequant = 0;
    final toFix = <(String, Uint8List, double)>[];
    for (final r in db.select('SELECT chunk_id, vec, scale FROM vectors')) {
      final blob = r.columnAt(1) as Uint8List;
      if (blob.isEmpty) continue;
      final vs = (r.columnAt(2) as num?)?.toDouble() ?? 0;
      if ((vs - finalScale).abs() > 1e-12) {
        toFix.add(('${r.columnAt(0)}', blob, vs != 0 ? vs : 1.0));
      }
    }
    if (toFix.isNotEmpty) {
      tx(db, () {
        final up = db.prepare(
          'UPDATE vectors SET vec=?, scale=? WHERE chunk_id=?',
        );
        try {
          for (final (cid, blob, vscale) in toFix) {
            final n = blob.length;
            final bd = ByteData(n);
            final ints = signedInt8(blob);
            for (var j = 0; j < n; j++) {
              bd.setInt8(j, _clamp127(pyRound(ints[j] * vscale / finalScale)));
            }
            up.execute([bd.buffer.asUint8List(), finalScale, cid]);
            nRequant++;
          }
        } finally {
          up.dispose();
        }
      });
      onProgress(
        '全局 scale 收敛：重整存量向量 $nRequant 行 → '
        'scale=${finalScale.toStringAsFixed(6)}',
      );
    }
    stats.scale = finalScale;
    stats.requantized = nRequant;

    // ⑧ FTS 全量重建（FTS5 可用时；与 chunks 严格一致）
    if (ftsMode == 'fts5_trigram') {
      tx(db, () {
        db.execute('DELETE FROM chunks_fts');
        db.execute(
          "INSERT INTO chunks_fts (chunk_id, title, text) "
          "SELECT chunk_id, COALESCE(title,''), text FROM chunks",
        );
      });
    }

    // ⑧.5 vec_chunks 镜像全量重建（失败不阻断建库——检索端自动回退流式）
    try {
      final v = vec0Rebuild(db, progress: onProgress);
      stats.vec0 = {
        'ok': v.ok,
        if (v.reason != null) 'reason': v.reason,
        if (v.ok) 'rows': v.rows,
        if (v.dim != null) 'dim': v.dim,
        'serialize': v.serialize,
        'skipped': v.skipped,
        'elapsed_s': v.elapsedS,
      };
    } catch (e) {
      stats.vec0 = {'ok': false, 'reason': '$e'};
      onProgress('vec0 重建异常（检索回退流式扫描）：$e');
    }

    // ⑨ meta 收口（Python L652-669）
    stats.elapsedS = sw.elapsedMilliseconds / 1000.0;
    final metaKv = <(String, String)>[
      ('embedding_model', model),
      ('embedding_dim', '$dim'),
      ('fts_mode', ftsMode),
      ('quant_scale', finalScale.toString()),
      ('updated_at', nowIso()),
      (
        'corpus_kind',
        switch (mode) {
          CorpusEmbedMode.drill => 'dryrun-ingest',
          CorpusEmbedMode.online => 'real',
          CorpusEmbedMode.offline => 'offline-ingest',
        },
      ),
      if (getMeta(db, 'built_at') == null) ('built_at', nowIso()),
      (
        'last_ingest',
        convert.jsonEncode({
          'rows': stats.rows,
          'pending': stats.pending,
          'embedded': stats.embedded,
          'resumed': stats.resumed,
          'pruned_stale': stats.prunedStale,
          'pruned_absent': stats.prunedAbsent,
          'scale': stats.scale,
          'elapsed_s': stats.elapsedS,
        }),
      ),
    ];
    setMeta(db, metaKv);
    return stats;
  } finally {
    db.dispose();
  }
}

// ------------------------------------------------------------- 编排 ----

/// 一条命令完成「语料树变更 → corpus.db 更新」（Python refresh_corpus.
/// run_default L202 逐段对齐）：extract 增量 → ingest 嵌入 + 事务性
/// upsert（pruneAbsent=true，树里删掉的 deck 同步剪库）。
///
/// 节点④：extract 发现的 -outline 大纲文件在 ingest 前先经
/// ingestOutlineFiles 入 outline_entries（不走常规切块/嵌入）；仅大纲
/// 入库（0 chunks）不再是告警路径。
///
/// [chunksJsonlPath]/[manifestPath] 缺省落在 db 同级目录（= Python
/// corpus_dir 约定：chunks.jsonl / extract_manifest.json / toc/）。
/// 返回 (extract, ingest)；抽取结果 0 chunks 且无大纲条目时 ingest 为
/// null（仅告警）。
Future<(ExtractAllStats, IngestStats?)> buildCorpus({
  required String inputPath,
  required String dbPath,
  String? chunksJsonlPath,
  String? manifestPath,
  required CorpusEmbedConfig embed,
  int batch = kDefaultBatch,
  int? maxFileMb,
  int? pdfMaxFileMb,
  int? docxMaxFileMb,
  bool forceFull = false,
  void Function(String message)? progress,
}) async {
  progress ??= (_) {};
  final dbFile = File(dbPath);
  final corpusDir = dbFile.parent.path.isEmpty ? '.' : dbFile.parent.path;
  chunksJsonlPath ??= '$corpusDir/chunks.jsonl';
  manifestPath ??= '$corpusDir/extract_manifest.json';
  final ex = extractAllCorpus(
    inputPath,
    chunksJsonlPath,
    manifestPath: manifestPath,
    maxFileMb: maxFileMb ?? pptx.defaultMaxFileMb,
    pdfMaxFileMb: pdfMaxFileMb,
    docxMaxFileMb: docxMaxFileMb,
    forceFull: forceFull,
    progress: progress,
  );
  // 节点④：大纲文件 → outline_entries（幂等；零网络零嵌入）
  if (ex.outlineFiles.isNotEmpty) {
    final db = openCorpusDb(dbPath);
    try {
      outline.ingestOutlineFiles(db, ex.outlineFiles, progress: progress);
    } finally {
      db.dispose();
    }
  }
  if (ex.chunks == 0) {
    if (ex.outlineFiles.isEmpty) {
      progress(
        '警告：抽取结果 0 chunks——检查 $inputPath 下是否放了 '
        '.pptx/.pdf/.docx（第一层子目录=科目短码）',
      );
    } else {
      progress('仅大纲入库（0 chunks）：outline_entries 已更新，无语料块');
    }
    return (ex, null);
  }
  final ing = await ingestCorpus(
    dbPath,
    chunksJsonlPath,
    embed: embed,
    batchSize: batch,
    source: 'tree',
    pruneAbsent: true,
    progress: progress,
  );
  return (ex, ing);
}
