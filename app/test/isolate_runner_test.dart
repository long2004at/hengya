// 恒牙（hengya）· P1-3 isolate 基建 + 建库 job + 拆卡 job 冒烟测试
// ============================================================================
//
// 纪律：本文件全部是 **plain test()**（非 testWidgets）——假异步下 await
// 真实 isolate 消息必死锁（仓库测试纪律），真实 IO/await 允许（同
// pipeline_runner_test）。Windows 宿主 sqlite3.dll：主 isolate 显式
// override 同款基建；**worker isolate 的 override 由 IsolateRunner.start
// 自动探测 test/sqlite3.dll 随 boot 下发**（isolate_runner.dart 文件头 ①
// ——overrideForAll 不随 Isolate.spawn 复制）。
//
// 覆盖面（P1-3 验收）：
//   1. 基建：进度事件（首订阅缓冲补发）+ 结果回传 + 单飞释放后可再启动
//   2. 单飞守卫：运行中重复 start → StateError
//   3. best-effort 取消：cancel → 检查点终止 → IsolateCancelledException
//   4. 异常回传：IsolateJobException（message + 堆栈文本）
//   5. 建库 job（drill 零网络）：真实树（oms pptx + exam pdf——pdf 顺带
//      验证 pdfium 在 worker isolate 首用自然加载）→ corpus.db 契约 +
//      离线检索冒烟 + 进度阶段协议断言
//   6. 拆卡 job 真实链：PipelineRunner.consumeForceRun（无 override）→
//      spawn worker → worker 内自开 hengya.db/corpus → 空收件箱零出卡 +
//      last_run.json 落盘 + 标志删除 + 进度转发
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/local/corpus/extract_all.dart'
    show CorpusEmbedMode;
import 'package:hengya/services/local/corpus/search_engine.dart'
    show corpusSearch, kVec0Table;
import 'package:hengya/services/local/app_log.dart';
import 'package:hengya/services/local/corpus_build_job.dart';
import 'package:hengya/services/local/isolate_runner.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

// —— 源文件（CWD=app/；与 extract_all_build_test 同源）——
const srcOmsPptx =
    '../content/ppt_raw/oms/(2.1.2)--第二章口腔颌面外科基本操作与基础知识 (1).pptx';
const srcExamPdf =
    '../content/ppt_raw/exam/试卷与模拟题/2023年口腔助理医师试题（网友回忆版）.pdf';

// ------------------------------------------- 测试专用 worker 入口（顶层）----

/// 发 3 条进度后返回结果。
void _echoWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    for (var i = 1; i <= 3; i++) {
      ctx.emit(IsolateProgressEvent(stage: 'echo', message: '进度 $i/3'));
    }
    return <String, Object?>{'value': 42};
  });
}

/// 抛错回传。
void _boomWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    ctx.emit(const IsolateProgressEvent(stage: 'boom', message: '即将失败'));
    throw StateError('boom-测试错误');
  });
}

/// 循环发进度 + 取消检查点（单飞/取消测试用）。
void _loopWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    var i = 0;
    while (true) {
      ctx.checkCancelled();
      ctx.emit(IsolateProgressEvent(stage: 'loop', message: 'tick ${i++}'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
}

/// 日志回流（node-1）：worker 内经 ctx.log 发 info/warn/error 三级日志事件
/// + 1 条普通进度事件收尾（验证 stage='log' 与普通进度混杂时的 wire 解码）。
/// worker isolate 内 AppLog 无 dataDir 不落盘——日志必须经事件回流主 isolate，
/// 主侧按 stage=='log' 语义写 AppLog（见 isolate_runner.dart 文件头）。
void _logWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    ctx.log('info', 'weekly', '周扫装配完成（worker 内日志事件）');
    ctx.log('warn', 'weekly', '周扫检索降级（废弃章节）：corpus.db 缺 -exam 镜像');
    ctx.log('error', 'llm', '周扫 LLM 失败：模拟周扫宕机');
    ctx.emit(IsolateProgressEvent(stage: 'done', message: '日志事件已发完'));
    return <String, Object?>{'ok': true};
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_isolate_test_');
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.pipelineKick = null;
    PipelineRunner.instance.runOnceOverride = null;
    PipelineRunner.instance.lastResult = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // 目录已不存在/被占用——系统临时目录兜底清理
    }
  });

  test('基建冒烟：进度事件顺序 + 结果回传 + 完结后可再启动', () async {
    expect(IsolateRunner.instance.isRunning('echo-test'), isFalse);
    final handle = await IsolateRunner.instance.start<Map<String, Object?>>(
      jobId: 'echo-test',
      workerEntry: _echoWorkerEntry,
    );
    expect(IsolateRunner.instance.isRunning('echo-test'), isTrue);
    final events = <IsolateProgressEvent>[];
    final sub = handle.progress.listen(events.add);
    final result = await handle.done;
    // done 与流事件送达存在微任务差——等待 drain 后再断言
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();

    expect(result['value'], 42);
    expect(events.map((e) => e.message).toList(),
        ['进度 1/3', '进度 2/3', '进度 3/3']);
    expect(events.every((e) => e.stage == 'echo'), isTrue);
    expect(IsolateRunner.instance.isRunning('echo-test'), isFalse);

    // 完结后同 jobId 可再启动（运行位已释放）
    final handle2 = await IsolateRunner.instance.start<Map<String, Object?>>(
      jobId: 'echo-test',
      workerEntry: _echoWorkerEntry,
    );
    expect(await handle2.done, isNotNull);
    expect(IsolateRunner.instance.isRunning('echo-test'), isFalse);
  });

  test('单飞守卫：运行中重复 start 抛 StateError', () async {
    final handle = await IsolateRunner.instance.start<Object?>(
      jobId: 'single-flight-test',
      workerEntry: _loopWorkerEntry,
    );
    expect(
        () => IsolateRunner.instance.start<Object?>(
              jobId: 'single-flight-test',
              workerEntry: _loopWorkerEntry,
            ),
        throwsStateError);
    expect(IsolateRunner.instance.isRunning('single-flight-test'), isTrue);
    handle.cancel();
    await expectLater(handle.done, throwsA(isA<IsolateCancelledException>()));
    expect(IsolateRunner.instance.isRunning('single-flight-test'), isFalse);
  });

  test('best-effort 取消：cancel → 检查点终止 + IsolateCancelledException',
      () async {
    final handle = await IsolateRunner.instance.start<Object?>(
      jobId: 'cancel-test',
      workerEntry: _loopWorkerEntry,
    );
    final events = <IsolateProgressEvent>[];
    final sub = handle.progress.listen(events.add);
    await handle.progress.first; // 等首个 tick（首订阅缓冲保证可见）
    handle.cancel();
    await expectLater(handle.done, throwsA(isA<IsolateCancelledException>()));
    expect(handle.cancelSent, isTrue);
    final n = events.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(events.length, n); // worker 已终：不再产生新事件
    await sub.cancel();
  });

  test('异常回传：done 以 IsolateJobException 收尾（message + 堆栈文本）',
      () async {
    final handle = await IsolateRunner.instance.start<Object?>(
      jobId: 'boom-test',
      workerEntry: _boomWorkerEntry,
    );
    await expectLater(
        handle.done,
        throwsA(isA<IsolateJobException>()
            .having((e) => e.message, 'message', contains('boom-测试错误'))
            .having((e) => e.stackTrace, 'stackTrace', isNotNull)));
    expect(IsolateRunner.instance.isRunning('boom-test'), isFalse);
  });

  test('建库 job（drill 零网络）：worker 真实建库 → 检索冒烟 + 进度阶段协议',
      () async {
    if (!File(srcOmsPptx).existsSync() || !File(srcExamPdf).existsSync()) {
      // skip-guard：公开仓库不含 content/（课程语料，版权原因），本用例仅私有工作区生效
      // ignore: avoid_print
      print('SKIP: 私有语料缺失（$srcOmsPptx / $srcExamPdf）');
      return;
    }
    // 临时树：oms pptx + exam pdf（pdf 顺带验证 pdfium worker 内首用加载）
    final tree = '${tmp.path}/tree';
    Directory('$tree/oms').createSync(recursive: true);
    Directory('$tree/exam').createSync(recursive: true);
    File(srcOmsPptx).copySync('$tree/oms/${_pyName(srcOmsPptx)}');
    File(srcExamPdf).copySync('$tree/exam/${_pyName(srcExamPdf)}');
    final dbPath = '${tmp.path}/corpus/corpus.db';

    final events = <IsolateProgressEvent>[];
    final handle = await runCorpusBuild(CorpusBuildRequest(
      inputPath: tree,
      corpusDbPath: dbPath,
      mode: CorpusEmbedMode.drill,
    ));
    final sub = handle.progress.listen(events.add);
    final result = await handle.done;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sub.cancel();

    // 进度协议：start/extract/ingest/done 阶段齐备（0 chunks 才缺 ingest）
    final stages = events.map((e) => e.stage).toSet();
    expect(stages, containsAll(['start', 'extract', 'ingest', 'done']));
    final extractDone =
        events.lastWhere((e) => e.stage == 'extract' && e.counts != null);
    expect((extractDone.counts!['chunks'] as num?)?.toInt(), 111);

    // 结果（ExtractAllStats/IngestStats toJson 契约键）
    expect(result.chunks, 111);
    expect(result.extract?['errors'] as List, isEmpty);
    expect((result.ingest?['rows'] as num?)?.toInt(), 111);
    expect((result.ingest?['embedded'] as num?)?.toInt(), 111);
    expect((result.ingest?['vec0'] as Map)['ok'], isTrue);
    expect(result.elapsedS, greaterThan(0));
    expect(result.corpusDbPath, dbPath);
    expect(result.notes, isEmpty);

    // key 纪律：全部事件文本不含 key 片段（drill 无 key，本断言为协议守卫）
    for (final e in events) {
      expect(e.message.contains('sk-'), isFalse);
    }

    // corpus.db 落盘（worker 产物）→ 主 isolate 只读验证 + 离线检索冒烟
    expect(File(dbPath).existsSync(), isTrue);
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final n = db.select('SELECT count(*) FROM chunks').first.columnAt(0)
          as int;
      expect(n, 111);
      expect(_count(db, kVec0Table), 111); // float32 镜像表
      // 动态取查询词（首 chunk 的 6 连汉字）→ 词面 + 伪向量检索冒烟
      final text =
          '${db.select('SELECT text FROM chunks LIMIT 1').first.columnAt(0)}';
      final m = RegExp(r'[\u4e00-\u9fff]{6}').firstMatch(text)!;
      final res =
          await corpusSearch(db, m[0]!, k: 5, offline: true, rerank: false);
      expect((res['results'] as List), isNotEmpty, reason: '离线检索零命中');
    } finally {
      db.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('拆卡 job 真实链：consumeForceRun → worker 自开连接 → 零出卡 + 标志删除',
      () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    Directory('${tmp.path}/corpus').createSync(recursive: true);
    File(PipelineRunner.markerPath(tmp.path)).writeAsStringSync('queued');

    final events = <IsolateProgressEvent>[];
    final sub = PipelineRunner.instance.progress.listen(events.add);
    try {
      await PipelineRunner.instance.consumeForceRun();
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
    }

    // 标志删除（rc==0 同义）+ 结果与存档
    expect(File(PipelineRunner.markerPath(tmp.path)).existsSync(), isFalse);
    expect(PipelineRunner.instance.lastResult, isNotNull);
    final result = PipelineRunner.instance.lastResult!;
    final counts = result['counts'] as Map<String, Object?>;
    expect(counts['inbox'], 0); // 空收件箱 → 零出卡零导入
    expect(counts['keywordsProcessed'], 0);
    expect(((result['steps'] as Map)['health'] as Map)['ok'], true);
    expect(File('${tmp.path}/corpus/last_run.json').existsSync(), true);

    // 进度转发（PipelineRunner.progress ← worker catchup 协议）
    final catchupMsgs =
        events.where((e) => e.stage == 'catchup').map((e) => e.message).toList();
    expect(catchupMsgs.first, contains('开始'));
    expect(catchupMsgs.last, contains('完成'));

    // worker 运行位已释放
    expect(IsolateRunner.instance.isRunning(pipelineCatchupJobId), isFalse);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('手动真题周扫真实链：consumeWeeklyRun → weeklyOnly 只跑周扫不跑 catchup + last_run.json 合并写入',
      () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    Directory('${tmp.path}/corpus').createSync(recursive: true);
    // 预置上一轮 catchup 终态帧——合并写入必须保留（不整份覆盖）
    File('${tmp.path}/corpus/last_run.json').writeAsStringSync(
      jsonEncode({
        'meta': {'trigger': 'manual'},
        'queue': {'total': 3},
        'counts': {'inbox': 1},
      }),
    );

    final events = <IsolateProgressEvent>[];
    final sub = PipelineRunner.instance.progress.listen(events.add);
    try {
      await PipelineRunner.instance.consumeWeeklyRun();
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
    }

    // weekly-only 结果：无 catchup 帧，只有 weekly 块（空库 → 零候选静默跳过）
    expect(PipelineRunner.instance.lastResult, isNotNull);
    final result = PipelineRunner.instance.lastResult!;
    expect(result.containsKey('counts'), isFalse, reason: 'weeklyOnly 不跑六步总编排');
    expect(result.containsKey('queue'), isFalse);
    final weekly = result['weekly'] as Map<String, Object?>;
    expect(weekly['ran'], false);
    expect(weekly['skipped'], 'empty', reason: '空库零候选 → 空态静默跳过');

    // 进度协议：stage='weekly' 事件全程上报（start/done），无 catchup 帧
    final weeklyMsgs =
        events.where((e) => e.stage == 'weekly').map((e) => e.message).toList();
    expect(weeklyMsgs.first, contains('真题周扫开始'));
    expect(events.where((e) => e.stage == 'catchup'), isEmpty,
        reason: 'weeklyOnly 轮不发 catchup 帧');

    // 存档合并：上一轮 catchup 的 meta/queue/counts 保留，仅刷新 weekly 键
    final saved = jsonDecode(
      File('${tmp.path}/corpus/last_run.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect((saved['meta'] as Map)['trigger'], 'manual',
        reason: '上一轮 catchup 终态帧保留');
    expect((saved['queue'] as Map)['total'], 3);
    expect((saved['weekly'] as Map)['skipped'], 'empty');

    // 手动轮不写自动周扫节流时间戳（两路节奏独立）
    final check = sqlite3.open('${tmp.path}/hengya.db');
    final rows = check.select(
      "SELECT value FROM settings WHERE key = 'pipeline.lastWeeklyScanAt'",
    );
    expect(rows, isEmpty, reason: '手动周扫不写自动周扫节流时间戳');
    check.dispose();

    // worker 运行位已释放
    expect(IsolateRunner.instance.isRunning(pipelineWeeklyJobId), isFalse);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('日志回流（node-1）：worker ctx.log → wire 解码 → 主 isolate 落盘 AppLog 可读回',
      () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path); // dataDir 就位：AppLog 落盘点成立

    final handle = await IsolateRunner.instance.start<Map<String, Object?>>(
      jobId: 'log-echo-test',
      workerEntry: _logWorkerEntry,
    );
    final events = <IsolateProgressEvent>[];
    final sub = handle.progress.listen(events.add);
    final result = await handle.done;
    // done 与流事件送达存在微任务差——等待 drain 后再断言
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sub.cancel();

    expect(result['ok'], true);
    // ① wire 协议：stage='log' 事件带 level/tag 回传；普通进度事件不受污染
    final logs = events.where((e) => e.stage == 'log').toList();
    expect(logs.length, 3, reason: 'worker 发 3 条日志事件');
    expect(events.every((e) => e.level == null || e.stage == 'log'), isTrue,
        reason: 'level/tag 仅 log 事件携带（协议守卫）');
    expect(
      logs.map((e) => '${e.level}/${e.tag}').toSet(),
      {'info/weekly', 'warn/weekly', 'error/llm'},
    );

    // ② 主 isolate 侧按 stage=='log' 语义写 AppLog（与 local_backend
    //    _buildLogLevel / pipeline_runner _logWorkerEvent 同款映射）
    for (final e in logs) {
      AppLog.instance.log(
        switch (e.level) {
          'warn' => AppLogLevel.warn,
          'error' => AppLogLevel.error,
          _ => AppLogLevel.info,
        },
        (e.tag == null || e.tag!.isEmpty) ? 'corpus-build' : e.tag!,
        e.message,
      );
    }
final tail = await AppLog.instance.readTail(maxLines: 50);
    expect(tail, contains('[info] [weekly] 周扫装配完成（worker 内日志事件）'),
        reason: 'info 日志已落盘（行格式 level/tag 齐全）');
    expect(
      tail,
      contains('[warn] [weekly] 周扫检索降级（废弃章节）：corpus.db 缺 -exam 镜像'),
    );
    expect(tail, contains('[error] [llm] 周扫 LLM 失败：模拟周扫宕机'));

    // ③ 落盘文件在 dataDir/logs/ 下（非仅内存）
    final logFile =
        File('${tmp.path}/logs/app-${DateTime.now().toIso8601String().substring(0, 10).replaceAll('-', '')}.log');
    expect(logFile.existsSync(), isTrue, reason: '日志文件已落盘');
  });
}

// ------------------------------------------------------------ helpers ----

String _pyName(String path) =>
    path.split(Platform.pathSeparator).last.split('/').last;

int _count(Database db, String table) {
  try {
    return db.select('SELECT count(*) FROM "$table"').first.columnAt(0) as int;
  } catch (_) {
    return -1; // 表不存在
  }
}
