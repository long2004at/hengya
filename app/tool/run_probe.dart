// 恒牙（hengya）· Phase 4 run_engine 真料拆卡探针（run_probe.dart）
// ============================================================================
//
// 用法（cwd=app/；Windows 自动加载 test/sqlite3.dll）：
//   dart run tool/run_probe.dart <corpus.db> --keyword 龋病四联因素 --subject endo
//          [--keyword … --subject …]*   关键词模式：拆卡出 JSON（不 import）
//          [--import <dataDir>]         真实模式：Db 直连 <dataDir>/hengya.db 拉
//                                        收件箱 pending → 拆卡 → 幂等 import →
//                                        consume（study-log 条目计数并跳过——推进
//                                        链待 progress_db 刀）
//          [--dry-run]                  与 --import 连用：只出卡不 import/consume
//          [--offline] [--floor 0.30] [--limit N] [--pretty]
//
// 配置：../automation/server-pipeline/.env —— SILICONFLOW_API_KEY（向量嵌入）+
// LLM_BASE_URL / LLM_API_KEY / LLM_MODEL（拆卡 LLM）。绝不打印任何 key 片段。
// prompts：优先读 ../automation/prompts/ 两模板（缺失回退 assets/prompts/，
// 再缺用内置兜底——loadPrompts 契约）。
//
// 输出：{meta, keywords[], studyLogSkipped, llm{calls,promptTokens,…}} JSON
// （stdout；--pretty 缩进）。供真料全流程检测人工审卡 + 机器对账。
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/services/local/corpus/run_engine.dart';
import 'package:hengya/services/local/corpus/run_llm.dart';
import 'package:hengya/services/local/corpus/search_api.dart';
import 'package:hengya/services/local/corpus/search_engine.dart';
import 'package:hengya/services/local/db.dart';
import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

Map<String, String> _loadEnv() {
  final env = <String, String>{};
  final f = File('../automation/server-pipeline/.env');
  if (!f.existsSync()) {
    return env;
  }
  for (final line in f.readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) {
      continue;
    }
    final eq = t.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    env[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
  }
  return env;
}

String? _readText(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}

/// Db 直连 → 引擎 CardPort 适配（CLI 真实模式；纯 Dart 无 flutter 依赖）。
class _DbPort implements CardPort {
  _DbPort(this.db);

  final Db db;

  @override
  Future<({bool ok, int inserted, int skipped, String? error})> importCards(
      List<Map<String, Object?>> cards) async {
    var inserted = 0;
    var skipped = 0;
    final errors = <String>[];
    for (final c0 in cards) {
      final id = (c0['id'] ?? '?').toString();
      try {
        final card = FlashCard.fromJson(Map<String, dynamic>.from(c0));
        if (!db.subjectExists(card.subjectId)) {
          // 科目缺失属暂时性故障（用户可能尚未建科目）→ 计错误，
          // 整批 ok=false → 引擎判 import_failed 不 consume，留补跑。
          errors.add('$id: 科目 ${card.subjectId} 不存在');
          continue;
        }
        if (db.importCard(card)) {
          inserted++;
        } else {
          skipped++; // 幂等：已存在的 id 跳过
        }
      } catch (e) {
        errors.add('$id: $e');
      }
    }
    if (inserted > 0) {
      db.bumpDataVersion();
    }
    return (
      ok: errors.isEmpty,
      inserted: inserted,
      skipped: skipped,
      error: errors.isEmpty ? null : errors.take(5).join('; '),
    );
  }

  @override
  Future<({bool ok, String? error})> consumeInbox(List<Object?> ids) async {
    final idInts = ids.whereType<int>().toList();
    if (idInts.isEmpty) {
      return (ok: true, error: null); // CLI 注入关键词无 inboxId → 无需消费
    }
    try {
      db.consumeKeywords(idInts);
      return (ok: true, error: null);
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }

  @override
  Future<({bool ok, String? error})> reworkDone(int queueId,
      {required String front,
      required String back,
      required String anchor}) async {
    try {
      final r =
          db.reworkDone(queueId, front: front, back: back, anchor: anchor);
      return r == null
          ? (ok: true, error: null)
          : (ok: false, error: r); // 'not_found' / 'stale'
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }
}

Future<void> main(List<String> argv) async {
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => ffi.DynamicLibrary.open(dll));
  }
  if (argv.isEmpty) {
    stderr.writeln('用法：dart run tool/run_probe.dart <corpus.db> '
        '--keyword <kw> --subject <sid> [--import <dataDir>] [--dry-run] '
        '[--offline] [--floor 0.30] [--limit N] [--pretty]');
    exitCode = 2;
    return;
  }
  final dbPath = argv[0];
  final kwArgs = <(String, String)>[];
  String? importDir;
  var dryRun = false;
  var offline = false;
  var floor = kLowScoreFloor;
  int? limit;
  var pretty = false;
  for (var i = 1; i < argv.length; i++) {
    switch (argv[i]) {
      case '--keyword':
        final k = argv[++i];
        if (i + 1 < argv.length && argv[i + 1] == '--subject') {
          i += 1;
          kwArgs.add((k, argv[++i]));
        } else {
          kwArgs.add((k, ''));
        }
      case '--subject':
        stderr.writeln('--subject 必须跟在 --keyword 之后');
        exitCode = 2;
        return;
      case '--import':
        importDir = argv[++i];
      case '--dry-run':
        dryRun = true;
      case '--offline':
        offline = true;
      case '--floor':
        floor = double.parse(argv[++i]);
      case '--limit':
        limit = int.parse(argv[++i]);
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

  final env = _loadEnv();
  // 向量嵌入（在线）：与 search_probe 同款 .env 消费，不打印 key。
  EmbedQueryFn? embed;
  String? embedModel;
  if (!offline) {
    final key = env['SILICONFLOW_API_KEY'] ?? env['EMBEDDING_API_KEY'] ?? '';
    if (key.isNotEmpty) {
      final cfg = SiliconFlowConfig(
        apiKey: key,
        embedBaseUrl: env['EMBEDDING_BASE_URL'] ?? kEmbedApiUrl,
        embedModel: env['EMBEDDING_MODEL'] ?? kEmbedModel,
      );
      embed = siliconFlowEmbedder(cfg);
      embedModel = cfg.embedModel;
    } else {
      stderr.writeln('提示：无 SILICONFLOW_API_KEY → 向量路禁用（词面单路）');
    }
  }
  // 拆卡 LLM：LLM_BASE_URL / LLM_API_KEY / LLM_MODEL（缺 → 关键词按 failed 处理）。
  final account = LlmAccount();
  final llmCfg = LlmConfig(
    baseUrl: env['LLM_BASE_URL'] ?? '',
    apiKey: env['LLM_API_KEY'] ?? '',
    model: env['LLM_MODEL'] ?? '',
  );
  final llmChat = llmChatFn(llmCfg, account);
  if (!llmCfg.configured) {
    stderr.writeln('提示：LLM 未配置（.env 需 LLM_BASE_URL/LLM_API_KEY/LLM_MODEL）'
        ' → 全部关键词将按 failed 处理（契约 9：不 consume）');
  }

  // 提示词模板：仓库源优先 → assets 拷贝 → 内置兜底。
  final (prompts, promptNotes) = loadPrompts([
    (
      name: '主跑-22-55-server.md',
      text: _readText('../automation/prompts/主跑-22-55-server.md') ??
          _readText('assets/prompts/主跑-22-55-server.md'),
    ),
    (
      name: '周度扫题-周日-server.md',
      text: _readText('../automation/prompts/周度扫题-周日-server.md') ??
          _readText('assets/prompts/周度扫题-周日-server.md'),
    ),
  ]);
  account.notes.addAll(promptNotes);

  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  Future<Map<String, Object?>> runSearch(String query,
      {String? subject, String? sourceType, int? k}) async {
    try {
      return await corpusSearch(
        db,
        query,
        subject: subject,
        sourceType: sourceType,
        k: k ?? kSearchK,
        weights: kSearchWeightsDefault,
        offline: offline,
        embed: embed,
        embedModel: embedModel,
      );
    } catch (e) {
      throw SearchException('$e');
    }
  }

  // 关键词来源：--import 真实模式拉收件箱；否则 CLI 注入。
  final opts = RunOptions(dryRun: dryRun, floor: floor, limit: limit);
  final kwItems = <Map<String, Object?>>[];
  var studyLogSkipped = 0;
  final subjectNames = <String, String>{};
  final progressSubjects = <String, Map<String, Object?>>{};
  final legalSubjects = <Map<String, Object?>>[];
  _DbPort? port;
  if (importDir != null) {
    final db = await Db.open('$importDir/hengya.db');
    final (kwItems_, slItems) = splitPendingBySource(db.inboxPending());
    kwItems.addAll(kwItems_);
    studyLogSkipped = slItems.length; // 推进链待 progress_db 刀：计数并跳过
    for (final s0 in db.subjectRows()) {
      final sid = (s0['id'] ?? '').toString();
      final name = (s0['name'] ?? sid).toString();
      subjectNames[sid] = name;
      legalSubjects.add({'id': sid, 'name': name});
    }
    // progress.json 直读：原始 subjects Map（罗盘函数读 learned_through/chapters）。
    // 注：不可走 /api/v1/progress 视图——那是 List 结构且字段已变形，永取不到。
    final progFile = File('$importDir/corpus/progress.json');
    if (progFile.existsSync()) {
      try {
        final prog = convert.jsonDecode(progFile.readAsStringSync());
        final subs = prog is Map ? prog['subjects'] : null;
        if (subs is Map) {
          subs.forEach((k, v) {
            if (v is Map) {
              progressSubjects[k.toString()] = Map<String, Object?>.from(v);
            }
          });
        }
      } catch (_) {
        // progress.json 损坏 → L2 用科目名（罗盘链属后续刀次，不阻断）
      }
    }
    port = _DbPort(db);
  } else {
    for (final (k, s) in kwArgs) {
      kwItems.add({'id': null, 'subjectId': s, 'keyword': k, 'note': ''});
      final sid = s.isEmpty ? '' : s;
      if (sid.isNotEmpty && !subjectNames.containsKey(sid)) {
        subjectNames[sid] = sid;
      }
    }
    legalSubjects.addAll(
        subjectNames.entries.map((e) => {'id': e.key, 'name': e.value}));
  }
  if (kwItems.isEmpty) {
    stderr.writeln('无待拆关键词（--keyword 或 --import 收件箱为空）');
    exitCode = 2;
    return;
  }
  var applied = kwItems;
  if (limit != null) {
    applied = applied.take(limit).toList();
  }

  final results = <Map<String, Object?>>[];
  for (final kw in applied) {
    final sid = (kw['subjectId'] ?? '').toString();
    final res = await splitKeyword(
      runSearch: runSearch,
      llmChat: llmChat,
      prompts: prompts,
      kw: kw,
      subjectName: subjectNames[sid] ?? sid,
      progressEntry: progressSubjects[sid],
      legalSubjects: legalSubjects,
      opts: opts,
    );
    if (port != null) {
      await importKeywordCards(port, res, opts);
    }
    results.add(res);
  }

  final out = <String, Object?>{
    'meta': {
      'corpusDb': dbPath,
      'offline': offline,
      'floor': floor,
      'dryRun': dryRun,
      'importDir': importDir,
      'llmModel': llmCfg.model,
      'keywords': applied.length,
      'notes': [
        if (studyLogSkipped > 0)
          'study-log 条目 $studyLogSkipped 条未处理（罗盘推进链待 progress_db 移植刀）',
      ],
    },
    'keywords': results,
    'llm': account.toJson(),
  };
  const encoder = convert.JsonEncoder.withIndent('  ');
  stdout.writeln(
      pretty ? encoder.convert(out) : convert.jsonEncode(out));
}
