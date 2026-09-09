// 统计页「卡生成队列」面板（#13，2026-09-07）：
// ============================================================================
// 拆卡流水线的生成过程透明化——用户手机曾只出 6 张真卡 vs 预期 11 张、过程
// 不可见；本面板让「正在生成 / 待生成 / 失败 / 回炉」的队列状态实时可见。
//
// 数据流（只消费，不改后端——pipeline_runner/run_engine/search_api 为禁改
// 内核）：
//   · 运行中：订阅 [PipelineRunner.progress]（broadcast，事件逐帧自洽——
//     counts['queue'] 即全量队列快照）实时刷新；订阅/取消订阅生命周期与
//     面板 State 绑定（initState 订阅 / dispose 取消）。
//   · 中途打开面板：[PipelineRunner.lastProgress] 缓存最近一帧（新轮开跑
//     置 null——此刻显示「正在准备队列数据」过渡态）。
//   · 冷启动 / 无流：读 `<dataDir>/corpus/last_run.json` 终态快照兜底
//     （meta.trigger/concurrency/elapsedSec + queue 块 + counts.reworkDone）。
//   · 完成切换：worker 的「流水线完成」包裹事件先于 handle.done/persist/
//     running=false 送达——收到后短轮询等运行位释放，再重读终态快照，
//     spinner 停、视图切「上次运行」。
//
// 数据源经 [PipelineQueueSource] 抽象注入：生产 = PipelineRunner + 文件；
// 测试注入 fake（同 LocalBackend.corpusBuildJobOverride 的注入缝纪律）。
// [rev] 为刷新信号（统计页 _load/pull-to-refresh 自增——面板重读快照），
// 与设置页 _corpusRev（#3）同一模式。
//
// #16（2026-09-07）终态学习记录摘要行：last_run.json counts.studyLog
// （entries/advanced）+ steps.studyLog 首因 note → 终态快照多一行
// 「学习记录：推进 N 章」/「学习记录：<首因 note>」；无学习记录条目不渲染，
// live 帧不强求（快照帧口径）。口径：罗盘=教材章进度，仅「章节」学习
// 记录经流水线推进；关键词→卡片→复习统计不推罗盘（设计如此，
// progress_db.dart 文件头注记）。
//
// 触发来源（#13 契约 counts.trigger / meta.trigger）：manual=手动「立即触发」
// / startup=启动补跑遗留标志 / scheduled=定时 22:55（App 侧预留值）。
//
// ⑦（2026-09-07）回炉队列统计联动：「回炉待重造 N」常显行——回炉积压量
// （rework_queue pending 行数，覆盖待审核拒绝带理由、题库/复习页回炉
// 按钮两个登记入口，reworkDone 后回落），经 PipelineQueueSource
// .fetchReworkPending → 语料状态端点 `GET /api/v1/corpus/status` 的
// reworkPending 字段读取；initState / rev 自增 / 流水线收尾三处重读，
// 空态与终态均渲染（N=0 也显示）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/api/api_client.dart';
import '../services/local/isolate_runner.dart' show IsolateProgressEvent;
import '../services/local/local_backend.dart' show LocalBackend;
import '../services/local/pipeline_runner.dart'
    show
        kPipelineTriggerManual,
        kPipelineTriggerScheduled,
        kPipelineTriggerStartup,
        PipelineRunner;

/// 队列面板数据源抽象：生产 = PipelineRunner（事件流/最近事件/运行位）+
/// last_run.json 终态快照；测试 extends 注入 fake。
class PipelineQueueSource {
  const PipelineQueueSource();

  /// 运行中进度事件流（broadcast——订阅/取消订阅由面板生命周期管理）。
  Stream<IsolateProgressEvent> get events => PipelineRunner.instance.progress;

  /// 最近一条事件缓存（中途订阅者取当前快照；新轮开跑置 null）。
  IsolateProgressEvent? get lastEvent => PipelineRunner.instance.lastProgress;

  /// 流水线是否正在运行。
  bool get running => PipelineRunner.instance.running;

  /// ⑦ 回炉待重造计数（rework_queue pending 行数，即下次流水线将重造的
  /// 积压量）：经语料状态端点（`GET /api/v1/corpus/status` →
  /// [CorpusStatus.reworkPending]）读取。返回 null = 拉取失败（面板不
  /// 渲染该行——不阻断队列主视图）。
  Future<int?> fetchReworkPending() async {
    try {
      final s = await ApiClient.instance.fetchCorpusStatus();
      return s.reworkPending;
    } catch (_) {
      return null;
    }
  }

  /// 上次运行持久快照（`<dataDir>/corpus/last_run.json` 终态兜底；null =
  /// 无存档或不可读）。只读文件，不触碰内核写路径。
  Map<String, Object?>? readSnapshot() {
    final dir = LocalBackend.instance.dataDir;
    if (dir == null) return null;
    try {
      final f = File('$dir/corpus/last_run.json');
      if (!f.existsSync()) return null;
      final raw = jsonDecode(f.readAsStringSync());
      return raw is Map ? Map<String, Object?>.from(raw) : null;
    } catch (_) {
      // 存档损坏/占用：按「无存档」处理，不阻断面板
      return null;
    }
  }
}

/// 统计页「卡生成队列」面板（local 模式显示——流水线为端上 local-first 链路，
/// demo/remote 无此数据面，统计页按模式门控渲染本组件）。
class PipelineQueueCard extends StatefulWidget {
  const PipelineQueueCard({super.key, this.source, this.rev});

  /// 数据源（null = 生产 PipelineQueueSource；测试注入 fake）。
  final PipelineQueueSource? source;

  /// 刷新信号（统计页 _load / pull-to-refresh 时自增 → 面板重读当前态）。
  final ValueListenable<int>? rev;

  @override
  State<PipelineQueueCard> createState() => _PipelineQueueCardState();
}

class _PipelineQueueCardState extends State<PipelineQueueCard> {
  late final PipelineQueueSource _src;
  StreamSubscription<IsolateProgressEvent>? _sub;
  _QueueFrame? _frame; // 当前渲染帧（null = 无数据）
  bool _live = false; // true = 运行中实时帧；false = 终态快照
  bool _loading = true; // 仅初始加载一瞬间
  int? _reworkPending; // ⑦ 回炉待重造计数（null = 未拉到，行不渲染）
  String? _weeklyLine; // ⑤ 真题周扫摘要行（null/空 = 不渲染；节流/空态静默）

  @override
  void initState() {
    super.initState();
    _src = widget.source ?? const PipelineQueueSource();
    // broadcast 流：无订阅者期间事件即弃——订阅生命周期与面板 State 严格绑定
    _sub = _src.events.listen(_onEvent, onError: (Object _) {});
    widget.rev?.addListener(_onRevChanged);
    _refresh();
  }

  @override
  void dispose() {
    widget.rev?.removeListener(_onRevChanged);
    unawaited(_sub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  void _onRevChanged() {
    if (mounted) _refresh();
  }

  /// 事件分发（四类，见 pipelineCatchupWorkerEntry / PipelineDeps.onProgress /
  /// runWeeklyAfterCatchup）：
  /// ① counts['queue'] 为 Map → 关键词粒度队列帧（kw_start/kw_done/…），实时刷新；
  /// ①b counts['weekly'] 为 Map → ⑤ 周扫阶段帧（stage='weekly' 事件——开始/
  ///    完成各一条；不携带队列快照，只更新周扫摘要行，不动既有队列帧）；
  /// ② counts == null → worker「开始」包裹事件：新轮开跑，帧稍后到；
  /// ③ counts 含 cardsTotal → worker「完成」包裹事件：等运行位收口后重读终态。
  void _onEvent(IsolateProgressEvent e) {
    if (!mounted) return;
    final c = e.counts;
    if (c?['queue'] is Map) {
      setState(() {
        _frame = _QueueFrame.fromEvent(e);
        _live = true;
        _loading = false;
      });
      return;
    }
    if (c?['weekly'] is Map) {
      // ⑤ 真题周扫阶段（stage='weekly'）：只更新摘要行（live 帧保持）
      setState(() {
        _weeklyLine = _weeklyLineOf(c!['weekly']);
        _loading = false;
      });
      return;
    }
    if (c == null) {
      // 新轮开跑（上一轮缓存已作废）：进实时态、清旧帧等首帧队列数据
      setState(() {
        _live = true;
        _frame = null;
        _loading = false;
        _weeklyLine = null;
      });
      return;
    }
    if (c.containsKey('cardsTotal')) {
      unawaited(_awaitTerminal());
    }
  }

  /// 初始 / 刷新：运行中取最近事件帧（lastProgress）；否则读 last_run.json。
  Future<void> _refresh() async {
    // ⑦ 回炉待重造计数随本面板刷新一起重读（initState / rev 自增均经此）
    unawaited(_loadReworkPending());
    if (_src.running) {
      final e = _src.lastEvent;
      if (e?.counts?['queue'] is Map) {
        if (!mounted) return;
        setState(() {
          _frame = _QueueFrame.fromEvent(e!);
          _live = true;
          _loading = false;
        });
      } else if (e?.counts?['weekly'] is Map) {
        // ⑤ 周扫阶段帧：队列终态已在（kw 全成）+ 周扫摘要行更新
        if (!mounted) return;
        setState(() {
          _live = true;
          _loading = false;
          _weeklyLine = _weeklyLineOf(e!.counts!['weekly']);
        });
      } else if (mounted) {
        setState(() {
          _live = true;
          _frame = null; // 新轮刚启动、首帧未到
          _loading = false;
        });
      }
      return;
    }
    final snap = _src.readSnapshot();
    if (!mounted) return;
    setState(() {
      _live = false;
      _frame = snap == null ? null : _QueueFrame.fromSnapshot(snap);
      _loading = false;
      _weeklyLine = _weeklyLineOf(snap?['weekly']);
    });
  }

  /// 「完成」包裹事件先于 handle.done → _persistLastRun → running=false 送达：
  /// 短轮询等运行位释放（生产 1-2 拍 ≈50-100ms；上限 40 拍 ≈2s 防呆）后重读
  /// 终态快照。轮询失败/无存档（异常路径）时保留最后事件帧、只停实时指示。
  Future<void> _awaitTerminal() async {
    for (var i = 0; i < 40; i++) {
      if (!mounted) return;
      if (!_src.running) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return;
    final snap = _src.readSnapshot();
    if (!mounted) return;
    setState(() {
      _live = false;
      if (snap != null) _frame = _QueueFrame.fromSnapshot(snap);
      _weeklyLine = _weeklyLineOf(snap?['weekly']);
    });
    // ⑦ 一轮收尾后回炉库存可能变动（reworkDone 拨回 pending）→ 重读计数
    unawaited(_loadReworkPending());
  }

  /// ⑤ 周扫摘要行文案（null = 不渲染）：
  /// - 阶段帧 phase=start → 「真题周扫进行中…」（live 提示）；
  /// - ran=true 且出卡 >0 → 「真题周扫：出卡 N 张 · 入库 M 张」；
  /// - ran=true 且出卡 0 → 「真题周扫：本周无新增真题卡」（LLM 判定宁缺毋滥）；
  /// - ran≠true（节流 throttled / 空态 empty / llmError / importError）→
  ///   null 静默（空态拍板：不报错不出噪音；细节在 last_run.json weekly 块）。
  static String? _weeklyLineOf(Object? w0) {
    if (w0 is! Map) return null;
    final w = Map<String, Object?>.from(w0);
    if (w['phase'] == 'start') return '真题周扫进行中…';
    if (w['ran'] != true) return null;
    final cards = _asInt(w['cards']);
    final imported = _asInt(w['imported']);
    return cards > 0
        ? '真题周扫：出卡 $cards 张 · 入库 $imported 张'
        : '真题周扫：本周无新增真题卡';
  }

  /// ⑦ 重读回炉待重造计数（拉取失败 / null → 保持原值或行不渲染）。
  Future<void> _loadReworkPending() async {
    final n = await _src.fetchReworkPending();
    if (!mounted || n == null) return;
    setState(() => _reworkPending = n);
  }

  // ------------------------------------------------------------- 渲染 ----

  static String _triggerLabel(String t) => switch (t) {
    kPipelineTriggerManual => '手动触发',
    kPipelineTriggerStartup => '启动补跑',
    kPipelineTriggerScheduled => '定时 22:55',
    _ => t.isEmpty ? '未知来源' : t,
  };

  /// ISO 时间戳 → 「9月7日 01:20」（解析失败回退空串）。
  static String _fmtTs(String? iso) {
    final t = iso == null ? null : DateTime.tryParse(iso);
    if (t == null) return '';
    final mm = t.minute.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    return '${t.month}月${t.day}日 $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = _frame;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dynamic_feed_outlined,
                  size: 18,
                  color: scheme.outline,
                ),
                const SizedBox(width: 8),
                Text(
                  '卡生成队列',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_live) ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '生成中',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ] else if (f != null)
                  Text(
                    '上次运行',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (f == null && _live)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '已触发流水线，正在准备队列数据…',
                  style: TextStyle(fontSize: 13, color: scheme.outline),
                ),
              )
            else if (f == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '暂无队列数据——收件箱存入关键词、设置页「强制开始拆卡 / 改卡」'
                  '触发后，这里实时展示生成进度',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              )
            else
              ..._body(scheme, f),
            // ⑤ 真题周扫摘要行（live=stage:'weekly' 事件 / 终态=last_run.json
            // weekly 块）：独立于队列帧渲染（空态/节流 null 不渲染——静默
            // 拍板）；⑦ reworkPending 行照旧在其后。
            if (_weeklyLine != null && _weeklyLine!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _weeklyLine!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ),
            // ⑦ 回炉待重造（rework_queue pending 行数，经语料状态端点）：
            // 独立于队列帧渲染——空态/终态/live 均显示（N=0 也显示，待审核
            // 拒绝带理由 / 回炉按钮提交后数值即动）；未拉到（null）不渲染。
            if (_reworkPending != null)
              _group(scheme, '回炉待重造', _reworkPending, const []),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(ColorScheme scheme, _QueueFrame f) {
    final info = f.live
        ? '触发：${_triggerLabel(f.trigger)} · 并发 ${f.concurrency} · '
              '共 ${f.total} 条关键词'
        : [
            if (_fmtTs(f.ts).isNotEmpty) _fmtTs(f.ts),
            _triggerLabel(f.trigger),
            '用时 ${f.elapsedSec.toStringAsFixed(1)} 秒',
            '并发 ${f.concurrency}',
          ].join(' · ');
    final reworkLabel = f.live
        ? '回炉 ${f.reworkTotal}'
        : '回炉 ${f.reworkTotal}'
              '${f.reworkDone == null ? '' : ' · 重造完成 ${f.reworkDone}'}';
    final reworkItems = [
      for (final r in f.rework)
        '· ${r['front'] ?? ''}'
            '${(r['reason'] ?? '').toString().isEmpty ? '' : '（${r['reason']}）'}',
    ];
    return [
      Text(info, style: TextStyle(fontSize: 11, color: scheme.outline)),
      if (f.live) ...[
        const SizedBox(height: 10),
        LinearProgressIndicator(
          minHeight: 4,
          value: f.total > 0
              ? ((f.doneCount + f.failedCount) / f.total).clamp(0.0, 1.0)
              : null,
        ),
      ],
      const SizedBox(height: 10),
      _group(scheme, '正在生成', f.runningCount, [
        for (final m in f.running) '· ${m['keyword'] ?? ''}',
      ], highlight: true),
      _group(scheme, '待生成', f.waitingCount, [
        for (final m in f.waiting) '· ${m['keyword'] ?? ''}',
      ]),
      _group(scheme, '失败', f.failedCount, [
        for (final m in f.failed)
          '· ${m['keyword'] ?? ''}'
              '${(m['error'] ?? '').toString().isEmpty ? '' : '：${m['error']}'}',
      ], danger: true),
      _group(scheme, reworkLabel, null, reworkItems),
      const SizedBox(height: 8),
      Text(
        f.live
            ? '已生成 ${f.doneCount}/${f.total} · 入库 ${f.imported} 张'
            : '已生成 ${f.doneCount}/${f.total} · 入库 ${f.imported} 张 · '
                  '消费 ${f.consumed} 条',
        style: TextStyle(fontSize: 12, color: scheme.outline),
      ),
      // #16 终态学习记录摘要行（live 不强求——快照帧口径；空 = 不渲染）
      if (!f.live && f.studyLogLine.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          f.studyLogLine,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      ],
      if (f.live && f.message.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          f.message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
      ],
    ];
  }

  /// 分组：标题行（含计数或纯标签）+ 条目行（单行省略）。
  /// [count] 为 null 时标题行直接用 [label]（回炉组的计数已拼入标签）。
  Widget _group(
    ColorScheme scheme,
    String label,
    int? count,
    List<String> items, {
    bool highlight = false,
    bool danger = false,
  }) {
    final titleColor = danger
        ? scheme.error
        : highlight
        ? scheme.primary
        : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == null ? label : '$label $count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: titleColor,
            ),
          ),
          for (final line in items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一帧队列视图（事件帧 / last_run 快照帧共用一套渲染字段）。
/// 契约：pipeline_runner.dart PipelineDeps.onProgress（counts['queue'] =
/// [_CatchupKwQueue.snapshot]）与 last_run.json（meta + queue + counts）。
class _QueueFrame {
  _QueueFrame({
    required this.live,
    required this.trigger,
    required this.concurrency,
    required this.ts,
    required this.total,
    required this.runningCount,
    required this.waitingCount,
    required this.doneCount,
    required this.failedCount,
    required this.imported,
    required this.consumed,
    required this.running,
    required this.waiting,
    required this.failed,
    required this.reworkTotal,
    required this.rework,
    this.reworkDone,
    this.elapsedSec = 0,
    this.message = '',
    this.studyLogLine = '',
  });

  /// 事件帧（counts['queue'] 全量快照逐帧自洽）。
  factory _QueueFrame.fromEvent(IsolateProgressEvent e) {
    final c = e.counts ?? const <String, Object?>{};
    final q = c['queue'] is Map
        ? Map<String, Object?>.from(c['queue'] as Map)
        : const <String, Object?>{};
    final rework = _reworkBlock(q);
    return _QueueFrame(
      live: true,
      trigger: '${c['trigger'] ?? ''}',
      concurrency: _asInt(q['concurrency']),
      ts: '${c['ts'] ?? ''}',
      total: _asInt(q['total']),
      runningCount: _asInt(q['runningCount']),
      waitingCount: _asInt(q['waitingCount']),
      doneCount: _asInt(q['doneCount']),
      failedCount: _asInt(q['failedCount']),
      imported: _asInt(q['imported']),
      consumed: _asInt(q['consumed']),
      running: _bucket(q, 'running'),
      waiting: _bucket(q, 'waiting'),
      failed: _bucket(q, 'failed'),
      reworkTotal: _asInt(rework['total']),
      rework: _bucket(rework, 'items'),
      message: '${c['message'] ?? ''}',
    );
  }

  /// 终态快照帧（last_run.json：meta.trigger/concurrency/elapsedSec +
  /// queue 块 + counts.reworkDone + #16 counts.studyLog/steps.studyLog）。
  factory _QueueFrame.fromSnapshot(Map<String, Object?> run) {
    final meta = run['meta'] is Map
        ? Map<String, Object?>.from(run['meta'] as Map)
        : const <String, Object?>{};
    final q = run['queue'] is Map
        ? Map<String, Object?>.from(run['queue'] as Map)
        : const <String, Object?>{};
    final counts = run['counts'] is Map
        ? Map<String, Object?>.from(run['counts'] as Map)
        : const <String, Object?>{};
    final studyLog = counts['studyLog'] is Map
        ? Map<String, Object?>.from(counts['studyLog'] as Map)
        : const <String, Object?>{};
    final rework = _reworkBlock(q);
    return _QueueFrame(
      live: false,
      trigger: '${q['trigger'] ?? meta['trigger'] ?? ''}',
      concurrency: _asInt(q['concurrency'] ?? meta['concurrency']),
      ts: '${meta['generatedAt'] ?? meta['startedAt'] ?? ''}',
      total: _asInt(q['total']),
      runningCount: _asInt(q['runningCount']),
      waitingCount: _asInt(q['waitingCount']),
      doneCount: _asInt(q['doneCount']),
      failedCount: _asInt(q['failedCount']),
      imported: _asInt(q['imported']),
      consumed: _asInt(q['consumed']),
      running: _bucket(q, 'running'),
      waiting: _bucket(q, 'waiting'),
      failed: _bucket(q, 'failed'),
      reworkTotal: _asInt(rework['total']),
      rework: _bucket(rework, 'items'),
      reworkDone: counts['reworkDone'] == null
          ? null
          : _asInt(counts['reworkDone']),
      elapsedSec: _asDouble(meta['elapsedSec']),
      studyLogLine: _studyLogLine(run, studyLog),
    );
  }

  final bool live;
  final String trigger;
  final int concurrency;
  final String ts;
  final int total;
  final int runningCount;
  final int waitingCount;
  final int doneCount;
  final int failedCount;
  final int imported;
  final int consumed;
  final List<Map<String, Object?>> running;
  final List<Map<String, Object?>> waiting;
  final List<Map<String, Object?>> failed;
  final int reworkTotal;
  final List<Map<String, Object?>> rework;

  /// 仅终态快照：⑦ 回炉完成条数（counts.reworkDone；live 帧无此值）。
  final int? reworkDone;

  /// 仅终态快照：整轮耗时秒（meta.elapsedSec）。
  final double elapsedSec;

  /// 仅事件帧：最近一条事件的人读文案。
  final String message;

  /// #16 仅终态快照：学习记录摘要行（counts.studyLog.entries/advanced +
  /// steps.studyLog 首因 note；空 = 不渲染——本轮无学习记录条目时隐藏）。
  final String studyLogLine;
}

// ---------------- 契约解析助手（防御式：坏值回退 0/空，不炸面板） ----------------

/// #16 学习记录摘要行（last_run.json 口径）：
/// - counts.studyLog.entries = 0 → 空串（不渲染——本轮无学习记录条目）；
/// - advanced > 0 → 「学习记录：推进 N 章」（N = 推进成功的章节引用数）；
/// - 有条目未推进 → 「学习记录：<首因 note>」（steps.studyLog.subjects[].refs
///   首个未推进 ref 的 note，如「教材未命中（低于低分线 0.30）——不推进」）；
///   无 ref/note 可取（如规范化失败空 refs）→ 「学习记录：未推进」。
String _studyLogLine(Map<String, Object?> run, Map<String, Object?> studyLog) {
  if (_asInt(studyLog['entries']) <= 0) {
    return '';
  }
  final advanced = _asInt(studyLog['advanced']);
  if (advanced > 0) {
    return '学习记录：推进 $advanced 章';
  }
  final steps = run['steps'] is Map
      ? Map<String, Object?>.from(run['steps'] as Map)
      : const <String, Object?>{};
  final slStep = steps['studyLog'] is Map
      ? Map<String, Object?>.from(steps['studyLog'] as Map)
      : const <String, Object?>{};
  final subjects = slStep['subjects'] is List
      ? slStep['subjects'] as List
      : const [];
  for (final s in subjects) {
    if (s is! Map) continue;
    final refs = s['refs'] is List ? s['refs'] as List : const [];
    for (final r in refs) {
      if (r is! Map || r['advanced'] == true) continue;
      final note = '${r['note'] ?? ''}';
      if (note.isNotEmpty) {
        return '学习记录：$note';
      }
    }
  }
  return '学习记录：未推进';
}

int _asInt(Object? v) =>
    v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

double _asDouble(Object? v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

Map<String, Object?> _reworkBlock(Map<String, Object?> q) => q['rework'] is Map
    ? Map<String, Object?>.from(q['rework'] as Map)
    : const {};

List<Map<String, Object?>> _bucket(Map<String, Object?> m, String key) {
  final raw = m[key];
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map) Map<String, Object?>.from(e),
  ];
}
