// 恒牙（hengya）· Phase 4 App 拆卡流水线总编排（pipeline_runner.dart）
// ============================================================================
//
// Python 参考基线（只读，语义对齐，逐段注明行号，2026-09-06 读取态）：
//   - automation/server-pipeline/run.py cmd_main_catchup L1590-1752（六步总编排：
//     收件箱拉取 → split_pending_by_source 分流 L1649 → compass_locate L1661 →
//     学习记录推进 L1667-1685 → 逐关键词 split_keyword L1691 →
//     import_keyword_cards L1700 → 学习记录 consume L1709-1730 →
//     process_rework L1732）
//   - run.py _assemble_result L1791-1905（counts 结构 = report.py 消费口径）
//   - run.py cmd_weekly L1908-2057（周扫装配：chapters/legalSubjects）
//   - force-check.sh（.force_run 标志消费：rc==0 才删标志，失败留待重试）
//
// 本刀范围（Phase 4 收口）：
//   - [runCatchup] 六步总编排 + [runWeeklyScan] 周扫装配；
//   - [PipelineDeps] 注入束：run_engine 三 seam（RunSearchFn / LlmChatFn /
//     CardPort）的 App 实装装配与测试 fake 装配共用，编排零全局状态；
//   - [LocalDbPort]：CardPort 的 db 直连实装（tool/run_probe.dart _DbPort
//     模式：subjectExists 守卫 + importCard 幂等 + bumpDataVersion +
//     consumeKeywords；reworkDone 后 markAiNoteSeen 与 /rework/<id>/done
//     路由同语义，契约 3）；
//   - [PipelineRunner]：.force_run 标志消费（单飞；≈force-check.sh）、
//     last_run.json 存档（契约 12 的端上单文件形态：每次覆盖，手机磁盘纪律）；
//   - 触发链：LocalBackend /pipeline/trigger 落标志 + pipelineKick 回调
//     （main() 装配 PipelineRunner.consumeForceRun；未装配只落标志——
//     与服务端「标志 + cron 消费」同构，测试注入 fake kick 断言契约）。
//
// P1-3（流水线 Isolate 化）：六步编排整体 spawn 到后台 isolate（基建 =
// isolate_runner.dart）。对外契约不变——consumeForceRun / pipelineKick /
// .force_run 语义 / runOnceOverride 注入缝原样；主 isolate 只收进度事件
// （PipelineRunner.progress 转发）与结果。worker 内自开 hengya.db 连接
// 完成全部写副作用（Db.open 每连接重放 WAL/foreign_keys PRAGMA；写侧
// SQLITE_BUSY 短退避重试，见 LocalDbPort._busyRetry——双连接并发写实测
// 见 isolate_runner.dart 文件头 ①）；提示词模板由主 isolate rootBundle
// 预读随请求下发（平台通道仅主 isolate 可用，文件头 ③）。
//
// 嵌入互斥校验命脉（已知坑，探针已示范）：在线时 RunSearchFn 必须传**真实
// embedModel**（settings embedding.model）——corpusSearch 以此对库内
// meta.embedding_model 做空间互斥，占位值会让向量路静默跳过。无 key →
// embed=null 词面单路（offline 无 key 路不炸）。绝不打印任何 key 片段。
//
// #12/#13（2026-09-07，并发池与进度事件）：
//   - ⑤ 关键词循环由串行改为**有界并发池**（上限 [kKeywordConcurrency]=3，
//     实际池大小 = min(3, N)；「pool 个 worker 从共享游标领号」结构，见
//     [_CatchupKwQueue.takeNext]）。拆卡任务本身零 hengya.db 写（检索只读
//     corpus.db + LLM HTTP + progressEntry 只读视图）——import/consume/
//     rework 全部写副作用仍在其后的**串行段**，db 写路径无新增并发面；跨
//     连接写竞争既有 WAL + LocalDbPort._busyRetry 兜底不变（db 写安全
//     结论：无需加锁/队列——读多写少，勿过度设计）。单关键词失败隔离
//     （#7③ 契约 9 不 consume 留补跑）语义原样保留在池 worker 循环体内；
//     kwResults 按 kwPending 序号占位回填，结果顺序与串行基线一致。
//   - [PipelineDeps.onProgress] 进度事件缝（#13）：runCatchup 以关键词
//     粒度发事件（start / kw_start / kw_done / kw_import / phase），每个
//     事件携带**全量队列快照**（running/waiting/done/failed/rework 的计数
//     与条目）+ ts + 触发来源，逐事件自洽——UI 订阅后取最新一帧即可渲染
//     完整队列。触发来源：consumeForceRun({trigger}) →
//     [PipelineCatchupRequest.trigger] 透传（manual=手动「立即触发」缺省 /
//     startup=启动消费遗留标志 / scheduled=定时 22:55 预留——服务端
//     assets/prompts/主跑-22-55-server.md cron 的 App 侧同义位）。worker
//     侧转发为 IsolateProgressEvent(stage:'catchup', counts=事件 Map)；
//     last_run.json 扩展 meta.{trigger, concurrency, startedAt} + 顶层
//     queue 块（per-关键词统计）；[PipelineRunner.lastProgress] 缓存最近
//     事件供中途订阅者取当前快照（broadcast 流无监听期间事件即弃，终态
//     由 last_run.json 兜底）。
//
// 与 Python 的行为差异（边界场景，写明不放宽）：
//   - 契约 1 health：端上直连 Db（local-first），无服务器探测步——steps.health
//     恒 ok（Python /health 探测是服务器拓扑的产物）；
//   - compassAdvances 计数：compass 行按「到达推进步（row 含 hit）」计（≈
//     run.py L1108 的无条件口径，未变/倒退同计）+ studyLog advancedCount
//     （≈L1266 的 rc==0 口径），两条链各自对齐原实现；
//   - 推进后不重新 progress_show 刷新快照（progress_db 刀交接：Dart 内存
//     即最新，Python 因 CLI 子进程写文件才需刷新）；
//   - 周扫 legalSubjects 不并检索命中科目（Dart runWeekly 的检索环在引擎
//     内部，调用方无从预知命中科目；引擎对非法科目已有候选所属章回退兜底）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/sqlite3.dart'
    show Database, OpenMode, SqliteException, sqlite3;

import 'corpus/extract_all.dart' show atomicWriteText, nowIso;
import 'corpus/exam_topics.dart' show kExamTopics;
import 'corpus/outline_docx.dart'
    show kMaxOutlineTagsPerCard, loadZhiyeSubtopicIndex, outlineTagsFor;
import 'corpus/progress_db.dart'
    show
        compassLocate,
        initFromTocSidecar,
        legalSubjects,
        loadProgress,
        progressEntryOf,
        saveProgress,
        studyLogAdvance,
        subjectDisplayName,
        tocSidecarSubjects,
        todayIso,
        weeklyChapters;
import 'corpus/run_engine.dart'
    show
        CardPort,
        PromptFile,
        RunOptions,
        RunSearchFn,
        SearchException,
        importKeywordCards,
        kSearchK,
        kSearchWeightsDefault,
        loadPrompts,
        normalizeStudyLogRefs,
        nextChapterTitle,
        processRework,
        runWeekly,
        splitKeyword,
        splitPendingBySource;
import 'corpus/run_llm.dart'
    show
        LlmAccount,
        LlmChatFn,
        LlmConfig,
        LlmFailoverEvent,
        failoverLlmChatFn;
import 'corpus/search_api.dart'
    show
        SiliconFlowConfig,
        kRerankModelDefault,
        normalizeEmbedEndpoint,
        normalizeRerankEndpoint,
        siliconFlowEmbedder;
import 'corpus/search_engine.dart' show EmbedQueryFn, corpusSearch;
import 'db.dart';
import 'isolate_runner.dart';
import 'local_backend.dart';

// ------------------------------------------------- #12/#13 常量契约 ----

/// #12：拆卡关键词并发池上限（用户拍板 = 3）。[runCatchup] 以此为缺省值；
/// 实际池大小 = min(上限, 待处理数)，空队列 = 0——绝不开无上限并发。
const int kKeywordConcurrency = 3;

/// #13：流水线触发来源（progress 事件 counts.trigger / last_run.json
/// meta.trigger 同名同值；UI 可直接按值分色/文案）。
///
/// - manual：用户点「立即触发」（/pipeline/trigger 落 .force_run 标志 +
///   pipelineKick 后台消费）——缺省值。
/// - startup：App 启动消费上次遗留 .force_run 标志（失败重试/跨会话排队，
///   ≈force-check.sh cron 语义）。
/// - scheduled：定时 22:55 周期触发（assets/prompts/主跑-22-55-server.md
///   服务端 cron 的 App 侧同义位；App 内调度器接入时传入，本节点预留）。
const String kPipelineTriggerManual = 'manual';
const String kPipelineTriggerStartup = 'startup';
const String kPipelineTriggerScheduled = 'scheduled';

// ------------------------------------------------------------- 注入束 ----

/// 六步总编排注入束（App 实装与测试 fake 各装配各的）。
class PipelineDeps {
  PipelineDeps({
    required this.db,
    required this.runSearch,
    required this.llmChat,
    required this.prompts,
    required this.progressData,
    this.progressPath,
    this.tocDir,
    CardPort? port,
    this.account,
    this.onProgress,
    this.outlineTagger,
  }) : port = port ?? LocalDbPort(db);

  /// hengya.db 直连（收件箱/科目/回炉队列读 + import/consume 写）。
  final Db db;

  /// 语料检索 seam（App 装配 [assembleRunSearch]；测试注入脚本化 fake）。
  final RunSearchFn runSearch;

  /// LLM seam（App 装配 llmChatFn(LlmConfig, LlmAccount)；未配置时每次
  /// 调用抛 LlmException——引擎按 failed 处理，契约 9 不 consume）。
  final LlmChatFn llmChat;

  /// 提示词模板（App 装配 [loadPromptsAsset]；测试传 const {} 用内置兜底）。
  final Map<String, String> prompts;

  /// progress.json 内存态（原始 subjects Map——罗盘函数只吃原始结构，
  /// 勿传任何 List 视图；推进直接改此 Map）。
  final Map<String, Object?> progressData;

  /// 非空 → 推进链有变更时 saveProgress 落盘；null → 不落盘（测试内存态）。
  final String? progressPath;

  /// #16 罗盘懒初始化 toc 目录（双保险 b，`<corpusDir>/toc`——writeTocSidecar
  /// 落点）：非空 → runCatchup 开跑时对「进度库缺条目且 sidecar 在」的科目
  /// 先 initFromTocSidecar 再进推进链（幂等：只补缺、不刷新已有条目——
  /// 刷新归建库收尾钩子；dry-run 跳过，守住零落盘口径）。null → 跳过
  /// （测试内存态/无语料环境）。覆盖既有语料：装新版后首次触发拆卡/
  /// 启动补跑即自动生成罗盘，进度页「语料入库后自动生成」承诺兑现。
  final String? tocDir;

  /// 卡片入库端口（默认 [LocalDbPort]；测试可注入 fake）。
  final CardPort? port;

  /// LLM 用量账本（App 实装传入；报告 counts.llm 消费；fake 链可为 null）。
  final LlmAccount? account;

  /// #13：进度事件出口（可空——worker 转发 ctx.emit / 测试收集器；null =
  /// 静默不发）。事件为普通 Map（全部字段可跨 isolate），契约（worker 侧
  /// 即 IsolateProgressEvent.counts，统计页 UI 消费面）：
  ///
  /// {type: start|kw_start|kw_done|kw_import|phase, ts: ISO,
  ///  trigger: manual|startup|scheduled, phase?: 'import'|'rework',
  ///  seq?: int, item?: {seq, inboxId, keyword, subjectId},
  ///  summary?: {status, cards?, pptHit?, elapsedMs?, error?, inserted?, skipped?, consumed?},
  ///  message: 人读文案, queue: 全量队列快照——见 [_CatchupKwQueue.snapshot]}
  ///
  /// 每事件自带快照（逐事件自洽）：订阅后取最新一帧即可渲染完整队列。
  final void Function(Map<String, Object?> event)? onProgress;

  /// 节点④：大纲细目打标器（E 项拍板）——null = 无大纲数据不打标（旧库/
  /// 未上传大纲）。App 实装 = corpus.db outline_entries 载入执业树索引
  /// （[_runCatchupInWorker] 装配，corpus.db 缺表/无数据自动降级 null）；
  /// 测试注入 fake。签名：(subjectId, keyword, subtopics) → 大纲标签
  /// （≤[kMaxOutlineTagsPerCard]，未命中空表——不强推）。
  final List<String> Function(
    String subjectId,
    String keyword,
    List<Object?> subtopics,
  )?
  outlineTagger;
}

// ------------------------------------------------------- CardPort 实装 ----

/// CardPort 的 db 直连实装（tool/run_probe.dart _DbPort 模式 + 与
/// LocalBackend 路由同语义的 data_version/已读标记副作用）。
class LocalDbPort implements CardPort {
  LocalDbPort(this.db);

  final Db db;

  /// SQLITE_BUSY 短退避重试（P1-3 isolate 化新增）：主 isolate（UI 路由）
  /// 与流水线 worker 双连接并发写 hengya.db（WAL）时，busy_timeout 编译
  /// 默认 0 → 写锁碰撞直接抛 SqliteException(5)（实测见
  /// isolate_runner.dart 文件头 ①）。写事务均为毫秒级 → 3 次退避即可
  /// 吸收；仍失败按原失败语义上抛（import_failed 不 consume——契约 9
  /// 「失败留补跑」兜底不变）。
  Future<T> _busyRetry<T>(T Function() op) async {
    const delays = [
      Duration(milliseconds: 30),
      Duration(milliseconds: 100),
      Duration(milliseconds: 300),
    ];
    var i = 0;
    while (true) {
      try {
        return op();
      } on SqliteException catch (e) {
        // 5 = SQLITE_BUSY（主码；261/517 等扩展码低 8 位同值）
        if (e.resultCode != 5 || i >= delays.length) {
          rethrow;
        }
        await Future<void>.delayed(delays[i++]);
      }
    }
  }

  @override
  Future<({bool ok, int inserted, int skipped, String? error})> importCards(
    List<Map<String, Object?>> cards,
  ) async {
    var inserted = 0;
    var skipped = 0;
    final errors = <String>[];
    for (final c0 in cards) {
      final id = (c0['id'] ?? '?').toString();
      try {
        final card = FlashCard.fromJson(Map<String, dynamic>.from(c0));
        if (!db.subjectExists(card.subjectId)) {
          // 科目缺失属暂时性故障（用户可能尚未建科目）→ 计错误，整批
          // ok=false → 引擎判 import_failed 不 consume，留补跑。
          errors.add('$id: 科目 ${card.subjectId} 不存在');
          continue;
        }
        if (await _busyRetry(() => db.importCard(card))) {
          inserted++;
        } else {
          skipped++; // 幂等：已存在的 id 跳过
        }
      } catch (e) {
        errors.add('$id: $e');
      }
    }
    if (inserted > 0) {
      // App 增量同步锚（与 /cards/import 路由同语义）
      await _busyRetry(() => db.bumpDataVersion());
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
      return (ok: true, error: null);
    }
    try {
      final n = await _busyRetry(() => db.consumeKeywords(idInts));
      if (n > 0) {
        await _busyRetry(() => db.bumpDataVersion()); // 与 /inbox/consume 路由同语义
      }
      return (ok: true, error: null);
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }

  @override
  Future<({bool ok, String? error})> reworkDone(
    int queueId, {
    required String front,
    required String back,
    required String anchor,
  }) async {
    try {
      final r = await _busyRetry(
        () => db.reworkDone(queueId, front: front, back: back, anchor: anchor),
      );
      if (r != null) {
        return (ok: false, error: r); // 'not_found' / 'stale'
      }
      // done 后自动标已读（契约 3；与 /cards/rework/<id>/done 路由同语义）
      final cardId = db.reworkQueueCardId(queueId);
      if (cardId != null) {
        await _busyRetry(() => db.markAiNoteSeen(cardId));
      }
      await _busyRetry(() => db.bumpDataVersion());
      return (ok: true, error: null);
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }
}

// ------------------------------- #12/#13 并发池队列快照与事件（私有） ----

/// 展示文本截断（事件/存档条目防长文：回炉卡题干、错误原文等）。
String _headOf(Object? v, int n) {
  final t = v?.toString() ?? '';
  return t.length > n ? '${t.substring(0, n)}…' : t;
}

/// 单关键词队列槽位（runCatchup ⑤ 池化执行 + ⑥ 入库的运行态跟踪）。
class _KwSlot {
  _KwSlot(this.seq, this.kw);

  /// 序号 = kwPending 下标（结果占位回填的保序键 + 事件 seq）。
  final int seq;

  /// 原始收件箱条目（只读）。
  final Map<String, Object?> kw;

  /// waiting → running → finished（done|failed 由 split.status 推导，
  /// ⑥ 的 import_failed 由 importKeywordCards 原地改写同一 Map）。
  bool running = false;
  bool finished = false;

  /// 时间戳（ISO 字符串——跨 isolate 安全；elapsedMs 为毫秒整数）。
  String? startedAt;
  String? endedAt;
  int? elapsedMs;

  /// splitKeyword 结果条目（与 runCatchup kwResults[seq] 同引用——import
  /// 信息原地写入此 Map，快照读到的永远是最新状态）。
  Map<String, Object?>? split;
}

/// 队列快照与进度事件装配器（runCatchup 内驱动）。单 isolate 事件循环内
/// 所有变更都发生在同步段——字段无并发竞态；takeNext 供池 worker 领号。
class _CatchupKwQueue {
  _CatchupKwQueue({
    required this.concurrency,
    required this.trigger,
    required List<Map<String, Object?>> keywords,
    required this.reworkItems,
    this.onProgress,
  }) : slots = List.generate(keywords.length, (i) => _KwSlot(i, keywords[i]));

  /// 实际池大小（= min(kKeywordConcurrency, N)；空队列 = 0）。
  final int concurrency;

  /// 触发来源（kPipelineTrigger*；事件与 last_run.json 同名透传）。
  final String trigger;

  /// 回炉队列条目（① 快照，展示裁剪形态；计数与条目进每个事件快照）。
  final List<Map<String, Object?>> reworkItems;

  /// 进度事件出口（null = 静默）。
  final void Function(Map<String, Object?> event)? onProgress;

  final List<_KwSlot> slots;
  int _cursor = 0;

  /// 池 worker 领取下一个序号；队列取尽返回 -1（worker 退出即自然清理）。
  int takeNext() => _cursor < slots.length ? _cursor++ : -1;

  int get finishedOk =>
      slots.where((s) => s.finished && _statusOf(s) == 'ok').length;

  int get finishedFailed =>
      slots.where((s) => s.finished && _statusOf(s) != 'ok').length;

  /// 已入库卡片累计（⑥ 原地写入的 import.inserted 求和——与 snapshot 同口径）。
  int get importedCount => slots.fold<int>(
    0,
    (n, s) =>
        n + (((s.split?['import'] as Map?)?['inserted'] as num?)?.toInt() ?? 0),
  );

  /// 已消费关键词累计（import.consumed == true 计数）。
  int get consumedCount => slots
      .where((s) => (s.split?['import'] as Map?)?['consumed'] == true)
      .length;

  static String _statusOf(_KwSlot s) => (s.split?['status'] ?? '').toString();

  /// 事件里的关键词条目（标识三件套：序号/收件箱 id/关键词 + 科目）。
  static Map<String, Object?> _itemOf(_KwSlot s) => <String, Object?>{
    'seq': s.seq,
    'inboxId': s.kw['id'],
    'keyword': s.kw['keyword']?.toString() ?? '',
    'subjectId': s.kw['subjectId']?.toString() ?? '',
  };

  // ---- 池 worker 生命周期钩子（runCatchup ⑤/⑥ 调用） ----

  /// 任务开跑：waiting → running + kw_start 事件。
  void markRunning(int seq, DateTime t0) {
    final s = slots[seq];
    s.running = true;
    s.startedAt = t0.toIso8601String();
    _emit(
      'kw_start',
      slot: s,
      message:
          '开始生成 ${seq + 1}/${slots.length}：'
          '${s.kw['keyword']?.toString() ?? ''}',
    );
  }

  /// 任务收口：running → finished + kw_done 事件（ok/failed 都发——
  /// summary.status 区分；failed 条目留在收件箱待补跑，契约 9）。
  void markDone(int seq, Map<String, Object?> result, DateTime t0) {
    final s = slots[seq];
    s.running = false;
    s.finished = true;
    s.split = result;
    s.endedAt = nowIso();
    s.elapsedMs = DateTime.now().difference(t0).inMilliseconds;
    final st = _statusOf(s);
    final ok = st == 'ok';
    final cards = (result['cards'] as List?)?.length ?? 0;
    _emit(
      'kw_done',
      slot: s,
      message: ok
          ? '生成完成 ${seq + 1}/${slots.length}：'
                '${s.kw['keyword']?.toString() ?? ''}（出卡 $cards 张）'
          : '生成失败 ${seq + 1}/${slots.length}：'
                '${s.kw['keyword']?.toString() ?? ''}'
                '（${_headOf(result['error'] ?? '无出卡', 80)}）',
      summary: <String, Object?>{
        'status': st,
        'cards': cards,
        'pptHit': result['pptHit'] == true,
        'elapsedMs': s.elapsedMs,
        if (!ok) 'error': _headOf(result['error'], 200),
      },
    );
  }

  /// 入库收口（⑥ 逐条）：kw_import 事件（inserted/skipped/consumed 与
  /// ⑥ 原地写入的 import_failed 状态）。
  void markImported(int seq, Map<String, Object?> kwres) {
    final s = slots[seq];
    final raw = kwres['import'];
    final m = raw is Map ? Map<String, Object?>.from(raw) : const {};
    final consumed = m['consumed'] == true;
    _emit(
      'kw_import',
      slot: s,
      message:
          '入库 ${seq + 1}/${slots.length}：'
          '${s.kw['keyword']?.toString() ?? ''}（新增 ${m['inserted'] ?? 0}、'
          '跳过 ${m['skipped'] ?? 0}、${consumed ? '已消费' : '未消费'}）',
      summary: <String, Object?>{
        'status': _statusOf(s),
        'inserted': m['inserted'],
        'skipped': m['skipped'],
        'consumed': consumed,
      },
    );
  }

  /// 队列初始化事件（② 分流后立即发——含待生成全量与回炉条目）。
  void emitStart() {
    _emit(
      'start',
      message:
          '队列初始化：待生成 ${slots.length} 条关键词、'
          '回炉 ${reworkItems.length} 项（并发池 $concurrency）',
    );
  }

  /// 阶段切换事件（phase='import'：⑤ 收口后；phase='rework'：⑥ 收口后）。
  void emitPhase(String phase, String message) =>
      _emit('phase', phase: phase, message: message);

  // ---- 快照与存档 ----

  /// 全量队列快照（**每个事件都携带**——UI 订阅后取最新一帧即可渲染完整
  /// 队列，不依赖事件回放）。不变式：runningCount+waitingCount+doneCount+
  /// failedCount == total（每槽位恰属一桶）；imported/consumed 为 ⑥ 累计。
  Map<String, Object?> snapshot() {
    final running = <Map<String, Object?>>[];
    final waiting = <Map<String, Object?>>[];
    final done = <Map<String, Object?>>[];
    final failed = <Map<String, Object?>>[];
    var imported = 0;
    var consumed = 0;
    for (final s in slots) {
      final st = _statusOf(s);
      if (s.running) {
        running.add(<String, Object?>{..._itemOf(s), 'startedAt': s.startedAt});
      } else if (!s.finished) {
        waiting.add(_itemOf(s));
      } else if (st != 'ok') {
        failed.add(<String, Object?>{
          ..._itemOf(s),
          'status': st,
          'error': _headOf(s.split?['error'], 200),
          'startedAt': s.startedAt,
          'endedAt': s.endedAt,
          'elapsedMs': s.elapsedMs,
        });
      } else {
        done.add(<String, Object?>{
          ..._itemOf(s),
          'status': st,
          'cards': (s.split?['cards'] as List?)?.length ?? 0,
          'pptHit': s.split?['pptHit'] == true,
          'startedAt': s.startedAt,
          'endedAt': s.endedAt,
          'elapsedMs': s.elapsedMs,
        });
      }
      final imp = s.split?['import'];
      if (imp is Map) {
        imported += (imp['inserted'] as num?)?.toInt() ?? 0;
        if (imp['consumed'] == true) {
          consumed++;
        }
      }
    }
    return <String, Object?>{
      'total': slots.length,
      'concurrency': concurrency,
      'runningCount': running.length,
      'waitingCount': waiting.length,
      'doneCount': done.length,
      'failedCount': failed.length,
      'imported': imported,
      'consumed': consumed,
      'running': running,
      'waiting': waiting,
      'done': done,
      'failed': failed,
      'rework': <String, Object?>{
        'total': reworkItems.length,
        'items': reworkItems,
      },
    };
  }

  /// last_run.json 顶层 queue 存档块（runCatchup 结果 'queue' 键——统计页
  /// 「卡生成队列」的持久数据源）：终态快照 + trigger/concurrency + per-
  /// 关键词统计行（含 import 明细与耗时）。
  Map<String, Object?> resultBlock() {
    return <String, Object?>{
      'trigger': trigger,
      'concurrency': concurrency,
      ...snapshot(),
      'keywords': <Map<String, Object?>>[
        for (final s in slots)
          <String, Object?>{
            ..._itemOf(s),
            'status': _statusOf(s),
            'pptHit': s.split?['pptHit'] == true,
            'cards': (s.split?['cards'] as List?)?.length ?? 0,
            if (s.split?['error'] != null)
              'error': _headOf(s.split?['error'], 200),
            'startedAt': s.startedAt,
            'endedAt': s.endedAt,
            'elapsedMs': s.elapsedMs,
            if (s.split?['import'] is Map)
              'import': Map<String, Object?>.from(s.split!['import'] as Map),
          },
      ],
    };
  }

  void _emit(
    String type, {
    String? phase,
    _KwSlot? slot,
    Map<String, Object?>? summary,
    required String message,
  }) {
    final cb = onProgress;
    if (cb == null) {
      return;
    }
    cb(<String, Object?>{
      'type': type,
      'ts': nowIso(),
      'trigger': trigger,
      'phase': ?phase,
      if (slot != null) ...<String, Object?>{
        'seq': slot.seq,
        'item': _itemOf(slot),
      },
      'summary': ?summary,
      'message': message,
      'queue': snapshot(),
    });
  }
}

// ------------------------------------------------------- 六步总编排 ----

/// 节点④（E 项拍板）：拆卡后大纲细目打标（纯函数，可离线测试）。
///
/// 对 [kwres] 逐关键词用 [tagger] 在执业树（level='zhiye'）细目级做词面
/// 强命中（输入 = 关键词 + 节点② plan 结构的 subtopics）；命中 → 该关键
/// 词本批**全部卡**（含 exam/占位卡）tags 追加「大纲：{单元}＞{细目}」
/// （序号前缀剥除），每卡此类标签 ≤[kMaxOutlineTagsPerCard]；未命中不强
/// 推（空表跳过）。打标写入 kwres note（「大纲细目打标：N 条」）供报告
/// 观测。返回打上标签的关键词数。
int applyOutlineTags(
  List<Map<String, Object?>> kwres,
  List<String> Function(
    String subjectId,
    String keyword,
    List<Object?> subtopics,
  )
  tagger,
) {
  var tagged = 0;
  for (final kw in kwres) {
    final cards = kw['cards'];
    if (cards is! List || cards.isEmpty) continue;
    final subs = kw['subtopics'];
    final tags = tagger(
      kw['subjectId']?.toString() ?? '',
      kw['keyword']?.toString() ?? '',
      subs is List ? subs : const <Object?>[],
    );
    if (tags.isEmpty) continue;
    for (final c0 in cards) {
      if (c0 is! Map) continue;
      var list = c0['tags'];
      if (list is! List) {
        list = <Object?>[];
        c0['tags'] = list;
      }
      var outlineCount = list
          .whereType<String>()
          .where((t) => t.startsWith('大纲：'))
          .length;
      for (final t in tags) {
        if (outlineCount >= kMaxOutlineTagsPerCard) break;
        if (!list.contains(t)) {
          list.add(t);
          outlineCount++;
        }
      }
    }
    final notes = kw['notes'];
    if (notes is List) {
      notes.add('大纲细目打标：${tags.length} 条');
    }
    tagged++;
  }
  return tagged;
}

/// 六步总编排（≈cmd_main_catchup，端上 local-first 形态）：
/// ① 收件箱拉取（契约 2 上下文：pending/rework/aiNotes/leech/科目名）
/// ② splitPendingBySource 分流（关键词 / 学习记录）
/// ③ compassLocate 当日科目罗盘定位 + 推进（≈L1661）
/// ④ 学习记录：同科合并 normalizeStudyLogRefs → studyLogAdvance（≈L1667）
/// ⑤ 逐关键词 splitKeyword（≈L1691）→ ⑥ importKeywordCards（≈L1700）
/// ⑥b 学习记录 consume：检索故障条目留重试（≈L1709-1730）
/// ⑦ processRework（≈L1732）→ ⑧ 罗盘落盘 → ⑨ 结果计数（report.py 口径）
///
/// 返回 result Map（counts/steps/misses/placeholders/violations/llm/
/// progressSummary——键名对齐 run.py _assemble_result，供报告层消费）。
Future<Map<String, Object?>> runCatchup({
  required PipelineDeps deps,
  RunOptions opts = const RunOptions(),

  /// #12：关键词并发池上限（缺省 [kKeywordConcurrency]=3；实际池大小 =
  /// min(本值, N)，传 ≤0 收敛为 1——串行；测试可注入 1/大值断言池行为）。
  int keywordConcurrency = kKeywordConcurrency,

  /// #13：触发来源（kPipelineTrigger*；进事件 counts.trigger 与结果
  /// meta.trigger / queue.trigger，worker 链由 PipelineCatchupRequest 透传）。
  String trigger = kPipelineTriggerManual,
}) async {
  final t0 = DateTime.now();
  final startedAt = nowIso();
  final db = deps.db;
  final progressData = deps.progressData;
  final progressBefore = jsonEncode(progressData);

  // ── #16 罗盘懒初始化（双保险 b；loadProgress 之后、推进链之前）：进度库
  //    缺条目且 toc sidecar 在 → initFromTocSidecar 补条目再进 ③/④ 推进链
  //    （幂等：只补缺、不刷新——刷新归建库收尾钩子；dry-run 跳过守住
  //    「dry-run 零变更不落盘」口径；toc 目录缺失/损坏 → 静默跳过不阻断）。
  //    初始化变更计入 progressBefore 差量 → ⑧ 落盘步自然持久（首次运行
  //    即生成 progress.json，进度页空态承诺兑现）。──
  final lazyTocDir = deps.tocDir;
  if (lazyTocDir != null && !opts.dryRun) {
    final lazySubjects = tocSidecarSubjects(lazyTocDir);
    if (lazySubjects != null) {
      for (final sid in lazySubjects) {
        if (progressEntryOf(progressData, sid) == null) {
          initFromTocSidecar(progressData, lazyTocDir, sid);
        }
      }
    }
  }

  // ── ① 契约 2：上下文拉取（端上直连 Db；无 health 探测步） ──
  var pending = db.inboxPending();
  if (opts.limit != null) {
    pending = pending.take(opts.limit!).toList();
  }
  final reworkQueue = db.reworkPending();
  final aiNotes = db.unreadAiNotes();
  final leechCount = db.leechCards().length;
  final pendingPool =
      (db.statsSummary(days: 1)['pendingCards'] as num?)?.toInt() ?? 0;
  final subjectNames = <String, String>{
    for (final s in db.subjectRows())
      s['id'] as String: (s['name'] ?? s['id']) as String,
  };
  String display(String sid) => subjectDisplayName(
    sid,
    subjectNames: subjectNames,
    progressData: progressData,
  );

  // ── ② 分流：source=study-log（罗盘推进）/ 其余（关键词拆卡） ──
  final (kwPending, slPending) = splitPendingBySource(pending);

  // ── #12/#13：并发池与队列快照装配（⑤ 池化执行的领号器 + 事件/存档
  //    数据源；回炉条目取 ① 快照裁剪形态） ──
  final poolSize = kwPending.isEmpty
      ? 0
      : keywordConcurrency.clamp(1, kwPending.length).toInt();
  final kwQueue = _CatchupKwQueue(
    concurrency: poolSize,
    trigger: trigger,
    keywords: kwPending,
    reworkItems: <Map<String, Object?>>[
      for (final r in reworkQueue)
        <String, Object?>{
          'queueId': r['id'],
          'cardId': r['cardId']?.toString(),
          'subjectId': r['subjectId']?.toString(),
          'front': _headOf(r['front'], 80),
          'reason': r['reason']?.toString() ?? '',
          'note': r['note']?.toString() ?? '',
        },
    ],
    onProgress: deps.onProgress,
  );
  kwQueue.emitStart();

  // ── ③ 教材罗盘：当日科目定位 + 推进（科目集合含学习记录科目，≈L1660） ──
  final subjectsToday = pending
      .map((k) => k['subjectId']?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .toSet();
  final compass = subjectsToday.isEmpty
      ? <String, Map<String, Object?>>{}
      : await compassLocate(
          runSearch: deps.runSearch,
          subjectsToday: subjectsToday,
          progressData: progressData,
          subjectDisplay: display,
          opts: opts,
        );

  // ── ④ 学习记录推进：同科合并一次 LLM 规范化 → 逐引用三重保险（≈L1667）──
  // Dart 内存态推进即时生效（Python 推进经 CLI 写文件后需 progress_show
  // 刷新快照，Dart 不需要——progress_db 刀交接 #1）。
  final studyLogSubjects = <Map<String, Object?>>[];
  final slBySub = <String, List<Map<String, Object?>>>{};
  for (final k in slPending) {
    slBySub.putIfAbsent(k['subjectId']?.toString() ?? '', () => []).add(k);
  }
  for (final sid in (slBySub.keys.toList()..sort())) {
    final items = slBySub[sid]!;
    final rawLines = [for (final k in items) k['keyword']?.toString() ?? ''];
    final (refs, slMode, slNotes) = await normalizeStudyLogRefs(
      llmChat: deps.llmChat,
      prompts: deps.prompts,
      subjectId: sid,
      subjectName: display(sid),
      rawLines: rawLines,
    );
    final adv = await studyLogAdvance(
      runSearch: deps.runSearch,
      subjectId: sid,
      subjectName: display(sid),
      refs: refs,
      progressData: progressData,
      opts: opts,
    );
    adv['normalizeMode'] = slMode;
    adv['normalizeNotes'] = slNotes;
    adv['entryIds'] = [for (final k in items) k['id']];
    studyLogSubjects.add(adv);
  }

  // ── ⑤ 契约 4/5/7/8：关键词并发拆卡（#12：池上限 [kKeywordConcurrency]；
  //    study-log 条目不进拆卡链路） ──
  // 结构：poolSize 个 worker 从共享游标领号（[_CatchupKwQueue.takeNext]，
  // 单 isolate 事件循环内领号为同步段，无竞态），每 worker 串行 await 一个
  // 关键词任务——同时在跑数恒 ≤ poolSize，绝不无上限并发；队列取尽 worker
  // 自然退出（无定时器/游离 Future，Future.wait 收口即清理干净）。
  // #7③ 隔离语义原样保留：任一关键词抛非预期异常（含 TypeError 等 Error）
  // 只把该条记 status=failed（契约 9：不 consume 留补跑），不影响其他在跑
  // 任务与整轮。拆卡任务零 hengya.db 写（检索只读 corpus.db + LLM HTTP +
  // progressEntry 只读视图）——写副作用全部在其后的串行段，无新增并发面。
  // kwResults 按 kwPending 序号占位回填：结果顺序与串行基线一致（下游
  // importKeywordCards 逐条消费，本身无顺序依赖，保序为报告口径稳定）。
  final legal = legalSubjects(progressData, subjectNames: subjectNames);
  final kwSlots = List<Map<String, Object?>?>.filled(kwPending.length, null);
  Future<Map<String, Object?>> runOne(Map<String, Object?> kw) async {
    final sid = kw['subjectId']?.toString() ?? '';
    return splitKeyword(
      runSearch: deps.runSearch,
      llmChat: deps.llmChat,
      prompts: deps.prompts,
      kw: kw,
      subjectName: display(sid),
      progressEntry: progressEntryOf(progressData, sid),
      legalSubjects: legal,
      opts: opts,
    );
  }

  Future<void> poolWorker() async {
    while (true) {
      final seq = kwQueue.takeNext();
      if (seq < 0) {
        return; // 队列取尽：worker 退出（池内自然清理）
      }
      final kw = kwPending[seq];
      final taskT0 = DateTime.now();
      kwQueue.markRunning(seq, taskT0);
      try {
        kwSlots[seq] = await runOne(kw);
      } catch (e) {
        kwSlots[seq] = <String, Object?>{
          'inboxId': kw['id'],
          'keyword': kw['keyword']?.toString() ?? '',
          'subjectId': kw['subjectId']?.toString() ?? '',
          'pptHit': false,
          'triedQueries': const <String>[],
          'notes': <String>['关键词处理异常（本轮隔离，不 consume 留补跑）：$e'],
          'evidenceChunks': 0,
          'examCandidates': 0,
          'cards': <Map<String, Object?>>[],
          'status': 'failed',
          'error': '$e',
        };
      }
      kwQueue.markDone(seq, kwSlots[seq]!, taskT0);
    }
  }

  await Future.wait([for (var w = 0; w < poolSize; w++) poolWorker()]);
  // 全 worker 返回 = 全部占位已回填——后续段只读非空视图（kwres 保序）
  final kwres = List<Map<String, Object?>>.generate(
    kwPending.length,
    (i) => kwSlots[i]!,
  );

  // ── ⑤.5 节点④（E 项）：大纲细目打标——出卡后、入库前；tagger null =
  //    无大纲数据（旧库/未上传大纲）不打标，未命中不强推。打标只动卡
  //    tags 与 kwres note，不影响 import/consume 语义（dry-run 同样打标，
  //    结果 steps.keywords[].cards[].tags 可观测）。──
  final outlineTagger = deps.outlineTagger;
  if (outlineTagger != null) {
    applyOutlineTags(kwres, outlineTagger);
  }

  // ── ⑥ 契约 9：import + consume（按关键词分批；dry-run 跳过） ──
  kwQueue.emitPhase(
    'import',
    '关键词生成结束（成功 ${kwQueue.finishedOk}、失败 '
        '${kwQueue.finishedFailed}），开始逐条入库',
  );
  for (var i = 0; i < kwres.length; i++) {
    await importKeywordCards(deps.port, kwres[i], opts);
    kwQueue.markImported(i, kwres[i]);
  }

  // ── ⑥b 学习记录条目 consume：出现「教材检索失败」（可能暂时）的科目条目
  //    留待重试不 consume，其余 consume（契约 9 同款语义，≈L1709-1730） ──
  var slConsumed = 0;
  bool? slConsumeOk;
  var slConsumeSkippedRetry = <int>[];
  String? slConsumeError;
  if (!opts.dryRun && slPending.isNotEmpty && deps.port != null) {
    final retryIds = <int>{};
    for (final adv in studyLogSubjects) {
      final rows = adv['refs'] as List? ?? const [];
      final hitSearchErr = rows.any(
        (r) => r is Map && ((r['note']?.toString() ?? '').startsWith('教材检索失败')),
      );
      if (hitSearchErr) {
        for (final x in (adv['entryIds'] as List? ?? const [])) {
          if (x is int) {
            retryIds.add(x);
          }
        }
      }
    }
    final ids = <int>[
      for (final k in slPending)
        if (k['id'] is int && !retryIds.contains(k['id'])) k['id'] as int,
    ];
    slConsumeSkippedRetry = retryIds.toList()..sort();
    if (ids.isNotEmpty) {
      final c = await deps.port!.consumeInbox(ids);
      slConsumeOk = c.ok;
      slConsumed = c.ok ? ids.length : 0;
      if (!c.ok) {
        slConsumeError = (c.error ?? '').length > 200
            ? c.error!.substring(0, 200)
            : c.error;
      }
    }
  }

  // ── ⑦ 契约 3：rework 逐条重写（「审核拒绝：」优先；dry-run 只出草稿） ──
  kwQueue.emitPhase(
    'rework',
    '入库结束（新增 ${kwQueue.importedCount}、消费 ${kwQueue.consumedCount}），'
        '开始回炉重造（${reworkQueue.length} 项）',
  );
  final reworkResults = await processRework(
    runSearch: deps.runSearch,
    llmChat: deps.llmChat,
    prompts: deps.prompts,
    queue: reworkQueue,
    aiNotes: aiNotes,
    subjectNames: subjectNames,
    opts: opts,
    port: deps.port,
  );

  // ── ⑧ 罗盘落盘：推进链有变更才写（dry-run 零变更自然不写） ──
  var progressSaved = false;
  final ppath = deps.progressPath;
  if (ppath != null && jsonEncode(progressData) != progressBefore) {
    saveProgress(ppath, progressData);
    progressSaved = true;
  }

  // ── ⑨ 结果装配（counts 对齐 run.py _assemble_result / report.py 口径） ──
  final allCards = <Map<String, Object?>>[
    for (final k in kwres)
      for (final c in (k['cards'] as List? ?? const []))
        if (c is Map) Map<String, Object?>.from(c),
  ];
  int asInt(Object? v) => v is num ? v.toInt() : 0;
  var inserted = 0;
  var importSkipped = 0;
  var consumedKw = 0;
  for (final k in kwres) {
    final imp = k['import'];
    if (imp is Map) {
      inserted += asInt(imp['inserted']);
      importSkipped += asInt(imp['skipped']);
      if (imp['consumed'] == true) {
        consumedKw++;
      }
    }
  }
  final slRows = <Map<String, Object?>>[
    for (final a in studyLogSubjects)
      for (final r in (a['refs'] as List? ?? const []))
        if (r is Map) Map<String, Object?>.from(r),
  ];
  final studyLogBits = <String, Object?>{
    'entries': slPending.length,
    'subjects': studyLogSubjects.length,
    'refs': slRows.length,
    'advanced': slRows.where((r) => r['advanced'] == true).length,
    'wouldAdvance': slRows.where((r) => r['wouldAdvance'] != null).length,
    'missed': slRows
        .where((r) => r['advanced'] != true && r['wouldAdvance'] == null)
        .length,
    'consumed': slConsumed,
    'consumeSkippedRetry': slConsumeSkippedRetry,
  };
  // compassAdvances：compass 行按「到达推进步（含 hit）」计（≈run.py L1108
  // 无条件口径，未变/倒退同计）+ studyLog advancedCount（≈L1266 rc==0 口径）。
  final compassAdvances =
      compass.values.where((r) => r.containsKey('hit')).length +
      studyLogSubjects.fold<int>(0, (n, a) => n + asInt(a['advancedCount']));
  final subs = progressData['subjects'];
  final progressSummary = <String, Object?>{
    if (subs is Map)
      for (final e in subs.entries)
        e.key.toString(): {
          'learnedThrough': e.value is Map
              ? asInt((e.value as Map)['learned_through'])
              : 0,
          'next': e.value is Map
              ? nextChapterTitle(Map<String, Object?>.from(e.value as Map))
              : null,
        },
  };
  return <String, Object?>{
    'meta': <String, Object?>{
      'date': todayIso(),
      'mode': 'catchup',
      'dryRun': opts.dryRun,
      'generatedAt': nowIso(),

      // #13：触发来源与池参数（last_run.json 存档键；统计页消费）
      'trigger': trigger,
      'concurrency': poolSize,
      'startedAt': startedAt,

      'elapsedSec': DateTime.now().difference(t0).inMilliseconds / 1000.0,
      'floor': opts.floor,
      'limit': opts.limit,
      'progressSaved': progressSaved,
    },
    'skipped': false,
    'steps': <String, Object?>{
      // 契约 1 health：端上直连 Db，无服务器探测——恒 ok（口径见文件头注）
      'health': <String, Object?>{'ok': true, 'note': 'local-first 端上直连'},
      'context': <String, Object?>{
        'pending': pending.length,
        'reworkQueue': reworkQueue.length,
        'aiNotes': aiNotes.length,
        'leech': leechCount,
      },
      'compass': compass,
      'studyLog': <String, Object?>{
        'subjects': studyLogSubjects,
        'entries': slPending.length,
        'consumed': slConsumed,
        'consumeOk': ?slConsumeOk,
        'consumeSkippedRetry': slConsumeSkippedRetry,
        'consumeError': ?slConsumeError,
      },
      'keywords': kwres,
      'rework': <String, Object?>{
        'processed': reworkResults,
        'rejected': reworkResults
            .where((r) => r['priorityRejected'] == true)
            .length,
        'aiNotes': reworkResults
            .where((r) => asInt(r['aiNotesRead']) > 0)
            .length,
      },
    },
    'counts': <String, Object?>{
      'inbox': pending.length,
      'keywordsProcessed': kwres.length,
      'studyLog': studyLogBits,
      'cards': <String, Object?>{
        'total': allCards.length,
        'ppt': allCards
            .where((c) => c['kind'] == 'ppt' && c['isPlaceholder'] != true)
            .length,
        'placeholder': allCards.where((c) => c['isPlaceholder'] == true).length,
        'exam': allCards.where((c) => c['kind'] == 'exam').length,
        'failed': kwres.where((k) => k['status'] == 'failed').length,
      },
      'import': <String, Object?>{
        'inserted': inserted,
        'skipped': importSkipped,
        'consumed': consumedKw,
      },
      'compassAdvances': compassAdvances,
      'reworkDone': reworkResults.where((r) => r['done'] == true).length,
      'reworkDraft': reworkResults.where((r) => r['draft'] == true).length,
      'leech': leechCount,
      'pendingPool': pendingPool,
    },
    'misses': <Map<String, Object?>>[
      for (final k in kwres)
        if (k['pptHit'] != true)
          {
            'keyword': k['keyword'],
            'subjectId': k['subjectId'],
            'queries': k['triedQueries'],
            'inboxId': k['inboxId'],
          },
    ],
    'placeholders': <Map<String, Object?>>[
      for (final c in allCards)
        if (c['isPlaceholder'] == true) c,
    ],
    'violations': <Map<String, Object?>>[
      for (final c in allCards)
        if ((c['violations'] as List?)?.isNotEmpty == true)
          {'id': c['id'], 'reasons': c['violations']},
    ],
    'llm':
        deps.account?.toJson() ??
        <String, Object?>{
          'calls': 0,
          'promptTokens': 0,
          'completionTokens': 0,
          'notes': <String>[],
        },
    'progressSummary': progressSummary,
    // #13：queue 存档块（App 侧扩展键，Python report.py 不消费）——统计页
    // 「卡生成队列」持久数据源：终态快照 + trigger/concurrency + per-关键词
    // 统计行（steps.keywords 为全量原始结果，queue.keywords 为展示统计行）。
    'queue': kwQueue.resultBlock(),
  };
}

// ------------------------------------------------------------ 周扫 ----

/// 通道 B 周扫装配（≈cmd_weekly L1941-1983；catchup 不含——服务端为独立
/// 周日 21:00 cron，App 侧供后续周日调度/手动入口调用）：
/// weeklyChapters（已学正文章唯一起点，未学不出卡）→ runWeekly（≤30/周）。
/// 节点⑤（B2 拍板）：技能五站（kExamTopics isSkill=true）豁免已学章门控，
/// 每类 ≤kWeeklySkillCapPerTopic、总量仍 ≤kWeeklyExamCap。
Future<Map<String, Object?>> runWeeklyScan({
  required PipelineDeps deps,
  RunOptions opts = const RunOptions(),

  /// 节点⑤：降级/兜底 note 收集（runWeekly 原地追加——检索降级、单卡跳过、
  /// 技能超额截断、examMeta 兜底等；随周扫结果块入 last_run.json）。
  List<String> notes = const [],
}) async {
  final subjectNames = <String, String>{
    for (final s in deps.db.subjectRows())
      s['id'] as String: (s['name'] ?? s['id']) as String,
  };
  return runWeekly(
    runSearch: deps.runSearch,
    llmChat: deps.llmChat,
    prompts: deps.prompts,
    chapters: weeklyChapters(deps.progressData, subjectNames: subjectNames),
    legalSubjects: legalSubjects(deps.progressData, subjectNames: subjectNames),
    opts: opts,
    port: deps.port,
    notes: notes,
    skillTopics: [for (final t in kExamTopics) if (t.isSkill) t],
  );
}

// ------------------------------------------------- 节点⑤ 周扫接线 ----

/// 节点⑤（B1 拍板）：上次真题周扫时间的持久化键——hengya.db settings 表
/// （既有 meta 机制，与 llm.*/embedding.* 同一通道；导出清洗只删 *.apiKey，
/// 本键非敏感可随库迁移）。值 = ISO 时间戳（nowIso）。
const String kWeeklyScanSettingKey = 'pipeline.lastWeeklyScanAt';

/// 节点⑤（B1 拍板）：自动周扫最小间隔（距上次 ≥7 天才再跑；批4 不接定时器
/// /不做 22:55 调度——只在 catchup 成功收尾后 opportunistically 触发）。
const Duration kWeeklyScanInterval = Duration(days: 7);

/// 周扫到期判定（纯函数）：无时间戳/坏值 = 从未跑过（到期）；[now] 距上次
/// ≥[kWeeklyScanInterval] = 到期。测试注入假时间戳/假时钟走本函数。
bool weeklyScanDue(String? lastRunIso, DateTime now) {
  final t = lastRunIso == null ? null : DateTime.tryParse(lastRunIso);
  if (t == null) {
    return true; // 从未跑过 / 时间戳损坏——视为到期（宁重跑不漏扫）
  }
  return now.difference(t) >= kWeeklyScanInterval;
}

/// 节点⑤（B1/B2/B3 + E4 拍板）：catchup 成功收尾后的真题周扫接线。
///
/// 节流：settings 表 [kWeeklyScanSettingKey] 时间戳距 [now]（缺省墙钟，测试
/// 注入）≥[kWeeklyScanInterval] 才跑；否则静默返回 skipped='throttled'。
///
/// 静默跳过（空态，不写时间戳——下次 catchup 自然重试）：候选为 0（罗盘
/// 无已学正文章命中且无技能专题候选，含本机无 -exam 真题语料树的检索降级）
/// → skipped='empty'，正常零结果（不报错、不出废卡、不写脏数据）。
///
/// 时间戳写入条件 = 周扫有意义地完成（候选 >0 且 LLM/import 无错；dry-run
/// 不写）：LLM/import 失败不计时（下次 catchup 重试——真题卡幂等 id 天然
/// 防重）；候选 0 不计时（重试只花本地检索，无 LLM 成本）。
///
/// 进度：[onWeeklyProgress] 收 {type: weekly_start|weekly_done, ts, message,
/// weekly} 事件（worker 侧包成 IsolateProgressEvent(stage:'weekly')）。
/// 返回周扫结果块（ran/skipped/lastRunAt/计数/notes——并入 catchup 结果
/// 顶层 'weekly' 键，随 last_run.json 存档）。
Future<Map<String, Object?>> runWeeklyAfterCatchup({
  required PipelineDeps deps,
  RunOptions opts = const RunOptions(),
  DateTime? now,
  void Function(Map<String, Object?> event)? onWeeklyProgress,
}) async {
  final t = now ?? DateTime.now();
  final db = deps.db;
  final prevIso = db.settingGet(kWeeklyScanSettingKey);
  if (!weeklyScanDue(prevIso, t)) {
    return {'ran': false, 'skipped': 'throttled', 'prevRunAt': prevIso};
  }
  onWeeklyProgress?.call(<String, Object?>{
    'type': 'weekly_start',
    'ts': nowIso(),
    'message': '真题周扫开始（距上次 ≥7 天自动触发）',
    'weekly': const <String, Object?>{'phase': 'start'},
  });
  final res = await runWeeklyScan(deps: deps, opts: opts);
  // runWeekly 内部拷贝 notes（const 默认参防护）——真实 notes 随结果返回
  final notes = (res['notes'] as List?)?.cast<String>() ?? <String>[];
  final counts = res['counts'] is Map
      ? Map<String, Object?>.from(res['counts'] as Map)
      : const <String, Object?>{};
  int asInt(Object? v) => v is num ? v.toInt() : 0;
  String? skipReason;
  if (asInt(counts['afterBalance']) == 0) {
    skipReason = 'empty';
  } else if (res['llmError'] != null) {
    skipReason = 'llmError';
  } else if (res['importError'] != null) {
    skipReason = 'importError';
  }
  final ran = skipReason == null;
  String? savedAt;
  if (ran && !opts.dryRun) {
    savedAt = nowIso();
    db.settingSet(kWeeklyScanSettingKey, savedAt);
  }
  final out = <String, Object?>{
    'ran': ran,
    'skipped': ?skipReason,
    'prevRunAt': prevIso,
    'lastRunAt': ?savedAt,
    'chapters': (res['chapters'] as List?)?.length ?? 0,
    'candidates': counts['afterBalance'],
    'cards': counts['cards'],
    'imported': counts['imported'],
    'counts': counts,
    'notes': notes,
  };
  onWeeklyProgress?.call(<String, Object?>{
    'type': 'weekly_done',
    'ts': nowIso(),
    'message': ran
        ? '真题周扫完成：候选 ${out['candidates']}、出卡 ${out['cards']}、'
              '导入 ${out['imported']}'
        : '真题周扫静默跳过（$skipReason）',
    'weekly': out,
  });
  return out;
}

// ------------------------------------------------------- App 实装装配 ----

/// settings embedding.* → 查询嵌入配置（null = key/model 缺失，词面单路）。
///
/// **互斥校验命脉**：embedModel 必须透传真实 settings embedding.model
/// （corpusSearch 以此对库内 meta.embedding_model 做空间互斥——占位值会让
/// 向量路静默跳过）。key/model 任一缺失 → null：词面单路，offline 无 key
/// 路不炸。绝不打印 key。
///
/// key 来源（安全修复 C：key 存系统安全存储 AiKeyVault，不再读 settings
/// 表明文）：[apiKey] 显式传入（worker 侧——vault 平台通道仅主 isolate
/// 可用，key 由 PipelineCatchupRequest 随请求下发）；缺省读主 isolate 的
/// [LocalBackend.aiKeyOf] 内存缓存。
///
/// instruct 前缀开关（节点③）：settings `embedding.instructQuery`='0' →
/// queryInstruct=''（禁用前缀，Gitee/模力方舟通道）；缺省/其他值 → null
/// （=内置 kQueryInstruct，2026-09-06 真库 A/B 定论：保留——禁用则生造词
/// 越过低分线）。建库侧（ingest）嵌入不带前缀（Python 同口径），该开关
/// 仅作用于查询侧——所有查询嵌入装配统一走本函数。
SiliconFlowConfig? assembleEmbedConfig(Db db, {String? apiKey}) {
  final key = apiKey ?? LocalBackend.instance.aiKeyOf('embedding');
  final model = db.settingGet('embedding.model') ?? '';
  if (key.isEmpty || model.isEmpty) {
    return null;
  }
final baseUrl = db.settingGet('embedding.baseUrl') ?? '';
  final instructOff = (db.settingGet('embedding.instructQuery') ?? '') == '0';
  final rerankBase = db.settingGet('reranker.baseUrl') ?? '';
  final rerankModel = db.settingGet('reranker.model') ?? '';
  return SiliconFlowConfig(
    apiKey: key,
    // #6①（2026-09-07）：settings 存基址形态（…/v1）与完整端点形态
    //（…/v1/embeddings，真机可能已手动补后缀）两种并存——统一经
    // normalizeEmbedEndpoint 规范化成完整端点（空回退默认端点）。修复前
    // 基址形态直接透传 embedBaseUrl → 查询嵌入 POST …/v1 恒 404 →
    // 三级检索全灭 → 全占位卡（建库侧 local_backend._selectBuildMode
    // 一直有同款补尾拼法——同配置两路径分裂的根因）。
    embedBaseUrl: normalizeEmbedEndpoint(baseUrl),
    embedModel: model,
    queryInstruct: instructOff ? '' : null,
    // 2026-09-11：reranker 同样两形态兼容（对齐 embed——基址 …/v1 经
    // normalizeRerankEndpoint 补 /rerank；空回退默认端点）。修复前本字段
    // 恒走默认 kRerankApiUrl → 用户设置页配的 reranker.baseUrl/model 对
    // 运行时检索重排完全不生效（只影响设置页测试连接展示）。
    rerankUrl: normalizeRerankEndpoint(rerankBase),
    rerankModel: rerankModel.isEmpty ? kRerankModelDefault : rerankModel,
  );
}

/// settings embedding.* → 查询嵌入注入（[assembleEmbedConfig] 的闭包形态）。
///
/// **互斥校验命脉**：embedModel 必须透传真实 settings embedding.model
/// （corpusSearch 以此对库内 meta.embedding_model 做空间互斥——占位值会让
/// 向量路静默跳过）。key/model 任一缺失 → (null, null)：词面单路，
/// offline 无 key 路不炸。绝不打印 key。
/// key 来源见 [assembleEmbedConfig]（安全修复 C：AiKeyVault）。
({EmbedQueryFn? embed, String? embedModel}) assembleEmbedder(
  Db db, {
  String? apiKey,
}) {
  final cfg = assembleEmbedConfig(db, apiKey: apiKey);
  if (cfg == null) {
    return (embed: null, embedModel: null);
  }
  return (embed: siliconFlowEmbedder(cfg), embedModel: cfg.embedModel);
}

/// corpus.db 只读打开（缺失/损坏 → null → 检索全降级 SearchException）。
Database? tryOpenCorpusDb(String path) {
  if (!File(path).existsSync()) {
    return null;
  }
  try {
    return sqlite3.open(path, mode: OpenMode.readOnly);
  } catch (_) {
    return null;
  }
}

/// RunSearchFn 装配（探针同款包装）：
/// - corpusDb=null → 每次调用直接 SearchException（契约 10 降级）；
/// - corpusSearch 任何异常（含 schema StateError）→ SearchException 统一出口；
/// - #8（2026-09-07）：该次查询嵌入异常（404/402/超时等）不再炸穿整个
///   检索——既有契约 embed 返回 null 即降级词面单路，此处把「抛异常」
///   归一成「返回 null」，词面路在 corpusSearch 内先行完成不受影响，
///   降级原因如实追加进结果 notes（词面单路即可出真卡，实测 11 张）。
RunSearchFn assembleRunSearch({
  Database? corpusDb,
  required String corpusPath,
  EmbedQueryFn? embed,
  String? embedModel,
  bool offline = false,
  List<double>? weights,
}) {
  return (query, {subject, sourceType, k}) async {
    if (corpusDb == null) {
      throw SearchException('corpus.db 不存在或无法打开（$corpusPath）');
    }
    Object? embedFailure; // 本次调用的嵌入异常（首错为准）
    final EmbedQueryFn? safeEmbed = embed == null
        ? null
        : (String q) async {
            try {
              return await embed(q);
            } catch (e) {
              embedFailure ??= '$e';
              return null; // 契约同款：null → 向量路跳过 → 词面单路
            }
          };
    try {
      final result = await corpusSearch(
        corpusDb,
        query,
        subject: subject,
        sourceType: sourceType,
        k: k ?? kSearchK,
        weights: weights ?? kSearchWeightsDefault,
        offline: offline,
        embed: safeEmbed,
        embedModel: embedModel,
      );
      if (embedFailure != null) {
        final n = result['notes'];
        if (n is List) {
          n.add('查询嵌入异常，降级词面单路（#8）：$embedFailure');
        }
      }
      return result;
    } catch (e) {
      throw SearchException('$e');
    }
  };
}

/// assets/prompts 模板加载（rootBundle；读取失败 → null → loadPrompts
/// 内置兜底 + note，与探针「仓库源 → assets → 兜底」的降级链同构）。
Future<(Map<String, String>, List<String>)> loadPromptsAsset() async {
  final files = <PromptFile>[];
  for (final name in const ['主跑-22-55-server.md', '周度扫题-周日-server.md']) {
    String? text;
    try {
      text = await rootBundle.loadString('assets/prompts/$name');
    } catch (_) {
      // 资产缺失/测试宿主未注册 → 兜底（notes 如实记录）
    }
    files.add((name: name, text: text));
  }
  return loadPrompts(files);
}

// ------------------------------------ P1-3 后台 isolate job 封装 ----

/// 拆卡流水线 job 的 IsolateRunner 单飞键。
const String pipelineCatchupJobId = 'pipeline-catchup';

/// 拆卡流水线 job 请求（主 → worker；字段全部可跨 isolate）。
///
/// 提示词模板由主 isolate 经 rootBundle 预读后传入——平台通道仅主
/// isolate 可用（isolate_runner.dart 文件头 ③），worker 绝不自读资产。
class PipelineCatchupRequest {
  const PipelineCatchupRequest({
    required this.dataDir,
    required this.prompts,
    required this.aiKeys,
    required this.promptNotes,
    this.trigger = kPipelineTriggerManual,
  });

  /// 数据根目录（hengya.db 与 corpus/ 挂其下——与 LocalBackend.init 同源）。
  final String dataDir;

  /// 提示词模板（loadPromptsAsset 产物；worker 直用，与主 isolate 直跑
  /// 时的装配完全同源）。
  final Map<String, String> prompts;

  /// AI 服务 key（'embedding' / 'llm'——worker 需要的两把）。安全修复 C：
  /// key 存系统安全存储 AiKeyVault，而 vault 走平台通道**仅主 isolate
  /// 可用**（文件头 ③）——主 isolate 经 [LocalBackend.aiKeyOf] 内存缓存
  /// 预读随请求下发，与 prompts 同一跨隔离模式；worker 绝不自读 vault。
  final Map<String, String> aiKeys;

  /// 模板加载 note（LLM 账本 notes 附加——语义同前）。
  final List<String> promptNotes;

  /// #13：触发来源（kPipelineTrigger*；[PipelineRunner.consumeForceRun]
  /// 的 trigger 参数透传 → runCatchup → 进度事件与 last_run.json meta）。
  final String trigger;
}

/// 拆卡流水线 worker 入口（Isolate.spawn 顶层函数；[PipelineRunner._runOnce]
/// 装配）。worker 内自开 hengya.db（Db.open——WAL/foreign_keys 每连接
/// 重放）+ corpus.db（tryOpenCorpusDb 只读）跑 [runCatchup]——全部写副作用
/// （subjectExists 守卫 / importCard 幂等 / bumpDataVersion / 已读标记）在
/// worker 自己的连接上完成，语义与文件头写副作用契约逐点一致。
///
/// 进度协议：stage='catchup'，开始/完成各一条；完成条 counts 携带
/// {inbox, keywordsProcessed, compassAdvances, reworkDone, cardsTotal}。
void pipelineCatchupWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    final req = boot.args! as PipelineCatchupRequest;
    ctx.emit(
      const IsolateProgressEvent(
        stage: 'catchup',
        message: '拆卡流水线开始（后台 isolate 执行）',
      ),
    );
    final result = await _runCatchupInWorker(req, ctx);
    final counts =
        (result['counts'] as Map?)?.cast<String, Object?>() ?? const {};
    final cards = counts['cards'] as Map?;
    ctx.emit(
      IsolateProgressEvent(
        stage: 'catchup',
        message:
            '拆卡流水线完成：收件箱 ${counts['inbox']}、关键词 '
            '${counts['keywordsProcessed']}、出卡 ${cards?['total']}、导入 '
            '${(counts['import'] as Map?)?['inserted']}',
        counts: <String, Object?>{
          'inbox': counts['inbox'],
          'keywordsProcessed': counts['keywordsProcessed'],
          'compassAdvances': counts['compassAdvances'],
          'reworkDone': counts['reworkDone'],
          'cardsTotal': cards?['total'],
        },
      ),
    );
    return result;
  });
}

/// worker 侧六步总编排执行（P1-3 迁移自 PipelineRunner._runOnce 主体；
/// 装配链 assembleEmbedder/assembleRunSearch/llmChatFn 与主 isolate 直跑
/// 完全同源——baseUrl/model 等非敏感 settings（llm.*/embedding.*）读自
/// worker 自己的连接；AI key 例外：vault 平台通道仅主 isolate，key 由
/// [PipelineCatchupRequest.aiKeys] 随请求下发（安全修复 C））。
Future<Map<String, Object?>> _runCatchupInWorker(
  PipelineCatchupRequest req,
  IsolateWorkerContext ctx,
) async {
  final dataDir = req.dataDir;
  final db = await Db.open('$dataDir/hengya.db'); // worker 自开连接
  try {
    final corpusPath = '$dataDir/corpus/corpus.db';
    final cdb = tryOpenCorpusDb(corpusPath);
    try {
      final (:embed, :embedModel) = assembleEmbedder(
        db,
        // 安全修复 C：key 随请求下发（vault 平台通道仅主 isolate），
        // worker 绝不自读 vault/settings 表明文
        apiKey: req.aiKeys['embedding'] ?? '',
      );
      final runSearch = assembleRunSearch(
        corpusDb: cdb,
        corpusPath: corpusPath,
        embed: embed,
        embedModel: embedModel,
      );
final llmCfg = LlmConfig(
        baseUrl: db.settingGet('llm.baseUrl') ?? '',
        apiKey: req.aiKeys['llm'] ?? '',
        model: db.settingGet('llm.model') ?? '',
      );
      // 备用生卡 LLM（llm_backup.*，可选）：主连续失败 3 次切备用；
      // 备用也连续失败 3 次 → 熔断（本轮跳过、收件箱保留，次日自动再试）。
      final backupCfg = LlmConfig(
        baseUrl: db.settingGet('llm_backup.baseUrl') ?? '',
        apiKey: req.aiKeys['llm_backup'] ?? '',
        model: db.settingGet('llm_backup.model') ?? '',
      );
      final account = LlmAccount();
      if (!llmCfg.configured) {
        account.notes.add(
          'LLM 未配置（settings llm.* 缺 baseUrl/apiKey/'
          'model）——关键词将按 failed 处理（契约 9：不 consume）',
        );
      }
      account.notes.addAll(req.promptNotes);
      // failover 装配：备用已配置 → 主备自动切换；否则纯主通道（行为零变化）。
      // failover 事件记入 account.notes（流水线结果/设置页可见，Q4-A）。
      final failoverEvents = <String>[];
      final llmChat = failoverLlmChatFn(
        primary: llmCfg,
        backup: backupCfg.configured ? backupCfg : null,
        account: account,
        onEvent: (event, state) {
          final msg = switch (event) {
            LlmFailoverEvent.switchedToBackup =>
              '主 LLM 连续失败，已切备用生卡 LLM（备用模型 ${backupCfg.model}）',
            LlmFailoverEvent.switchedBackToPrimary => '备用成功冷却到期，已切回主 LLM',
            LlmFailoverEvent.tripped =>
              '主备生卡 LLM 均连续失败已熔断，本轮剩余关键词跳过（收件箱保留，次日自动重试）',
          };
          failoverEvents.add(msg);
          account.notes.add(msg);
        },
      );
      final progressPath = '$dataDir/corpus/progress.json';
      // 节点④（E 项）：大纲细目打标器——corpus.db outline_entries 载入
      // 执业树索引（corpus.db 只读连接；缺 outline_entries 表（旧库）或
      // 无数据 → null 不打标，降级绝不炸流水线）。
      List<String> Function(String, String, List<Object?>)? outlineTagger;
      if (cdb != null) {
        try {
          final idx = loadZhiyeSubtopicIndex(cdb);
          if (idx.isNotEmpty) {
            outlineTagger = (sid, kw, subs) => outlineTagsFor(
              subjectId: sid,
              keyword: kw,
              subtopics: subs,
              index: idx,
            );
          }
        } catch (_) {
          // 旧 corpus.db 无 outline_entries → 不打标（未上传大纲同态）
        }
      }
      final catchupDeps = PipelineDeps(
        db: db,
        runSearch: runSearch,
llmChat: llmChat,
        prompts: req.prompts,
        progressData: loadProgress(progressPath),
        progressPath: progressPath,
        // #16 罗盘懒初始化（双保险 b）：catchup 装配处把 toc 目录交给
        // runCatchup——条目缺失且 sidecar 在的科目开跑即自动生成罗盘；
        // 既有语料装新版后首次拆卡/启动补跑覆盖。
        tocDir: '$dataDir/corpus/toc',
        account: account,
        outlineTagger: outlineTagger,
        // #13：关键词粒度事件 → IsolateProgressEvent（stage 固定
        // 'catchup'；结构化契约即事件 Map 本体，进 counts——字段全部
        // 可跨 isolate，UI 消费面见 PipelineDeps.onProgress 文档）。
        onProgress: (event) => ctx.emit(
          IsolateProgressEvent(
            stage: 'catchup',
            message: event['message']?.toString() ?? '',
            counts: event,
          ),
        ),
      );
      final result = await runCatchup(trigger: req.trigger, deps: catchupDeps);
      // ── 节点⑤（B1 拍板）：catchup 成功收尾后 ≥7 天自动真题周扫 ──
      // 同一 deps 复用（progressData 为本轮推进后的最新内存态）；进度事件
      // 以 stage='weekly' 独立上报（与 'catchup' 阶段区分）；周扫结果块并入
      // 结果顶层 'weekly' 键（随 last_run.json 存档，统计页面板消费）。
      // 节流/空态/失败语义见 [runWeeklyAfterCatchup]——任何分支都不抛
      // （周扫是 catchup 的 opportunistic 追加，绝不影响主轮成败）。
      try {
        result['weekly'] = await runWeeklyAfterCatchup(
          deps: catchupDeps,
          onWeeklyProgress: (event) => ctx.emit(
            IsolateProgressEvent(
              stage: 'weekly',
              message: event['message']?.toString() ?? '',
              counts: event,
            ),
          ),
        );
      } catch (_) {
        // 周扫装配异常（如 settings 读写故障）：静默跳过——不写脏数据、
        // 不掩盖 catchup 成功结果（下次 catchup 再试）
      }
      return result;
    } finally {
      // worker 随后退出——close 失败不掩盖流水线成功结果
      try {
        cdb?.dispose();
      } catch (_) {
        // dispose 失败随 isolate 退出由 OS 回收
      }
    }
  } finally {
    try {
      db.close();
    } catch (_) {
      // 同上：close 失败不掩盖流水线结果
    }
  }
}

// --------------------------------------------------------- 标志消费 ----

/// .force_run 标志消费器（单例）：路由 kick / 启动消费共用。
class PipelineRunner {
  PipelineRunner._();

  static final PipelineRunner instance = PipelineRunner._();

  /// 测试注入（生产勿碰）：覆盖单轮执行（返回 ok；null = 走真实链）。
  Future<bool> Function(String dataDir)? runOnceOverride;

  static const markerName = '.force_run';

  bool _spinning = false;
  bool _running = false;

  /// 流水线是否正在运行（UI 状态行/防重复触发用）。
  bool get running => _running;

  /// 后台流水线进度事件流（P1-3；broadcast——无订阅者时事件丢弃）。
  /// 事件源自 worker（pipelineCatchupWorkerEntry 进度协议：
  /// stage='catchup' 开始/完成各一条，完成条携带计数）。
  Stream<IsolateProgressEvent> get progress => _progressCtrl.stream;

  final StreamController<IsolateProgressEvent> _progressCtrl =
      StreamController<IsolateProgressEvent>.broadcast();

  /// 最近一次运行结果（内存态；完整结果持久化在
  /// `<dataDir>/corpus/last_run.json`）。
  Map<String, Object?>? lastResult;

  /// 最近一次运行时间。
  DateTime? lastRunAt;

  /// #13：最近一条进度事件缓存（新轮开跑时置 null）。broadcast 流无监听
  /// 期间事件即弃——统计页等**中途订阅者**可直接读本字段获得当前队列快照
  ///（事件逐帧自洽，见 PipelineDeps.onProgress 契约），不必等下一事件；
  /// 完整终态兜底仍在 last_run.json。多读单写（仅 _runOnce 订阅回调写），
  /// 多监听安全。
  IsolateProgressEvent? lastProgress;

  /// .force_run 标志消费（≈force-check.sh）：有标志才跑一轮；单飞——
  /// 运行中重复 kick 直接返回（标志仍在，语义=排队中）；成功（rc==0 同义）
  /// 删标志，失败留标志待下次触发/启动再消费（进程内不自动重试）。
  /// 本方法绝不抛（kick 侧 unawaited 安全）。
  ///
  /// [trigger]（#13）：触发来源。kick tear-off 赋值给
  /// LocalBackend.pipelineKick（`Future<void> Function()?`——可选命名参数
  /// 的 tear-off 是其子类型，既有装配零改动）；App 启动消费传
  /// [kPipelineTriggerStartup]，定时 22:55 调度器接入时传
  /// [kPipelineTriggerScheduled]。
  Future<void> consumeForceRun({
    String trigger = kPipelineTriggerManual,
  }) async {
    if (_spinning) {
      return;
    }
    _spinning = true;
    try {
      final dir = LocalBackend.instance.dataDir;
      if (dir == null || !_markerExists(dir)) {
        return;
      }
      _running = true;
      lastProgress = null; // 新轮开跑：上一轮缓存作废（事件逐帧自洽）
      var ok = false;
      try {
        ok = await _runOnce(dir, trigger: trigger);
      } catch (_) {
        ok = false; // 装配/编排异常：留标志，下次触发/启动再消费
      } finally {
        _running = false;
      }
      if (ok) {
        _deleteMarker(dir);
      }
    } finally {
      _spinning = false;
    }
  }

  bool _markerExists(String dataDir) => File(markerPath(dataDir)).existsSync();

  static String markerPath(String dataDir) => '$dataDir/corpus/$markerName';

  void _deleteMarker(String dataDir) {
    try {
      File(markerPath(dataDir)).deleteSync();
    } catch (_) {}
  }

  /// 单轮执行（P1-3 起六步编排在后台 isolate 跑）：
  /// ① runOnceOverride 注入缝优先（测试 fake——主 isolate 直跑，不动）；
  /// ② 真实链：主 isolate rootBundle 预读提示词 → IsolateRunner spawn
  ///    worker（单飞键 [pipelineCatchupJobId]）→ worker 自开 Db/corpus
  ///    连接跑 runCatchup（见 _runCatchupInWorker）→ 结果回传后主 isolate
  ///    存档 last_run.json（契约 12 端上单文件形态）。
  ///    失败/取消 → 异常上抛 → consumeForceRun 捕获（ok=false 留标志）。
  Future<bool> _runOnce(
    String dataDir, {
    String trigger = kPipelineTriggerManual,
  }) async {
    final override = runOnceOverride;
    if (override != null) {
      return override(dataDir);
    }
    // 平台通道仅主 isolate：提示词先读好随请求下发（文件头 ③）；
    // AI key 同理——vault 缓存预热（main() 已接线，幂等兜底）后随请求
    // 下发（安全修复 C）。预热失败不阻断：worker 以空 key 降级
    //（LLM 未配置 → 关键词 failed 留补跑，契约 9）。
    try {
      await LocalBackend.instance.initAiKeys();
    } catch (_) {}
    final (prompts, promptNotes) = await loadPromptsAsset();
    final handle = await IsolateRunner.instance.start<Map<String, Object?>>(
      jobId: pipelineCatchupJobId,
      workerEntry: pipelineCatchupWorkerEntry,
      args: PipelineCatchupRequest(
        dataDir: dataDir,
        prompts: prompts,
aiKeys: {
          'embedding': LocalBackend.instance.aiKeyOf('embedding'),
          'llm': LocalBackend.instance.aiKeyOf('llm'),
          'llm_backup': LocalBackend.instance.aiKeyOf('llm_backup'),
        },
        promptNotes: promptNotes,
        trigger: trigger,
      ),
    );
    final sub = handle.progress.listen((e) {
      lastProgress = e; // #13：中途订阅者取当前快照用（见字段注释）
      _progressCtrl.add(e);
    });
    try {
      final result = await handle.done;
      lastResult = result;
      lastRunAt = DateTime.now();
      _persistLastRun(dataDir, result);
      return true;
    } finally {
      await sub.cancel();
    }
  }

  /// 最近一次运行结果存档（原子写；每次覆盖——手机磁盘纪律）。
  void _persistLastRun(String dataDir, Map<String, Object?> result) {
    try {
      Directory('$dataDir/corpus').createSync(recursive: true);
      atomicWriteText(
        '$dataDir/corpus/last_run.json',
        const JsonEncoder.withIndent(' ').convert(result),
      );
    } catch (_) {
      // 存档失败不影响流水线结果（下次运行覆盖）
    }
  }
}
