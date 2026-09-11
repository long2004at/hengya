// 恒牙（hengya）· #12 拆卡并发池 + #13 进度事件（关键词粒度）单元测试
// ============================================================================
//
// 断言面（本节点验收契约）：
//  1. 池上限：fake LLM 记录同时在跑数峰值——恒 ≤ kKeywordConcurrency(3)，
//     且 7 任务 3 worker 满载时恰为 3（「N worker 从共享游标领号」结构的
//     确定性结果：3 个 worker 首个 await 前同步领号开跑）；
//  2. 全完成：7 任务全部处理、卡真实落库（真实临时 hengya.db）、收件箱
//     全部消费、结果按 kwPending 序保序；
//  3. 隔离：单关键词抛非预期 Error（模拟畸形数据 TypeError 同型）只失败
//     该条（契约 9 不 consume 留补跑），其余在跑任务与整轮不受影响；
//  4. 无泄漏：收口后 in-flight 归零、等待后无迟到调用（池无定时器/游离
//     Future，Future.wait 收口即清理）；
//  5. 事件契约（#13）：type 序列、快照不变式（running+waiting+done+failed
//     == total 且 runningCount ≤ 池大小）、rework 条目、trigger 透传；
//  6. 池参数：concurrency=1 串行；大于 N 收敛到 N；空队列零任务不炸；
//  7. 真实 worker 链（consumeForceRun 无 override）：trigger 透传
//     last_run.json（meta.trigger + queue 块）+ 关键词粒度事件 + 标志删除。
//
// 纪律：
//  - 纯 plain test，**不调** TestWidgetsFlutterBinding.ensureInitialized()——
//    它会把 dart:io HttpClient 全局替换为恒 400 假实现；本文件 fake LLM
//    零网络，不受影响，但按环境纪律不引入该副作用；
//  - Windows 测试宿主显式加载 test/sqlite3.dll（同 local_backend_test 教训）；
//  - 真实临时 hengya.db 全链（LocalDbPort 直连——import/consume/reworkDone
//    落库为真实 SQLite 行为，与生产 App 实装同一条链路）。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/local/corpus/progress_db.dart'
    show emptyProgress;
import 'package:hengya/services/local/corpus/run_llm.dart' show LlmChatFn;
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/isolate_runner.dart'
    show IsolateProgressEvent, IsolateRunner;
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

/// split 调用在跑数跟踪（并发上限断言的探针）。
class _SplitProbe {
  int inFlight = 0;
  int maxInFlight = 0;
  int calls = 0;

  void enter() {
    inFlight++;
    if (inFlight > maxInFlight) {
      maxInFlight = inFlight;
    }
  }

  void leave() => inFlight--;
}

void main() {
  // Windows 测试宿主：显式加载 test/sqlite3.dll（worker isolate 由
  // IsolateRunner.start 自动探测同款 dll 随 boot 下发重放——文件头 ①）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_pool_test_');
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.pipelineKick = null;
    PipelineRunner.instance.runOnceOverride = null;
    PipelineRunner.instance.lastResult = null;
    PipelineRunner.instance.lastProgress = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<Db> openDb() => Db.open('${tmp.path}/hengya.db');

  /// fake 检索命中（同 pipeline_runner_test hit() 形状——searchHits/
  /// chunkToEvidence 消费口径）。
  Map<String, Object?> hit(String cid) => <String, Object?>{
    'chunk_id': cid,
    'deck': '讲义',
    'page_range': '1-2',
    'title': '第一章 · 概述',
    'source_type': 'ppt',
    'subject_id': 'endo',
    'text': '正文：测试证据内容。',
    'score': 0.92,
  };

  /// fake LLM（脚本化）：split → 150ms 延迟后出 1 张真 ppt 卡（探针记录
  /// 在跑数；延迟窗口取大——CI 共享 runner 负载下 worker 取任务间隙可被
  /// 拖长，25ms 窗口曾致「峰值恰 3」满载断言漏采，150ms 使 3 worker 必然
  /// 同时在飞）；throwOn 集合内关键词延迟 10ms 后抛非 LlmException 的 Error
  ///（模拟 splitKeyword 内逃逸的畸形数据异常——隔离路径必经池 worker catch）。
  (LlmChatFn, _SplitProbe) fakeLlm({Set<String> throwOn = const {}}) {
    final probe = _SplitProbe();
    return (
      (String system, String user, {String tag = ''}) async {
        switch (tag) {
          case 'split':
            probe.calls++;
            probe.enter();
            try {
              final kwText =
                  ((jsonDecode(user) as Map)['keyword'] as Map)['text']
                      as String;
              if (throwOn.contains(kwText)) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
                throw StateError('模拟未捕获 Error（畸形数据同型）：$kwText');
              }
              await Future<void>.delayed(const Duration(milliseconds: 150));
              return jsonEncode(<String, Object?>{
                'cards': <Map<String, Object?>>[
                  <String, Object?>{
                    'kind': 'ppt',
                    'front': '题-$kwText',
                    'back': '答-$kwText',
                    'topic': kwText,
                    'evidenceChunkId': 'c1',
                  },
                ],
              });
            } finally {
              probe.leave();
            }
          case 'rework':
            return jsonEncode(<String, Object?>{
              'front': '重写后的回炉题干',
              'back': '重写后的三点答案',
              'evidenceChunkId': 'r1',
            });
          default:
            return '{"queries": []}'; // synonym / studylog 兜底
        }
      },
      probe,
    );
  }

  /// 无脑命中的 fake 检索（每查询 1 条 → pptHit=true，无 synonym 分支）。
  Future<Map<String, Object?>> allHitSearch(
    String query, {
    String? subject,
    String? sourceType,
    int? k,
  }) async {
    return <String, Object?>{
      'results': <Object?>[hit('c1')],
    };
  }

  List<String> seedKws(Db db, Iterable<String> texts) {
    for (final t in texts) {
      db.insertKeyword(subjectId: 'endo', keyword: t, source: 'chat', note: '');
    }
    return db
        .inboxPending()
        .map((r) => r['keyword'] as String)
        .toList(); // 快照序 = runCatchup 将看到的顺序（保序断言基准）
  }

  test('#12 池上限：7 任务并发峰值恰为 3（≤上限 + 确实并发），全完成落库保序', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '通史');
    final kws = seedKws(db, const [
      'alpha',
      'bravo',
      'charlie',
      'delta',
      'echo',
      'foxtrot',
      'golf',
    ]);
    // 回炉队列 1 项（快照 rework 条目 + ⑦ 真实重写断言）
    db.importCard(
      FlashCard(
        id: 'endo-orig-001',
        subjectId: 'endo',
        type: CardType.basic,
        front: '原始回炉题干',
        back: '原始答案',
        anchor: '绪论 p1',
        source: '课程 PPT',
        status: CardStatus.pending,
      ),
    );
    db.activateCard('endo-orig-001');
    db.reworkCard('endo-orig-001', '答案太啰嗦', '请精简为三点');

    final (llm, probe) = fakeLlm();
    final result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: allHitSearch,
        llmChat: llm,
        prompts: const {},
        progressData: emptyProgress(),
      ),
    );

    // ── 池上限（#12 核心断言）：峰值恰 3 —— ≤上限 + 满载证明非串行 ──
    expect(probe.maxInFlight, 3, reason: '7 任务 3 worker：领号结构下并发峰值应恰为池大小');
    expect(probe.calls, 7, reason: '每个关键词恰好 1 次 split 调用');

    // ── 全部完成：处理数/卡计数/真实落库/收件箱消费 ──
    final counts = result['counts'] as Map<String, Object?>;
    expect(counts['keywordsProcessed'], 7);
    expect((counts['cards'] as Map)['total'], 7);
    expect((counts['cards'] as Map)['failed'], 0);
    final imp = counts['import'] as Map<String, Object?>;
    expect(imp['inserted'], 7);
    expect(imp['consumed'], 7);
    expect(counts['reworkDone'], 1, reason: '⑦ 回炉真实重写完成');
    expect(db.inboxPending(), isEmpty, reason: '7 条全部消费');
    final fronts = db.pendingCards(limit: 20).map((c) => c.front).toSet();
    for (final t in kws) {
      expect(fronts, contains('题-$t'), reason: '「$t」的卡真实入库');
    }
    final reworked = db.cardById('endo-orig-001')!;
    expect(reworked.status, CardStatus.pending, reason: '回炉完成回待审核池');
    expect(reworked.front, '重写后的回炉题干');

    // ── 保序：steps.keywords 与 kwPending 快照同序（占位回填不乱序） ──
    final resultKws = ((result['steps'] as Map)['keywords'] as List)
        .cast<Map<String, Object?>>()
        .map((k) => k['keyword'] as String)
        .toList();
    expect(resultKws, kws);

    // ── 无泄漏：收口后 in-flight 归零 + 等待后无迟到调用 ──
    expect(probe.inFlight, 0, reason: 'runCatchup 返回时全部任务收口');
    final callsAfter = probe.calls;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(probe.calls, callsAfter, reason: '无游离 Future/定时器迟到回调');
    expect(IsolateRunner.instance.isRunning(pipelineCatchupJobId), isFalse);

    // ── meta（#13）：trigger/concurrency 存档键 ──
    final meta = result['meta'] as Map<String, Object?>;
    expect(meta['trigger'], kPipelineTriggerManual, reason: '缺省触发来源');
    expect(meta['concurrency'], 3, reason: '实际池大小存档');
    expect(meta['startedAt'], isA<String>());
  });

  test('#12 隔离：单关键词抛 Error 只失败该条（不 consume 留补跑），其余照常', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '通史');
    seedKws(db, const [
      'alpha',
      'bravo',
      'charlie',
      'delta',
      'echo',
      'foxtrot',
      'golf',
    ]);

    final (llm, probe) = fakeLlm(throwOn: {'charlie'});
    final result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: allHitSearch,
        llmChat: llm,
        prompts: const {},
        progressData: emptyProgress(),
      ),
    );

    expect(probe.maxInFlight, lessThanOrEqualTo(3), reason: '隔离用例池上限仍成立');
    final counts = result['counts'] as Map<String, Object?>;
    expect(counts['keywordsProcessed'], 7, reason: '失败关键词也到达处理位');
    expect((counts['cards'] as Map)['failed'], 1, reason: '仅异常关键词 failed');
    final imp = counts['import'] as Map<String, Object?>;
    expect(imp['inserted'], 6);
    expect(imp['consumed'], 6, reason: '好关键词照常消费');
    final inboxLeft = db.inboxPending();
    expect(inboxLeft.length, 1, reason: '失败条目不 consume 留补跑（契约 9）');
    expect(inboxLeft.single['keyword'], 'charlie');
    expect(db.pendingCards(limit: 20).length, 6, reason: '6 张好卡真实入库');
    final byKw = {
      for (final k
          in ((result['steps'] as Map)['keywords'] as List)
              .cast<Map<String, Object?>>())
        k['keyword'] as String: k,
    };
    expect(byKw['charlie']!['status'], 'failed');
    expect((byKw['charlie']!['error'] as String), contains('模拟未捕获 Error'));
    expect((byKw['charlie']!['notes'] as List).join(' '), contains('关键词处理异常'));
    expect(byKw['golf']!['status'], 'ok', reason: '并发下其他任务完好');
  });

  test('#12 池参数：concurrency=1 串行；大于 N 收敛到 N；空队列零任务不炸', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '通史');

    // concurrency=1 → 串行（峰值恰 1）
    seedKws(db, const ['alpha', 'bravo', 'charlie']);
    var (llm, probe) = fakeLlm();
    var result = await runCatchup(
      keywordConcurrency: 1,
      deps: PipelineDeps(
        db: db,
        runSearch: allHitSearch,
        llmChat: llm,
        prompts: const {},
        progressData: emptyProgress(),
      ),
    );
    expect(probe.maxInFlight, 1, reason: 'concurrency=1 严格串行');
    expect((result['meta'] as Map)['concurrency'], 1);
    expect(db.inboxPending(), isEmpty);

    // concurrency=5 > N=2 → 收敛到 2
    seedKws(db, const ['delta', 'echo']);
    (llm, probe) = fakeLlm();
    result = await runCatchup(
      keywordConcurrency: 5,
      deps: PipelineDeps(
        db: db,
        runSearch: allHitSearch,
        llmChat: llm,
        prompts: const {},
        progressData: emptyProgress(),
      ),
    );
    expect(probe.maxInFlight, 2, reason: '池大小收敛到待处理数（min(5,2)）');
    expect((result['meta'] as Map)['concurrency'], 2);
    expect(db.inboxPending(), isEmpty);

    // 空队列 → 0 个 worker 照常收口（Future.wait([])），零关键词事件不炸
    final events = <Map<String, Object?>>[];
    result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: allHitSearch,
        llmChat: llm,
        prompts: const {},
        progressData: emptyProgress(),
        onProgress: events.add,
      ),
    );
    expect((result['counts'] as Map)['keywordsProcessed'], 0);
    expect((result['meta'] as Map)['concurrency'], 0, reason: '空队列池大小 0');
    expect(
      events.map((e) => e['type']).toSet(),
      const <String?>{'start', 'phase'},
      reason: '空队列只有 start/phase 事件，无 kw_* 事件',
    );
  });

  test('#13 事件契约：关键词粒度事件 + 快照不变式 + rework 条目 + trigger 透传', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '通史');
    seedKws(db, const ['alpha', 'bravo', 'charlie', 'delta']);
    db.importCard(
      FlashCard(
        id: 'endo-orig-001',
        subjectId: 'endo',
        type: CardType.basic,
        front: '原始回炉题干',
        back: '原始答案',
        anchor: '绪论 p1',
        source: '课程 PPT',
        status: CardStatus.pending,
      ),
    );
    db.activateCard('endo-orig-001');
    db.reworkCard('endo-orig-001', '答案太啰嗦', '');

    final (llm, _) = fakeLlm(throwOn: {'bravo'});
    final events = <Map<String, Object?>>[];
    final result = await runCatchup(
      trigger: kPipelineTriggerScheduled,
      deps: PipelineDeps(
        db: db,
        runSearch: allHitSearch,
        llmChat: llm,
        prompts: const {},
        progressData: emptyProgress(),
        onProgress: events.add,
      ),
    );

    // ── 通用字段：每事件必有 type/ts/trigger/queue/message ──
    expect(events, isNotEmpty);
    for (final e in events) {
      expect(e['type'], isA<String>(), reason: 'type 必有');
      expect(
        DateTime.tryParse(e['ts'] as String? ?? ''),
        isNotNull,
        reason: 'ts 为可解析 ISO 时间戳',
      );
      expect(e['trigger'], kPipelineTriggerScheduled, reason: 'trigger 透传');
      expect(e['message'], isA<String>());
      final q = e['queue'] as Map<String, Object?>;
      // 快照不变式：running+waiting+done+failed == total；running ≤ 池大小
      final sum =
          (q['runningCount'] as num).toInt() +
          (q['waitingCount'] as num).toInt() +
          (q['doneCount'] as num).toInt() +
          (q['failedCount'] as num).toInt();
      expect(sum, q['total'], reason: '每槽位恰属一桶');
      expect((q['runningCount'] as num).toInt(), lessThanOrEqualTo(3));
      expect((q['rework'] as Map)['total'], 1, reason: '回炉条目计数在位');
    }

    // ── 事件序列：start → kw_start/kw_done 交错 → phase(import) →
    //    kw_import×4 → phase(rework) ──
    expect(events.first['type'], 'start');
    expect(events.last['type'], 'phase');
    expect(events.last['phase'], 'rework');
    final types = events.map((e) => e['type'] as String).toList();
    expect(types.where((t) => t == 'kw_start').length, 4);
    expect(types.where((t) => t == 'kw_done').length, 4);
    expect(types.where((t) => t == 'kw_import').length, 4);
    expect(types.where((t) => t == 'phase').length, 2);
    final phaseIdx = [
      for (var i = 0; i < types.length; i++)
        if (types[i] == 'phase') i,
    ];
    expect(phaseIdx.length, 2);
    expect(
      events[phaseIdx.first]['phase'],
      'import',
      reason: '先 import 后 rework',
    );
    // kw_import 全部在 phase(import) 之后
    for (var i = 0; i < types.length; i++) {
      if (types[i] == 'kw_import') {
        expect(i, greaterThan(phaseIdx.first));
      }
    }

    // ── kw_done summary：ok/failed 区分 + 失败原文 ──
    final bravoDone = events.firstWhere(
      (e) => e['type'] == 'kw_done' && (e['item'] as Map)['keyword'] == 'bravo',
    );
    expect((bravoDone['summary'] as Map)['status'], 'failed');
    expect(
      ((bravoDone['summary'] as Map)['error'] as String),
      contains('模拟未捕获 Error'),
    );
    final alphaDone = events.firstWhere(
      (e) => e['type'] == 'kw_done' && (e['item'] as Map)['keyword'] == 'alpha',
    );
    final alphaSummary = alphaDone['summary'] as Map;
    expect(alphaSummary['status'], 'ok');
    expect(alphaSummary['cards'], 1);
    expect(alphaSummary['pptHit'], true);
    expect(alphaSummary['elapsedMs'], isA<int>());

    // ── kw_import summary：inserted/consumed ──
    final alphaImport = events.firstWhere(
      (e) =>
          e['type'] == 'kw_import' && (e['item'] as Map)['keyword'] == 'alpha',
    );
    final ai = alphaImport['summary'] as Map;
    expect(ai['inserted'], 1);
    expect(ai['consumed'], true);

    // ── 终态快照（最后一个事件携带）：done 3 + failed 1，running/waiting 清空 ──
    final finalQ = events.last['queue'] as Map<String, Object?>;
    expect(finalQ['total'], 4);
    expect(finalQ['doneCount'], 3);
    expect(finalQ['failedCount'], 1);
    expect(finalQ['runningCount'], 0);
    expect(finalQ['waitingCount'], 0);
    expect(finalQ['imported'], 3);
    expect(finalQ['consumed'], 3);
    final failedEntry = (finalQ['failed'] as List).single as Map;
    expect(failedEntry['keyword'], 'bravo');
    expect(failedEntry['status'], 'failed');
    expect(failedEntry['startedAt'], isA<String>(), reason: '失败条目时间戳在位');
    final reworkItem =
        ((finalQ['rework'] as Map)['items'] as List).single as Map;
    expect(reworkItem['cardId'], 'endo-orig-001');
    expect(reworkItem['queueId'], isNotNull);
    expect(reworkItem['reason'], '答案太啰嗦');

    // ── last_run.json 存档块（#13）：trigger/concurrency + per-关键词统计 ──
    final queue = result['queue'] as Map<String, Object?>;
    expect(queue['trigger'], kPipelineTriggerScheduled);
    expect(queue['concurrency'], 3, reason: '4 任务 → 池 3');
    expect(queue['total'], 4);
    final kwRows = queue['keywords'] as List;
    expect(kwRows.length, 4);
    final bravoRow = kwRows.cast<Map<String, Object?>>().firstWhere(
      (r) => r['keyword'] == 'bravo',
    );
    expect(bravoRow['status'], 'failed');
    expect(bravoRow['error'], contains('模拟未捕获 Error'));
    expect(
      bravoRow['import'],
      isA<Map>(),
      reason: '失败条目 import 明细（consumed=false）',
    );
    final alphaRow = kwRows.cast<Map<String, Object?>>().firstWhere(
      (r) => r['keyword'] == 'alpha',
    );
    expect(alphaRow['cards'], 1);
    expect((alphaRow['import'] as Map)['consumed'], true);
    expect(alphaRow['startedAt'], isA<String>());
    expect(alphaRow['endedAt'], isA<String>());
    expect(alphaRow['elapsedMs'], isA<int>());
  });

  test(
    '#13 真实 worker 链：consumeForceRun → trigger 透传 last_run.json + 事件 + 标志删除',
    () async {
      await LocalBackend.instance.resetForTest();
      LocalBackend.instance.init(tmp.path);
      Directory('${tmp.path}/corpus').createSync(recursive: true);
      File(PipelineRunner.markerPath(tmp.path)).writeAsStringSync('queued');

      // 种子：科目 + 3 关键词（worker 自开连接跑同一条链；WAL 双连接安全；
      // 3 条 → 真实 worker 链也验证池满载 min(3, N)=3）
      final seedDb = await Db.open('${tmp.path}/hengya.db');
      seedDb.insertSubject(id: 'endo', name: '通史');
      for (final kw in const ['龋病四联因素', '白斑', '皮沟皮嵴']) {
        seedDb.insertKeyword(
          subjectId: 'endo',
          keyword: kw,
          source: 'chat',
          note: '',
        );
      }
      seedDb.close();

      final events = <IsolateProgressEvent>[];
      final sub = PipelineRunner.instance.progress.listen(events.add);
      try {
        await PipelineRunner.instance
            .consumeForceRun(); // 缺省 trigger = manual（路由 kick 同源）
        await Future<void>.delayed(const Duration(milliseconds: 30));
      } finally {
        await sub.cancel();
      }

      // 标志删除（rc==0 同义）+ 结果/存档 trigger 透传
      expect(File(PipelineRunner.markerPath(tmp.path)).existsSync(), isFalse);
      final result = PipelineRunner.instance.lastResult!;
      expect((result['meta'] as Map)['trigger'], 'manual');
      expect((result['meta'] as Map)['concurrency'], 3);
      final saved =
          jsonDecode(
                File('${tmp.path}/corpus/last_run.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect((saved['meta'] as Map)['trigger'], 'manual');
      expect((saved['meta'] as Map)['startedAt'], isA<String>());
      expect(saved['queue'], isA<Map>(), reason: 'last_run.json 顶层 queue 块');
      expect(((saved['queue'] as Map)['keywords'] as List).length, 3);

      // 节点⑤：真实 worker 链收尾后自动真题周扫（本用例无 corpus.db、无已学
      // 章 → 空态静默：ran=false/skipped=empty，不写时间戳、不上抛）。
      final weekly = saved['weekly'] as Map?;
      expect(weekly, isNotNull, reason: 'catchup 结果顶层 weekly 块在位');
      expect(weekly!['ran'], false);
      expect(weekly['skipped'], 'empty');

      // 关键词粒度事件经 IsolateProgressEvent 转发（counts = 事件 Map 本体）
      expect(
        PipelineRunner.instance.lastProgress,
        isNotNull,
        reason: '中途订阅者快照缓存在位',
      );
      final structured = events
          .where((e) => e.counts?['type'] != null)
          .cast<IsolateProgressEvent>()
          .toList();
      expect(structured, isNotEmpty);
      final types = structured.map((e) => e.counts!['type'] as String).toList();
      expect(types.first, 'start');
      expect(types, containsAll(<String>['kw_start', 'kw_done', 'kw_import']));
      // ⑤ 起 catchup 阶段之后追加 weekly 阶段（stage='weekly'）——catchup 段
      // 末条仍为 phase（rework 收尾），weekly 段为 weekly_start→weekly_done。
      final catchupTypes = structured
          .where((e) => e.stage == 'catchup')
          .map((e) => e.counts!['type'] as String)
          .toList();
      expect(catchupTypes.last, 'phase');
      expect(types, containsAll(const <String>['weekly_start', 'weekly_done']));
      // LLM 未配置 → 关键词按 failed 处理（契约 9 不 consume），事件如实记录
      final kwDone = structured.firstWhere(
        (e) => e.counts!['type'] == 'kw_done',
      );
      expect((kwDone.counts!['summary'] as Map)['status'], 'failed');
      expect((kwDone.counts!['queue'] as Map)['total'], 3);
      expect((kwDone.counts!['trigger']), kPipelineTriggerManual);
      for (final e in structured.where((e) => e.stage == 'catchup')) {
        expect(e.stage, 'catchup', reason: 'catchup 段 stage 固定（兼容消费面）');
      }
      for (final e in structured.where((e) => e.stage == 'weekly')) {
        expect(
          e.counts!['weekly'],
          isA<Map>(),
          reason: '⑤ weekly 段事件携带 weekly 块',
        );
      }
      // 收件箱未消费（failed 留补跑）——终态可从 last_run.json 兜底读取
      final checkDb = await Db.open('${tmp.path}/hengya.db');
      try {
        expect(checkDb.inboxPending().length, 3);
      } finally {
        checkDb.close();
      }

      // worker 运行位已释放（无 isolate 泄漏）
      expect(IsolateRunner.instance.isRunning(pipelineCatchupJobId), isFalse);
      expect(PipelineRunner.instance.running, isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
