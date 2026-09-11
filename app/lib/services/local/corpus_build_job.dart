// 恒牙（hengya）· 建库流水线 isolate job 封装（P1-3 下游接线公共契约）
// ============================================================================
//
// 「App 内建库接线」节点的公共 API：把 extract_all 建库链（树扫描抽取 →
// ingest 建库 + 可选嵌入）封装为后台 isolate job——App 内可调用、执行不卡
// UI、进度事件实时、结果结构化。CLI 探针（tool/corpus_build_probe.dart）
// 仍是直跑 buildCorpus 的独立入口，--mode 语义与本 job 严格一致。
//
// ── 公共契约（下游按此编码；签名稳定）──
// 入口：
//   runCorpusBuild(CorpusBuildRequest) → Future<IsolateJobHandle<CorpusBuildResult>>
//   - 单飞：corpusBuildJobId（'corpus-build'）运行中重复启动 → StateError
//     （查询面 IsolateRunner.instance.isRunning(corpusBuildJobId)）
//   - 进度：handle.progress（阶段/消息/计数，见下）
//   - 结果：handle.done（完成 = CorpusBuildResult；取消 =
//     IsolateCancelledException；失败/崩溃 = IsolateJobException）
//   - 取消：handle.cancel()——best-effort：抽取按文件、嵌入按批的进度
//     检查点生效；中途取消安全（manifest 增量 + chunk_state 断点续传
//     语义保证重跑收敛）
//
// 进度事件协议（IsolateProgressEvent，按发生顺序送达）：
//   stage='start'   建库开始：message 含 mode/输入路径（**不含 key**）
//   stage='extract' 抽取进度：每文件 1 条（「已抽取：科目 / ppt（N
//                    chunks）」「跳过超限文件…」「抽取失败：…」原样透传）
//   stage='extract' 抽取完成：counts = ExtractAllStats.toJson() 全量
//                    （decks_total/changed/unchanged/removed/chunks/
//                     skipped_big/errors/by_subject）
//   stage='ingest'  入库/嵌入进度：每批 1 条（「嵌入 N/M（scale=…）」
//                    「剪除树外 deck…」「vec0 回填 N 行…」等原样透传）
//   stage='ingest'  入库完成：counts = IngestStats.toJson() 全量
//                    （rows/bad_lines/mode/model/dim/embedded/resumed/
//                     pending/batches/pruned_stale/pruned_absent/vec0…）
//   stage='done'    建库完成：counts={chunks, embedded, elapsed_s}
//   （0 chunks 时 ingest 阶段不发生——start 后直接 done，notes 携带提示）
//
// key 纪律：apiKey 只进 CorpusEmbedConfig，绝不进任何进度/结果/异常文本。
//
// 纯 Dart（不 import Flutter）；worker 内 pdfium/sqlite3 首用自然加载
// （跨 isolate 结论见 isolate_runner.dart 文件头 ①②）。
import 'dart:io';

import 'corpus/extract_all.dart'
    show
        CorpusEmbedConfig,
        CorpusEmbedMode,
        extractAllCorpus,
        ingestCorpus,
        kDefaultBatch,
        openCorpusDb;
import 'corpus/extract_pptx.dart' as pptx;
import 'corpus/outline_docx.dart' as outline;
import 'corpus/progress_db.dart'
    show applyChange, loadProgress, progressEntryOf, saveProgress;
import 'corpus/search_api.dart' show kEmbedApiUrl, kEmbedDim, kEmbedModel;
import 'db.dart';
import 'isolate_runner.dart';

/// 建库 job 的 IsolateRunner 单飞键。
const String corpusBuildJobId = 'corpus-build';

// ------------------------------------------------------------- 请求 ----

/// 建库请求（主 → worker；字段全部可跨 isolate）。
class CorpusBuildRequest {
  const CorpusBuildRequest({
    required this.inputPath,
    required this.corpusDbPath,
    this.mode = CorpusEmbedMode.offline,
    this.apiKey,
    this.model,
    this.baseUrl,
    this.dim,
    this.batch = kDefaultBatch,
this.maxFileMb,
    this.pdfMaxFileMb,
    this.docxMaxFileMb,
    this.forceFull = false,
    this.resetVectors = false,
    this.backfillVectors = false,
  });

  /// 语料树根目录（第一层子目录名 = 科目短码；xxx-textbook / xxx-exam /
  /// exam 命名规则同 Python），或单文件路径（.pptx/.pdf/.docx）。
  final String inputPath;

  /// corpus.db 输出路径；chunks.jsonl / extract_manifest.json / toc/ 落其
  /// 同级目录（与 buildCorpus 默认布局一致）。注意与主库 hengya.db 是
  /// 两个库（corpus.db 由本管线生成；hengya.db 是 App 主库）。
  final String corpusDbPath;

  /// 嵌入模式（同 CLI 探针 --mode 口径）：
  /// - offline：无 key 不写向量（库可建，检索词面单路；后续在线补嵌收敛）
  /// - drill：确定性伪向量（local-charhash-1024-v1），零网络零计费
  /// - online：SiliconFlow /v1/embeddings 真实嵌入（**有真实计费**，
  ///   须提供 [apiKey]；缺 key 抛错）
  final CorpusEmbedMode mode;

  /// 在线模式 API key（来源由调用方决定：App = LocalBackend.aiKeyOf
  ///（AiKeyVault 安全存储缓存）；绝不打印/不进结果）。offline/drill 忽略。
  final String? apiKey;

  /// 嵌入模型覆盖（缺省 [kEmbedModel]；drill 固定 local-charhash-1024-v1）。
  final String? model;

  /// /v1/embeddings 完整端点覆盖（缺省 [kEmbedApiUrl]）。
  final String? baseUrl;

  /// MRL 截断维度覆盖（缺省 [kEmbedDim]）。
  final int? dim;

  /// 嵌入批量大小（缺省 [kDefaultBatch]=20，模力方舟免费档对齐）。
  final int batch;

  /// pptx 大小上限 MB（缺省 defaultMaxFileMb）。
  final int? maxFileMb;

  /// pdf 大小上限 MB（缺省 extract_pdf 侧默认）。
  final int? pdfMaxFileMb;

  /// docx 大小上限 MB（缺省同 pdf 侧默认）。
  final int? docxMaxFileMb;

  /// true → 无视 manifest 增量全量重抽。
final bool forceFull;

  /// 强制向量全量重建（2026-09-11「重建全部向量」按钮）：清空 vectors +
  /// chunk_state 后按当前嵌入配置全量重嵌。语义 = 覆盖层：0-chunks 时
  /// 不再早退，转走 ingestCorpus 的库内自嵌（incoming 树空也可重嵌）。
  final bool resetVectors;

  /// 增量补齐（2026-09-12「补齐缺失向量」按钮）：与 [resetVectors] 同样以
  /// 「库内全量 ∪ jsonl」为嵌入源、0-chunks 不早退，但不清空现有向量——
  /// 断点检查天然跳过已嵌行，只补缺失部分。模型/维度与库内不一致时
  /// ingestCorpus 拒绝（报错走全量重建）。
  final bool backfillVectors;
}

// ------------------------------------------------------------- 结果 ----

/// 建库结果（worker → 主 isolate；字段全部可跨 isolate、可 JSON 落盘）。
///
/// 统计为 extract_all 的 toJson() 形态——键与 Python 同构（extract_all.dart
/// ExtractAllStats/IngestStats 的 toJson 注释即键定义）。
class CorpusBuildResult {
  const CorpusBuildResult({
    required this.extract,
    required this.ingest,
    required this.notes,
    required this.elapsedS,
    required this.inputPath,
    required this.corpusDbPath,
  });

  /// 抽取统计（ExtractAllStats.toJson()）。恒非 null。
  final Map<String, Object?>? extract;

  /// 建库统计（IngestStats.toJson()）；抽取 0 chunks 时为 null（未建库）。
  final Map<String, Object?>? ingest;

  /// 人读提示（0 chunks 警告等；不含任何 key 片段）。
  final List<String> notes;

  /// 总耗时（秒）。
  final double elapsedS;

  /// 回显输入路径（排查用）。
  final String inputPath;

  /// 回显 corpus.db 路径（排查用）。
  final String corpusDbPath;

  /// 抽取出的 chunk 总数（extract['chunks']；快捷读取）。
  int get chunks => (extract?['chunks'] as num?)?.toInt() ?? 0;

  /// 实际嵌入条数（ingest['embedded']；offline 恒 0；快捷读取）。
  int get embedded => (ingest?['embedded'] as num?)?.toInt() ?? 0;
}

// --------------------------------------------------------------- 入口 ----

/// App 内建库公共入口：spawn 后台 isolate 执行「抽取 → ingest（可选嵌入）」。
///
/// 示例（App 建库接线节点）：
/// ```dart
/// if (IsolateRunner.instance.isRunning(corpusBuildJobId)) {
///   // 已在运行——UI 提示后返回
/// }
/// final handle = await runCorpusBuild(CorpusBuildRequest(
///   inputPath: '$dataDir/corpus/incoming',   // 用户放入语料的目录
///   corpusDbPath: '$dataDir/corpus/corpus.db',
///   mode: CorpusEmbedMode.online,            // 真实嵌入（有计费）
///   apiKey: LocalBackend.instance.aiKeyOf('embedding'), // 安全存储缓存
/// ));
/// handle.progress.listen((e) => log('${e.stage}: ${e.message}'));
/// try {
///   final result = await handle.done;
///   log('建库完成：${result.chunks} chunks，嵌入 ${result.embedded}');
/// } on IsolateJobException catch (e) {
///   log('建库失败：$e');                       // 重跑即断点续传
/// }
/// ```
///
/// - 单飞：[corpusBuildJobId] 运行中 → StateError。
/// - offline/drill 零网络；online 才有网络与计费。
/// - 取消：`handle.cancel()`（best-effort，检查点见文件头协议）。
Future<IsolateJobHandle<CorpusBuildResult>> runCorpusBuild(
  CorpusBuildRequest request,
) {
  return IsolateRunner.instance.start<CorpusBuildResult>(
    jobId: corpusBuildJobId,
    workerEntry: corpusBuildWorkerEntry,
    args: request,
  );
}

// ------------------------------------------------------------- worker ----

/// 建库 worker 入口（Isolate.spawn 顶层函数；[runCorpusBuild] 装配）。
///
/// 两段式调用 extractAllCorpus + ingestCorpus（与 buildCorpus 编排完全
/// 同参：chunks.jsonl/manifest 落库同级、source='tree'、pruneAbsent=true、
/// 大小上限默认同款），只为给进度事件打上 extract/ingest 阶段标签并在
/// 两段之间设取消检查点。
void corpusBuildWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    final req = boot.args! as CorpusBuildRequest;
    final t0 = Stopwatch()..start();
    final notes = <String>[];

    // 嵌入配置组装（同探针口径；online 缺 key 由 ingestCorpus 抛错）
    final embed = CorpusEmbedConfig(
      mode: req.mode,
      apiKey: req.apiKey,
      model: req.model ?? kEmbedModel,
      baseUrl: req.baseUrl ?? kEmbedApiUrl,
      dim: req.dim ?? kEmbedDim,
    );

    // 进度转发即取消检查点（best-effort：每条进度回调一次）
    void relay(String stage, String message) {
      ctx.checkCancelled();
      ctx.emit(IsolateProgressEvent(stage: stage, message: message));
    }

    ctx.emit(
      IsolateProgressEvent(
        stage: 'start',
        message: '建库开始：mode=${req.mode.name}，输入 ${req.inputPath}',
      ),
    );

    // 路径布局与 buildCorpus 一致（chunks.jsonl/manifest 落库同级）
    final dbFile = File(req.corpusDbPath);
    final corpusDir = dbFile.parent.path.isEmpty ? '.' : dbFile.parent.path;
    final chunksJsonlPath = '$corpusDir/chunks.jsonl';
    final manifestPath = '$corpusDir/extract_manifest.json';

    ctx.checkCancelled();
    final ex = extractAllCorpus(
      req.inputPath,
      chunksJsonlPath,
      manifestPath: manifestPath,
      maxFileMb: req.maxFileMb ?? pptx.defaultMaxFileMb,
      pdfMaxFileMb: req.pdfMaxFileMb,
      docxMaxFileMb: req.docxMaxFileMb,
      forceFull: req.forceFull,
      progress: (m) => relay('extract', m),
    );
    ctx.emit(
      IsolateProgressEvent(
        stage: 'extract',
        message:
            '抽取完成：${ex.chunks} chunks'
            '（changed=${ex.changed} unchanged=${ex.unchanged} '
            'removed=${ex.removed}）',
        counts: ex.toJson(),
      ),
    );

    // 节点④：-outline 大纲树文件 → outline_entries（不走常规切块/嵌入；
    // F 证据隔离——正文绝不进语料块）。仅大纲入库（0 chunks）不算失败。
    var outlineEntries = 0;
    if (ex.outlineFiles.isNotEmpty) {
      ctx.checkCancelled();
      final odb = openCorpusDb(req.corpusDbPath);
      try {
        final ostats = outline.ingestOutlineFiles(
          odb,
          ex.outlineFiles,
          progress: (m) => relay('extract', m),
        );
        outlineEntries = ostats.entries;
        notes.add('大纲入库：${ostats.entries} 条（${ostats.entriesByLevel}）');
        ctx.emit(
          IsolateProgressEvent(
            stage: 'extract',
            message:
                '大纲入库完成：${ostats.entries} 条'
                '（${ostats.entriesByLevel}）',
            counts: <String, Object?>{'outline': ostats.toJson()},
          ),
        );
      } finally {
        odb.dispose();
      }
      // A5 拍板（D 项）：大纲落库后自动确保 med 占位科目「医学综合」存在
      // （derm 同款机制：subjects 一行 + progress.json 无罗盘占位——真机
      // 用户上传大纲建库后自动出现，不参与复习提示；本批绝不为 med 建
      // 语料树/拆卡）。失败不阻断建库（notes 如实记录）。
      if (outlineEntries > 0) {
        try {
          await ensureMedSubjectPlaceholder(req.corpusDbPath);
          notes.add('已确保 med 占位科目（医学综合）存在');
        } catch (e) {
          notes.add('med 占位科目确保失败：$e');
        }
      }
    }

// 0 chunks：非 resetVectors/backfillVectors 直接 return（与 buildCorpus
    // 同款告警路径；仅大纲入库除外）。resetVectors=true → 不早退：转
    // ingestCorpus（其库内自嵌从 chunks 表读全部行重新嵌入——incoming 空树
    // 也重嵌）。backfillVectors=true → 同不早退（库内自嵌 + 断点检查只补
    // 缺失向量——incoming 空树也可补齐）。
    if (ex.chunks == 0 && !req.resetVectors && !req.backfillVectors) {
      if (ex.outlineFiles.isEmpty) {
        notes.add(
          '抽取结果 0 chunks——检查 ${req.inputPath} 下是否放了 '
          '.pptx/.pdf/.docx（第一层子目录=科目短码）',
        );
      } else {
        notes.add(
          '仅大纲入库（0 chunks）：outline_entries $outlineEntries 条，'
          '未做语料块入库',
        );
      }
      final elapsed = t0.elapsedMilliseconds / 1000.0;
      ctx.emit(
        IsolateProgressEvent(
          stage: 'done',
          message:
              '建库结束（0 chunks，'
              '${ex.outlineFiles.isEmpty ? '未入库' : '仅大纲入库 $outlineEntries 条'}）',
          counts: <String, Object?>{
            'chunks': 0,
            'outline_entries': outlineEntries,
            'elapsed_s': elapsed,
          },
        ),
      );
      return CorpusBuildResult(
        extract: ex.toJson(),
        ingest: null,
        notes: notes,
        elapsedS: elapsed,
        inputPath: req.inputPath,
        corpusDbPath: req.corpusDbPath,
      );
    }

    ctx.checkCancelled();
final ing = await ingestCorpus(
      req.corpusDbPath,
      chunksJsonlPath,
      embed: embed,
      batchSize: req.batch,
      source: 'tree',
      pruneAbsent: true,
      resetVectors: req.resetVectors,
      backfillVectors: req.backfillVectors,
      preserveDeckSource: req.resetVectors || req.backfillVectors,
      progress: (m) => relay('ingest', m),
    );
    ctx.emit(
      IsolateProgressEvent(
        stage: 'ingest',
        message:
            '入库完成：rows=${ing.rows} embedded=${ing.embedded} '
            'resumed=${ing.resumed}',
        counts: ing.toJson(),
      ),
    );

    final elapsed = t0.elapsedMilliseconds / 1000.0;
    ctx.emit(
      IsolateProgressEvent(
        stage: 'done',
        message:
            '建库完成：${ex.chunks} chunks，嵌入 ${ing.embedded}'
            '（${elapsed.toStringAsFixed(1)}s）',
        counts: <String, Object?>{
          'chunks': ex.chunks,
          'embedded': ing.embedded,
          'elapsed_s': elapsed,
        },
      ),
    );
    return CorpusBuildResult(
      extract: ex.toJson(),
      ingest: ing.toJson(),
      notes: notes,
      elapsedS: elapsed,
      inputPath: req.inputPath,
      corpusDbPath: req.corpusDbPath,
    );
  });
}

// ------------------------------------------------- med 占位科目确保 ----

/// 大纲落库后自动确保 med 占位科目「医学综合」存在（A5/D 拍板；⑨ 总量
/// 核验按此口径）：
///
/// 1. **hengya.db subjects 表**补一行 (id='med', name='医学综合',
///    is_exam_subject=1, sort_order=末位)——幂等（[Db.ensureSubjectRow]，
///    已存在不动），插入成功 bumpDataVersion；
/// 2. **progress.json** 补无罗盘占位条目——derm 同款机制
///    （progress_db.applyChange：textbook=null、learned_through=0、仅接受
///    0；source='outline'、history 记「大纲入库自动创建占位科目」）；
///    条目已存在不动。
///
/// 路径布局假设（App 内建库唯一调用方）：corpusDbPath =
/// `<dataDir>/corpus/corpus.db`（LocalBackend.init 同源）→ hengya.db 在
/// `<dataDir>/`、progress.json 在 `<corpusDir>/`。无罗盘 → 复习提示/罗盘
/// 汇总天然排除（progress_page/home_page 既有多数派口径）；本批绝不为
/// med 建语料树/拆卡。
Future<void> ensureMedSubjectPlaceholder(String corpusDbPath) async {
  final corpusDir = File(corpusDbPath).parent.path;
  final dataDir = Directory(corpusDir).parent.path;
  // ① subjects 行（幂等）
  final db = await Db.open('$dataDir/hengya.db');
  try {
    if (db.ensureSubjectRow(
      outline.kMedSubjectCode,
      outline.kMedSubjectName,
      isExamSubject: true,
    )) {
      db.bumpDataVersion();
    }
  } finally {
    db.close();
  }
  // ② progress.json 无罗盘占位（幂等：条目已存在不动）
  final progressPath = '$corpusDir/progress.json';
  final data = loadProgress(progressPath);
  if (progressEntryOf(data, outline.kMedSubjectCode) == null) {
    final r = applyChange(
      data,
      outline.kMedSubjectCode,
      0,
      source: 'outline',
      evidence: '',
      allowCreate: true,
      createNote: '大纲入库自动创建占位科目（医学综合，无罗盘不参与复习提示）',
    );
    if (r.mutated) {
      saveProgress(progressPath, data);
    }
  }
}
