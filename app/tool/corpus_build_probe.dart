// 恒牙（hengya）· extract_all 第二刀 · 建库探针（CLI 冒烟）
// ============================================================================
//
// 用法（cwd=app/；Windows 下自动加载 test/sqlite3.dll，同 test/* 基建）：
//   dart run tool/corpus_build_probe.dart [input-dir]
//       [--db <path>] [--mode offline|drill|online] [--env <file>]
//       [--batch N] [--force-full] [--query Q] [--k N] [--json]
//
//   input-dir  默认 ../content/ppt_raw（第一层子目录=科目短码；
//              xxx-textbook / xxx-exam / exam 命名规则同 Python）
//   --db       默认临时目录（绝不写进 input 树；探针库勿替代生产库）
//   --mode     嵌入态：offline=无 key 不写向量（默认）；drill=确定性伪向量
//              （local-charhash，零网络）；online=SiliconFlow API（需要 key，
//              全库嵌入有真实计费——请显式指定）
//   --env      .env 路径（默认 ../automation/server-pipeline/.env，其次
//              当前目录 .env；同名环境变量优先于 .env；绝不打印 key 值）
//   --query    建库后离线检索冒烟（corpusSearch offline；词面+伪向量/词面）
//
// 输出：建库统计（extract/ingest）+ schema/行数报告（表清单、行数、chunks
// 列、meta、deck_state、vec_chunks 镜像）+ 可选检索冒烟；--json 输出机器
// 可读结构。嵌入模型口径与 Python meta 一致（meta.embedding_model）。
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/services/local/corpus/extract_all.dart';
import 'package:hengya/services/local/corpus/search_api.dart'
    show kEmbedApiUrl, kEmbedDim, kEmbedModel;
import 'package:hengya/services/local/corpus/search_engine.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

/// .env KEY=VALUE 解析（同 search_probe 口径；值不打印）。
Map<String, String> parseEnvFile(String path) {
  final f = File(path);
  if (!f.existsSync()) return {};
  final env = <String, String>{};
  for (final raw in f.readAsStringSync(encoding: convert.utf8).split('\n')) {
    final t = raw.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final eq = t.indexOf('=');
    if (eq <= 0) continue;
    env[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
  }
  return env;
}

/// Python ENV_KEY_NAMES 同款（search_corpus.py）：别名链取第一个非空。
String? _apiKeyOf(Map<String, String> env) {
  for (final n in [
    'SILICONFLOW_API_KEY',
    'SILICONFLOW_KEY',
    'EMBEDDING_API_KEY',
    'EMBED_API_KEY',
  ]) {
    final v = env[n];
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

String? _envGet(Map<String, String> fileEnv, String key) {
  final sys = Platform.environment[key];
  if (sys != null && sys.isNotEmpty) return sys;
  final v = fileEnv[key];
  if (v != null && v.isNotEmpty) return v;
  return null;
}

int _countOf(Database db, String table) {
  try {
    return db.select('SELECT count(*) FROM "$table"').first.columnAt(0) as int;
  } catch (_) {
    return -1; // 表不存在
  }
}

Future<void> main(List<String> argv) async {
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => ffi.DynamicLibrary.open(dll));
  }

  // ---- 参数解析 ----
  var inputDir = '../content/ppt_raw';
  String? dbArg;
  var mode = 'offline';
  String? envArg;
  var batch = kDefaultBatch;
  var forceFull = false;
  String? query;
  var k = 5;
  var json = false;
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--db') {
      dbArg = argv[++i];
    } else if (a == '--mode') {
      mode = argv[++i];
    } else if (a == '--env') {
      envArg = argv[++i];
    } else if (a == '--batch') {
      batch = int.parse(argv[++i]);
    } else if (a == '--force-full') {
      forceFull = true;
    } else if (a == '--query') {
      query = argv[++i];
    } else if (a == '--k') {
      k = int.parse(argv[++i]);
    } else if (a == '--json') {
      json = true;
    } else if (!a.startsWith('--')) {
      inputDir = a;
    } else {
      stderr.writeln('未知参数：$a');
      exitCode = 2;
      return;
    }
  }
  if (mode != 'offline' && mode != 'drill' && mode != 'online') {
    stderr.writeln('未知 --mode：$mode（可用 offline|drill|online）');
    exitCode = 2;
    return;
  }
  if (!Directory(inputDir).existsSync()) {
    stderr.writeln('输入目录不存在：$inputDir');
    exitCode = 2;
    return;
  }
  if (json) {
    // --json：stdout 转 UTF-8（Windows 控制台显示乱码是预期噪音；
    // 管道/重定向落盘为干净 UTF-8——禁用 > 的 UTF-16 重定向规则不受影响）
    stdout.encoding = convert.utf8;
  }

  // ---- .env 与嵌入配置（key 只判存在，绝不打印值） ----
  var fileEnv = <String, String>{};
  for (final cand in [
    ?envArg,
    '../automation/server-pipeline/.env',
    '.env',
  ]) {
    if (File(cand).existsSync()) {
      fileEnv = parseEnvFile(cand);
      if (!json) stdout.writeln('env 文件：$cand（${fileEnv.length} 键）');
      break;
    }
  }
  final apiKey = _apiKeyOf({
    ...fileEnv,
    ...Platform.environment,
  });
  if (!json) {
    stdout.writeln('API key：${apiKey == null ? "无" : "有（值不显示）"}');
  }
  final CorpusEmbedConfig embed;
  if (mode == 'online') {
    if (apiKey == null) {
      stderr.writeln('在线模式需要 SILICONFLOW_API_KEY（.env 或环境变量）；'
          '无 key 冒烟请用 --mode offline / --mode drill');
      exitCode = 2;
      return;
    }
    embed = CorpusEmbedConfig.online(
      apiKey,
      model: _envGet(fileEnv, 'EMBEDDING_MODEL') ?? kEmbedModel,
      baseUrl: _envGet(fileEnv, 'EMBEDDING_BASE_URL') ?? kEmbedApiUrl,
      dim: int.tryParse(_envGet(fileEnv, 'EMBED_DIM') ?? '') ?? kEmbedDim,
    );
  } else if (mode == 'drill') {
    embed = const CorpusEmbedConfig.drill();
  } else {
    // offline：无 key → 不写向量，检索词面单路；模型名仍按目标口径写 meta
    embed = CorpusEmbedConfig(
      mode: CorpusEmbedMode.offline,
      model: _envGet(fileEnv, 'EMBEDDING_MODEL') ?? kEmbedModel,
      baseUrl: _envGet(fileEnv, 'EMBEDDING_BASE_URL') ?? kEmbedApiUrl,
      dim: int.tryParse(_envGet(fileEnv, 'EMBED_DIM') ?? '') ?? kEmbedDim,
    );
  }

  // ---- 临时库（绝不污染 input 树） ----
  final dbPath = dbArg ??
      '${Directory.systemTemp.createTempSync('hengya_build_probe_').path}'
      '${Platform.pathSeparator}corpus.db';

  if (!json) {
    stdout.writeln('== 恒牙 · Dart 建库探针 ==');
    stdout.writeln('输入：$inputDir | 库：$dbPath | 模式：${embed.mode.name}'
        ' | 模型：${embed.effectiveModel}（dim=${embed.effectiveDim}）'
        '${forceFull ? ' | force-full' : ''}');
  }

  final t0 = Stopwatch()..start();
  late final (ExtractAllStats, IngestStats?) built;
  try {
    built = await buildCorpus(
      inputPath: inputDir,
      dbPath: dbPath,
      embed: embed,
      batch: batch,
      forceFull: forceFull,
      progress: json
          ? null
          : (m) => stdout.writeln('  $m'),
    );
  } catch (e) {
    stderr.writeln('建库失败：$e');
    exitCode = 2;
    return;
  }
  final (ex, ing) = built;
  final elapsed = t0.elapsedMilliseconds / 1000.0;

  // ---- schema/行数报告 ----
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  Map<String, Object?> report;
  Map<String, Object?>? searchSmoke;
  try {
    final tables = [
      for (final r in db.select(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"))
        '${r.columnAt(0)}',
    ];
    final counts = <String, int>{};
    for (final t in [
      'chunks',
      'vectors',
      'meta',
      'chunk_state',
      'deck_state',
      'chunks_fts',
      kVec0Table,
    ]) {
      counts[t] = _countOf(db, t);
    }
    final meta = <String, String>{};
    for (final r in db.select('SELECT key, value FROM meta')) {
      meta['${r.columnAt(0)}'] = '${r.columnAt(1)}';
    }
    final decks = [
      for (final r in db.select('SELECT subject_id, ppt_id, source, '
          'chunk_count, updated_at FROM deck_state ORDER BY subject_id, ppt_id'))
        {
          'subject': '${r.columnAt(0)}',
          'ppt_id': '${r.columnAt(1)}',
          'source': '${r.columnAt(2)}',
          'chunks': r.columnAt(3),
          'updated_at': '${r.columnAt(4)}',
        },
    ];
    final bySubject = <String, int>{};
    for (final r in db.select('SELECT subject_id, count(*) FROM chunks '
        'GROUP BY subject_id ORDER BY subject_id')) {
      bySubject['${r.columnAt(0)}'] = r.columnAt(1) as int;
    }
    // vec_chunks 镜像抽样：行长（应 = vec0_dim×4）
    var mirrorBlobLen = -1;
    if (counts[kVec0Table]! > 0) {
      final r = db
          .select('SELECT length(v) FROM $kVec0Table LIMIT 1');
      mirrorBlobLen = r.first.columnAt(0) as int;
    }
    final chunksCols = [
      for (final r in db.select('PRAGMA table_info("chunks")'))
        '${r.columnAt(1)}',
    ];

    report = {
      'db': dbPath,
      'input': inputDir,
      'mode': embed.mode.name,
      'model': embed.effectiveModel,
      'dim': embed.effectiveDim,
      'elapsed_s': elapsed,
      'extract': ex.toJson(),
      'ingest': ing?.toJson(),
      'tables': tables,
      'row_counts': counts,
      'chunks_columns': chunksCols,
      'meta': meta,
      'decks': decks,
      'chunks_by_subject': bySubject,
      'vec0_mirror_blob_len': mirrorBlobLen,
    };

    // ---- 离线检索冒烟（词面 + drill 伪向量/词面单路） ----
    if (query != null) {
      final res = await corpusSearch(db, query,
          k: k, offline: true, rerank: false);
      final hits =
          (res['results'] as List).cast<Map<String, Object?>>().toList();
      searchSmoke = {
        'query': query,
        'n_hits': hits.length,
        'notes': res['notes'],
        'top': hits.take(k).toList(),
      };
      if (!json) {
        stdout.writeln('检索冒烟（offline，k=$k）：命中 ${hits.length}');
        for (final h in hits.take(k)) {
          stdout.writeln('  #${h['rank']} [${h['hit_path']}] ${h['subject']} / '
              '${h['deck']} ${h['page_range']} | ${h['title']} | '
              'score=${h['score']} vec=${(h['vec'] as num).toStringAsFixed(3)}');
        }
      }
    }
  } finally {
    db.dispose();
  }

  if (!json) {
    stdout.writeln('-----------------------------------------');
    stdout.writeln('建库完成（${elapsed.toStringAsFixed(1)}s）：'
        'decks=${ex.decksTotal} changed=${ex.changed} '
        'unchanged=${ex.unchanged} removed=${ex.removed}');
    if (ex.skippedBig.isNotEmpty) {
      stdout.writeln('超限跳过：${ex.skippedBig.length} 个');
    }
    if (ex.errors.isNotEmpty) {
      stdout.writeln('抽取失败：${ex.errors.length} 个');
      for (final e in ex.errors.take(10)) {
        stdout.writeln('  - $e');
      }
    }
    stdout.writeln('chunks=${ex.chunks}${ing != null ? ' | rows=${ing.rows} '
        'embedded=${ing.embedded} resumed=${ing.resumed} '
        'pruned_stale=${ing.prunedStale} pruned_absent=${ing.prunedAbsent} '
        'scale=${ing.scale.toStringAsFixed(6)}' : '（ingest 未执行：0 chunks）'}');
    stdout.writeln('行数：');
    final counts = report['row_counts']! as Map<String, int>;
    for (final e in counts.entries) {
      stdout.writeln('  ${e.key.padRight(12)} ${e.value < 0 ? '（缺表）' : e.value}');
    }
    stdout.writeln('chunks 列：${report['chunks_columns']}');
    stdout.writeln('meta：');
    for (final e in (report['meta']! as Map<String, String>).entries) {
      stdout.writeln('  ${e.key} = ${e.value}');
    }
    stdout.writeln('deck_state：');
    for (final d in (report['decks']! as List)) {
      final m = d as Map<String, Object?>;
      stdout.writeln('  ${m['subject']} / ${m['ppt_id']}'
          '（${m['source']}，${m['chunks']} chunks，${m['updated_at']}）');
    }
    stdout.writeln('vec_chunks 镜像：rows=${counts[kVec0Table]}'
        '，BLOB=${report['vec0_mirror_blob_len']}B');
  } else {
    final out = <String, Object?>{
      ...report,
      'search_smoke': ?searchSmoke,
    };
    stdout.writeln(convert.jsonEncode(out));
  }
  // 清理提示（默认临时库不自动删——留检；--db 用户自管）
  if (dbArg == null) {
    stderr.writeln('探针临时库：$dbPath（可随时删除）');
  }
}
