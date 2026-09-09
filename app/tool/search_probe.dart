// 恒牙（hengya）· Phase 4 检索引擎跨引擎对拍探针
// ============================================================================
//
// 用法（cwd=app/；Windows 下自动加载 test/sqlite3.dll，同 test/* 基建）：
//   dart run tool/search_probe.dart <db> <query> [--subject S] [--k N]
//          [--source-type T] [--offline] [--no-fts] [--vec0 on|off]
//          [--fusion linear|rrf] [--weights a,b] [--pretty]
//
// offline：词面单路（真库 meta.embedding_model 与 local-charhash 互斥，
// 向量路自动跳过——与 Python --offline 行为逐字一致）；演练库
// （meta.embedding_model=local-charhash-1024-v1）则全链含向量对拍。
// 在线模式：读 ../automation/server-pipeline/.env 的 SILICONFLOW_API_KEY
// 及 EMBEDDING_*（不打印任何 key 片段）。
//
// 输出：Python search_corpus.py --json 兼容结构（stdout），
// 供跨引擎逐字段对拍（比对脚本见 .snow/tmp/diff_search.py）。
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/services/local/corpus/search_api.dart';
import 'package:hengya/services/local/corpus/search_engine.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

String? _envOf(Map<String, String> env, List<String> names) {
  for (final n in names) {
    final v = env[n];
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

void main(List<String> argv) {
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => ffi.DynamicLibrary.open(dll));
  }
  if (argv.length < 2) {
    stderr.writeln(
        '用法：dart run tool/search_probe.dart <db> <query> [--subject S] '
        '[--k N] [--source-type T] [--offline] [--no-fts] '
        '[--vec0 on|off] [--fusion linear|rrf] [--weights a,b] [--pretty]');
    exitCode = 2;
    return;
  }
  final dbPath = argv[0];
  final query = argv[1];
  String? subject;
  String? sourceType;
  var k = 10;
  var offline = false;
  var noFts = false;
  bool? vec0;
  var fusion = 'linear';
  List<double>? weights;
  var pretty = false;
  for (var i = 2; i < argv.length; i++) {
    switch (argv[i]) {
      case '--subject':
        subject = argv[++i];
      case '--k':
        k = int.parse(argv[++i]);
      case '--source-type':
        sourceType = argv[++i];
      case '--offline':
        offline = true;
      case '--no-fts':
        noFts = true;
      case '--vec0':
        vec0 = argv[++i] == 'on';
      case '--fusion':
        fusion = argv[++i];
      case '--weights':
        weights = argv[++i].split(',').map(double.parse).toList();
      case '--pretty':
        pretty = true;
      default:
        stderr.writeln('未知参数：${argv[i]}');
        exitCode = 2;
        return;
    }
  }
  if (!File(dbPath).existsSync()) {
    stderr.writeln('corpus.db 不存在: $dbPath');
    exitCode = 2;
    return;
  }

  // 在线模式：解析 ../automation/server-pipeline/.env（KEY=VALUE；不打印）
  EmbedQueryFn? embed;
  String? embedModel;
  if (!offline) {
    final envFile = File('../automation/server-pipeline/.env');
    final env = <String, String>{};
    if (envFile.existsSync()) {
      for (final line in envFile.readAsLinesSync()) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        final eq = t.indexOf('=');
        if (eq <= 0) continue;
        env[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
      }
    }
    final key = _envOf(env, [
      'SILICONFLOW_API_KEY',
      'SILICONFLOW_KEY',
      'EMBEDDING_API_KEY',
      'EMBED_API_KEY',
    ]);
    if (key == null || key.isEmpty) {
      stderr.writeln('在线模式需要 SILICONFLOW_API_KEY（.env）；'
          '离线对拍请用 --offline');
      exitCode = 2;
      return;
    }
    final cfg = SiliconFlowConfig(
      apiKey: key,
      embedBaseUrl: env['EMBEDDING_BASE_URL'] ?? kEmbedApiUrl,
      embedModel: env['EMBEDDING_MODEL'] ?? kEmbedModel,
      queryInstruct:
          env.containsKey('EMBED_QUERY_INSTRUCT') && env['EMBED_QUERY_INSTRUCT']!.isEmpty
              ? ''
              : null,
    );
    embed = siliconFlowEmbedder(cfg);
    embedModel = cfg.embedModel;
  }

  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    final res = () async {
      return await corpusSearch(
        db,
        query,
        subject: subject,
        k: k,
        sourceType: sourceType,
        weights: weights,
        offline: offline,
        noFts: noFts,
        fusion: fusion,
        vec0: vec0,
        embed: embed,
        embedModel: embedModel,
        rerank: false, // 对拍口径：rerank off（rerank 抖动不进硬门）
      );
    }();
    res.then((r) {
      const encoder = convert.JsonEncoder.withIndent('  ');
      stdout.writeln(pretty
          ? encoder.convert(r)
          : convert.jsonEncode(r));
    }).catchError((Object e) {
      stderr.writeln('检索失败: $e');
      exitCode = 1;
    });
  } finally {
    // db.dispose 延迟到进程退出（async main 中 finally 会过早关闭）；
    // 进程结束自动释放。
  }
}
